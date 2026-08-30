//! The control protocol between the manager and a host process.
//!
//! One `SOCK_STREAM` socketpair per host, inherited at spawn. Every message
//! is one frame: a little-endian `u32` JSON length, a little-endian `u32`
//! payload length, the JSON-encoded message, then the payload (the recipe
//! bytes of `initialize`; empty otherwise). File descriptors travel as
//! `SCM_RIGHTS` ancillary data on the `sendmsg` of the frame they belong to:
//! `start` carries the guest's listening socket; `fork` carries the child's
//! control end followed by the child's listening socket.
//!
//! Manager → host: `prepare`, `start`, `initialize`, `freeze`, `fork`, `stop`.
//! Host → manager: `ready {endpoint}` once the guest listens on the passed
//! socket; `exited {run, status, pid}` when a run ends — `run` is `prepare`,
//! `guest`, `initializer`, or `child` for a reaped clone (then `pid` is set);
//! `frozen {coroutines}`; `forked {pid, endpoint}`, sent by the parent on its
//! own channel when `fork()` returns and by the child on the child's channel
//! once it serves; `error {text}` for a refused or failed request. A host
//! answers every request with exactly one reply, except that `stop` ends the
//! process without one; `exited` for the guest and for reaped children can
//! arrive at any time. The manager keeps at most one request outstanding per
//! channel, so replies pair with requests by order and carry no id.

use std::{
    io::{self, IoSlice, IoSliceMut, Read, Write},
    os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd},
    time::Duration,
};

use anyhow::{Context as _, Result, bail};
use nix::{
    poll::{PollFd, PollFlags, PollTimeout, poll},
    sys::socket::{
        AddressFamily, ControlMessage, ControlMessageOwned, MsgFlags, SockFlag, SockType, recvmsg,
        sendmsg, socketpair,
    },
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};

/// A request from the manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Prepare,
    Start,
    Initialize,
    Freeze,
    Fork,
    Stop,
}

/// Which run a completion refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Run {
    Prepare,
    Guest,
    Initializer,
    Child,
}

/// A reply, or an unsolicited event, from a host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Reply {
    Ready {
        endpoint: String,
    },
    Exited {
        run: Run,
        status: i32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<u32>,
    },
    Frozen {
        coroutines: usize,
    },
    Forked {
        pid: u32,
        endpoint: String,
    },
    Error {
        text: String,
    },
}

const HEADER_LEN: usize = 8;
const MAX_JSON_LEN: usize = 64 * 1024;
const MAX_PAYLOAD_LEN: usize = 256 * 1024 * 1024;
const MAX_FDS: usize = 4;

/// One end of a control channel.
#[derive(Debug)]
pub struct Channel {
    fd: OwnedFd,
}

/// A received frame.
#[derive(Debug)]
pub struct Frame<T> {
    pub message: T,
    pub payload: Vec<u8>,
    pub fds: Vec<OwnedFd>,
}

impl Channel {
    /// Creates a connected pair; both ends are close-on-exec.
    ///
    /// # Errors
    ///
    /// Returns the `socketpair` error.
    pub fn pair() -> Result<(Self, Self)> {
        let (a, b) = socketpair(
            AddressFamily::Unix,
            SockType::Stream,
            None,
            SockFlag::SOCK_CLOEXEC,
        )
        .context("failed to create a control socketpair")?;
        Ok((Self { fd: a }, Self { fd: b }))
    }

    /// Wraps an inherited descriptor.
    #[must_use]
    pub fn from_fd(fd: OwnedFd) -> Self {
        Self { fd }
    }

