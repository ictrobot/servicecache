//! Linux host-futex backend for suspended WASIX waits.
//!
//! `futex_waitv` arrived in Linux 5.16, so it is invoked through `syscall`
//! and probed at runtime. This keeps the executable's libc requirements
//! unchanged and lets older kernels retain Wasmer's async wait path.

#[cfg(target_os = "linux")]
mod linux {
    use std::io;
    use std::sync::atomic::{AtomicU8, AtomicU32, Ordering};
    use std::time::Instant;

    use wasmer_vm::{HostFutexHooks, HostFutexResult, HostFutexWait};

    /// The backend's state: not yet probed, in use, never available on this
    /// host (the probe failed or the variable turned it off), or turned off
    /// after a wait the host could not interpret. The last two differ only
    /// in that a waiter may still be parked in the kernel after DISABLED.
    const UNKNOWN: u8 = 0;
    const SUPPORTED: u8 = 1;
    const UNAVAILABLE: u8 = 2;
    const DISABLED: u8 = 3;
    const FUTEX_32: u32 = 2;
    const FUTEX_WAITV_PRIVATE: u32 = FUTEX_32 | libc::FUTEX_PRIVATE_FLAG as u32;

    static SUPPORT: AtomicU8 = AtomicU8::new(UNKNOWN);

    #[repr(C)]
    struct Waiter {
        value: u64,
        address: u64,
        flags: u32,
        reserved: u32,
    }

    impl Waiter {
        fn new(address: *const u32, value: u32) -> Self {
            Self {
                value: u64::from(value),
                address: address as usize as u64,
                flags: FUTEX_WAITV_PRIVATE,
                reserved: 0,
            }
        }
    }

    pub(super) fn install() {
        let supported =
            std::env::var_os("SERVICECACHE_DISABLE_FUTEX_WAITV").is_none() && probe_futex_waitv();
        SUPPORT.store(
            if supported { SUPPORTED } else { UNAVAILABLE },
            Ordering::Release,
        );
        wasmer_vm::set_host_futex_hooks(HostFutexHooks {
            supported: || SUPPORT.load(Ordering::Acquire) == SUPPORTED,
            wait,
            wake,
        });
        tracing::debug!(supported, "host futex_waitv backend probed");
    }

    fn probe_futex_waitv() -> bool {
        let word = AtomicU32::new(0);
        let waiter = [Waiter::new((&raw const word).cast(), 1)];
        matches!(call_waitv(&waiter, None), Err(libc::EAGAIN))
    }

    fn wait(request: HostFutexWait) -> HostFutexResult {
        let waiters = [
            Waiter::new(request.address, request.expected),
            Waiter::new(request.interrupt, request.interrupt_expected),
            Waiter::new(request.gate, request.gate_expected),
        ];
        loop {
            match call_waitv(&waiters, request.deadline) {
                Ok(0) => return HostFutexResult::Woken,
                Ok(1 | 2) => return HostFutexResult::Interrupted,
                Err(libc::ETIMEDOUT) => return HostFutexResult::TimedOut,
                Err(libc::EAGAIN) => {
                    if load(request.gate) != request.gate_expected
                        || load(request.interrupt) != request.interrupt_expected
                    {
                        return HostFutexResult::Interrupted;
                    }
                    if load(request.address) != request.expected {
                        return HostFutexResult::Woken;
                    }
                    if request
                        .deadline
                        .is_some_and(|deadline| Instant::now() >= deadline)
                    {
                        return HostFutexResult::TimedOut;
                    }
                }
                // A Unix signal can interrupt the host syscall independently
                // of a WASIX signal. Retry after rechecking all generations.
                Err(libc::EINTR) => {
                    if load(request.gate) != request.gate_expected
                        || load(request.interrupt) != request.interrupt_expected
                    {
                        return HostFutexResult::Interrupted;
                    }
                }
                other => return disable_after_error(other),
            }
        }
    }

    /// Gives up on the backend for the rest of the process after a result
    /// the wait cannot interpret: an errno it does not handle, or a woken
    /// index beyond the words it passed. The guest falls back to Wasmer's
    /// async wait, and every later wait does the same without asking. Only
    /// the wait that turns the backend off says so.
    fn disable_after_error(result: Result<usize, i32>) -> HostFutexResult {
        if SUPPORT.swap(DISABLED, Ordering::AcqRel) == SUPPORTED {
            match result {
                Ok(index) => tracing::warn!(
                    index,
                    "futex_waitv woke an unknown word; disabling the host futex backend"
                ),
                Err(errno) => tracing::warn!(
                    errno,
                    error = %io::Error::from_raw_os_error(errno),
                    "futex_waitv failed; disabling the host futex backend"
                ),
            }
        }
        HostFutexResult::Unavailable
    }

    fn load(address: *const u32) -> u32 {
        // SAFETY: the hook contract supplies a live and aligned 32-bit word.
        unsafe { AtomicU32::from_ptr(address.cast_mut()) }.load(Ordering::Acquire)
    }