    /// The descriptor, for passing to a child.
    #[must_use]
    pub fn as_fd(&self) -> BorrowedFd<'_> {
        self.fd.as_fd()
    }

    /// Sends one frame, with `fds` attached to it.
    ///
    /// # Errors
    ///
    /// Returns an error if the message cannot be encoded or the peer is gone.
    pub fn send<T: Serialize>(&self, message: &T, payload: &[u8], fds: &[RawFd]) -> Result<()> {
        let json = serde_json::to_vec(message).context("failed to encode a control message")?;
        let json_len = u32::try_from(json.len()).context("control message too long")?;
        let payload_len = u32::try_from(payload.len()).context("control payload too long")?;
        let mut frame = Vec::with_capacity(HEADER_LEN + json.len() + payload.len());
        frame.extend_from_slice(&json_len.to_le_bytes());
        frame.extend_from_slice(&payload_len.to_le_bytes());
        frame.extend_from_slice(&json);
        frame.extend_from_slice(payload);

        let control = if fds.is_empty() {
            Vec::new()
        } else {
            vec![ControlMessage::ScmRights(fds)]
        };
        let mut sent = sendmsg::<()>(
            self.fd.as_raw_fd(),
            &[IoSlice::new(&frame)],
            &control,
            MsgFlags::MSG_NOSIGNAL,
            None,
        )
        .context("failed to send a control frame")?;
        while sent < frame.len() {
            let n = sendmsg::<()>(
                self.fd.as_raw_fd(),
                &[IoSlice::new(&frame[sent..])],
                &[],
                MsgFlags::MSG_NOSIGNAL,
                None,
            )
            .context("failed to send a control frame")?;
            if n == 0 {
                bail!("control channel closed while sending");
            }
            sent += n;
        }
        Ok(())
    }

    /// Receives one frame; `None` at end of stream.
    ///
    /// # Errors
    ///
    /// Returns an error on a truncated frame, an undecodable message, or an
    /// I/O failure.
    pub fn recv<T: DeserializeOwned>(&self) -> Result<Option<Frame<T>>> {
        let mut header = [0_u8; HEADER_LEN];
        let mut filled = 0;
        let mut fds = Vec::new();
        while filled < HEADER_LEN {
            let mut control = nix::cmsg_space!([RawFd; MAX_FDS]);
            let mut iov = [IoSliceMut::new(&mut header[filled..])];
            let message = recvmsg::<()>(
                self.fd.as_raw_fd(),
                &mut iov,
                Some(&mut control),
                MsgFlags::MSG_CMSG_CLOEXEC,
            )
            .context("failed to receive a control frame")?;
            for cmsg in message.cmsgs().context("bad control message")? {
                if let ControlMessageOwned::ScmRights(received) = cmsg {
                    fds.extend(
                        received
                            .into_iter()
                            .map(|fd| unsafe { OwnedFd::from_raw_fd(fd) }),
                    );
                }
            }
            if message.bytes == 0 {
                if filled == 0 && fds.is_empty() {
                    return Ok(None);
                }
                bail!("control channel closed inside a frame");
            }
            filled += message.bytes;
        }

        let json_len = u32::from_le_bytes([header[0], header[1], header[2], header[3]]) as usize;
        let payload_len = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
        if json_len > MAX_JSON_LEN || payload_len > MAX_PAYLOAD_LEN {
            bail!("control frame too large: {json_len} + {payload_len} bytes");
        }
        let mut json = vec![0_u8; json_len];
        self.read_exact(&mut json)?;
        let mut payload = vec![0_u8; payload_len];
        self.read_exact(&mut payload)?;
        let message =
            serde_json::from_slice(&json).context("failed to decode a control message")?;
        Ok(Some(Frame {
            message,
            payload,
            fds,
        }))
    }

    fn read_exact(&self, buffer: &mut [u8]) -> Result<()> {
        let mut file =
            std::fs::File::from(self.fd.try_clone().context("failed to dup the channel")?);
        file.read_exact(buffer)
            .context("control channel closed inside a frame")?;
        file.flush().ok();
        Ok(())
    }

    /// Waits until a frame can be read, at most `timeout` (forever if `None`).
    /// Returns `false` on timeout.
    ///
    /// # Errors
    ///
    /// Returns the `poll` error.
    pub fn wait_readable(&self, timeout: Option<Duration>) -> Result<bool> {
        let mut fds = [PollFd::new(self.fd.as_fd(), PollFlags::POLLIN)];
        let timeout = match timeout {
            Some(timeout) => PollTimeout::try_from(timeout).context("poll timeout too long")?,
            None => PollTimeout::NONE,
        };
        loop {
            match poll(&mut fds, timeout) {
                Ok(0) => return Ok(false),
                Ok(_) => return Ok(true),
                Err(nix::errno::Errno::EINTR) => {}
                Err(err) => {
                    return Err(io::Error::from(err)).context("poll on the control channel");
                }
            }
        }
    }
}

impl AsFd for Channel {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.fd.as_fd()
    }
}

impl AsRawFd for Channel {
    fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }
}

impl From<Channel> for OwnedFd {
    fn from(channel: Channel) -> Self {
        channel.fd
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip_with_payload_and_descriptors() {
        let (a, b) = Channel::pair().expect("pair");
        let (x, y) = Channel::pair().expect("second pair");
        a.send(
            &Request::Initialize,
            b"recipe bytes",
            &[x.as_raw_fd(), y.as_raw_fd()],
        )
        .expect("send");
        a.send(&Request::Stop, b"", &[]).expect("send");

        let frame: Frame<Request> = b.recv().expect("recv").expect("frame");
        assert_eq!(frame.message, Request::Initialize);
        assert_eq!(frame.payload, b"recipe bytes");
        assert_eq!(frame.fds.len(), 2);

        // The received descriptors are the same sockets: a write on `y`
        // arrives on the received copy of `x`.
        let received_x = Channel::from_fd(frame.fds.into_iter().next().expect("fd"));
        y.send(&Reply::Frozen { coroutines: 3 }, b"", &[])
            .expect("send through the original");
        let inner: Frame<Reply> = received_x.recv().expect("recv").expect("frame");
        assert_eq!(inner.message, Reply::Frozen { coroutines: 3 });

        let frame: Frame<Request> = b.recv().expect("recv").expect("frame");
        assert_eq!(frame.message, Request::Stop);
        assert!(frame.fds.is_empty());

        drop(a);
        assert!(b.recv::<Request>().expect("eof").is_none());
    }

    #[test]
    fn wait_readable_times_out_and_wakes() {
        let (a, b) = Channel::pair().expect("pair");
        assert!(
            !b.wait_readable(Some(Duration::from_millis(10)))
                .expect("poll")
        );
        a.send(&Request::Prepare, b"", &[]).expect("send");
        assert!(b.wait_readable(Some(Duration::from_secs(5))).expect("poll"));
    }
}