    fn call_waitv(waiters: &[Waiter], deadline: Option<Instant>) -> Result<usize, i32> {
        let timeout = deadline.map(absolute_timeout).transpose()?;
        let timeout = timeout
            .as_ref()
            .map_or(std::ptr::null(), std::ptr::from_ref);
        let waiter_count = libc::c_uint::try_from(waiters.len()).map_err(|_| libc::EOVERFLOW)?;
        // SAFETY: every pointer is live for this call, the array has the
        // kernel ABI layout above, and the timeout uses CLOCK_MONOTONIC.
        let result = unsafe {
            libc::syscall(
                libc::SYS_futex_waitv,
                waiters.as_ptr(),
                waiter_count,
                0 as libc::c_uint,
                timeout,
                libc::CLOCK_MONOTONIC,
            )
        };
        if result >= 0 {
            usize::try_from(result).map_err(|_| libc::EOVERFLOW)
        } else {
            Err(io::Error::last_os_error()
                .raw_os_error()
                .unwrap_or(libc::EIO))
        }
    }

    fn absolute_timeout(deadline: Instant) -> Result<libc::timespec, i32> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let mut now = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        // SAFETY: `now` is a valid output pointer.
        let result = unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &raw mut now) };
        if result != 0 {
            return Err(io::Error::last_os_error()
                .raw_os_error()
                .unwrap_or(libc::EIO));
        }
        let seconds = libc::time_t::try_from(remaining.as_secs()).unwrap_or(libc::time_t::MAX);
        let nanos = libc::c_long::from(remaining.subsec_nanos());
        now.tv_sec = now.tv_sec.saturating_add(seconds);
        now.tv_nsec += nanos;
        if now.tv_nsec >= 1_000_000_000 {
            now.tv_sec = now.tv_sec.saturating_add(1);
            now.tv_nsec -= 1_000_000_000;
        }
        Ok(now)
    }

    fn wake(address: *const u32, count: u32) -> u32 {
        // Without futex_waitv no direct waiter was ever parked, so there is
        // nothing to wake and no syscall to spend on it.
        if count == 0 || SUPPORT.load(Ordering::Acquire) == UNAVAILABLE {
            return 0;
        }
        let count = libc::c_int::try_from(count).unwrap_or(libc::c_int::MAX);
        // SAFETY: the hook contract supplies a live and aligned word.
        //
        // FUTEX_WAKE predates futex_waitv by many years, so this still works
        // once the backend is disabled, when a waiter parked before that may
        // need it.
        let result = unsafe {
            libc::syscall(
                libc::SYS_futex,
                address,
                libc::FUTEX_WAKE | libc::FUTEX_PRIVATE_FLAG,
                count,
            )
        };
        u32::try_from(result).unwrap_or(0)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::Arc;
        use std::thread;
        use std::time::Duration;

        #[repr(C)]
        struct Words {
            guest: AtomicU32,
            interrupt: AtomicU32,
            gate: AtomicU32,
        }

        fn request(words: &Words, deadline: Option<Instant>) -> HostFutexWait {
            HostFutexWait {
                address: (&raw const words.guest).cast(),
                expected: 0,
                interrupt: (&raw const words.interrupt).cast(),
                interrupt_expected: 0,
                gate: (&raw const words.gate).cast(),
                gate_expected: 0,
                deadline,
            }
        }

        #[test]
        fn probe_is_repeatable() {
            assert_eq!(probe_futex_waitv(), probe_futex_waitv());
        }

        #[test]
        fn vector_wait_observes_each_word_and_timeout() {
            if !probe_futex_waitv() {
                return;
            }
            for (index, expected) in [
                (0, HostFutexResult::Woken),
                (1, HostFutexResult::Interrupted),
                (2, HostFutexResult::Interrupted),
            ] {
                let words = Arc::new(Words {
                    guest: AtomicU32::new(0),
                    interrupt: AtomicU32::new(0),
                    gate: AtomicU32::new(0),
                });
                let waiter_words = words.clone();
                let waiter = thread::spawn(move || {
                    wait(request(
                        &waiter_words,
                        Some(Instant::now() + Duration::from_secs(2)),
                    ))
                });
                thread::sleep(Duration::from_millis(10));
                let word = [&words.guest, &words.interrupt, &words.gate][index];
                word.fetch_add(1, Ordering::Release);
                wake(std::ptr::from_ref(word).cast(), 1);
                assert_eq!(waiter.join().unwrap(), expected);
            }

            let words = Words {
                guest: AtomicU32::new(0),
                interrupt: AtomicU32::new(0),
                gate: AtomicU32::new(0),
            };
            assert_eq!(
                wait(request(
                    &words,
                    Some(Instant::now() + Duration::from_millis(10)),
                )),
                HostFutexResult::TimedOut
            );
        }
    }
}

pub(super) fn install() {
    #[cfg(target_os = "linux")]
    linux::install();
}
