//! Networking for the guest: the listening socket comes from the manager.
//!
//! Stock wasmer-wasix binds sockets itself. Here the manager creates the
//! guest's listening socket and passes it over the control channel; when
//! the guest binds its `listen_port` it gets that socket, and a forked child
//! replaces it with the socket passed for the child.
//!
//! A bind on any other port gets a socket that reports the address it was
//! given but can neither listen nor connect: a clone must never bind a real
//! host port, and wasix-libc decides the byte order of every port it reads
//! back by binding a throwaway socket and reading its address, so refusing the
//! bind outright would leave the guest with swapped ports. Outbound
//! connections (the initializer's) go to the host network unchanged.
//!
//! Every connection the guest accepts is handed over wrapped in a guard
//! that records its descriptor and forgets it when the guest drops the
//! stream, so a freeze can end the template's network presence exactly:
//! `shut_down_sockets` stops the listener and shuts down each connection
//! the guest still holds.

use std::{
    collections::HashSet,
    mem::MaybeUninit,
    net::{Shutdown, SocketAddr, TcpListener},
    os::fd::{AsRawFd, RawFd},
    sync::{Arc, Mutex},
    task::{Context, Poll},
    time::Duration,
};

use anyhow::{Context as _, Result, bail};
use nix::errno::Errno;
use virtual_mio::InterestHandler;
use virtual_net::{
    NetworkError, SocketStatus, VirtualConnectedSocket, VirtualIoSource, VirtualNetworking,
    VirtualSocket, VirtualTcpBoundSocket, VirtualTcpListener, VirtualTcpSocket,
    host::{LocalNetworking, LocalTcpListener, LocalTcpStream},
};

type SharedListener = Arc<Mutex<LocalTcpListener>>;

/// The descriptors of the connections the guest holds, kept by the guard
/// in every `TrackedStream`.
type Connections = Arc<Mutex<HashSet<RawFd>>>;

/// See the module documentation.
pub struct HostNetworking {
    inner: LocalNetworking,
    listen_port: u16,
    /// The passed socket, until the guest binds.
    passed: Mutex<Option<TcpListener>>,
    /// The guest's listener once it has bound.
    adopted: Mutex<Option<SharedListener>>,
    /// Called once the guest listens on the passed socket.
    on_listen: Arc<dyn Fn() + Send + Sync>,
    connections: Connections,
}

impl std::fmt::Debug for HostNetworking {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostNetworking")
            .field("listen_port", &self.listen_port)
            .field("passed", &self.passed)
            .field("adopted", &self.adopted)
            .finish_non_exhaustive()
    }
}

impl HostNetworking {
    /// Networking for a guest that listens on `listen_port`; `on_listen` is
    /// called from the guest thread when its listen completes.
    #[must_use]
    pub fn new(listen_port: u16, on_listen: Arc<dyn Fn() + Send + Sync>) -> Self {
        Self {
            inner: LocalNetworking::new(),
            listen_port,
            passed: Mutex::new(None),
            adopted: Mutex::new(None),
            on_listen,
            connections: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    /// The selector every socket registers with.
    #[must_use]
    pub fn selector(&self) -> &Arc<virtual_mio::Selector> {
        self.inner.selector()
    }

    /// Stores the socket the guest gets when it binds `listen_port`.
    ///
    /// # Errors
    ///
    /// Fails if the guest has already bound.
    pub fn set_listener(&self, listener: TcpListener) -> Result<()> {
        if self
            .adopted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
        {
            bail!("the guest has already bound its listening socket");
        }
        *self
            .passed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(listener);
        Ok(())
    }

    /// In a forked child: makes the guest's listener use `listener` instead
    /// of the socket inherited from the parent.
    ///
    /// # Errors
    ///
    /// Fails if the guest has not bound yet or the swap fails.
    pub fn replace_listener(&self, listener: TcpListener) -> Result<()> {
        let adopted = self
            .adopted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(shared) = adopted.as_ref() else {
            bail!("the guest has not bound its listening socket");
        };
        shared
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replace_std_listener(listener)
            .context("failed to replace the guest's listening socket")
    }

    /// Ends the guest's network presence, for a freeze: the listener stops
    /// accepting (a listening socket shut down for reading refuses new
    /// connections and resets those waiting in its backlog) and every
    /// connection the guest holds is shut down both ways, so its peer sees
    /// the end. The descriptors stay open for the objects owning them.
    ///
    /// # Errors
    ///
    /// Fails if a shutdown fails for a reason other than the socket not
    /// being connected.
    pub fn shut_down_sockets(&self) -> Result<()> {
        let shut_down = |fd: RawFd, how| match nix::sys::socket::shutdown(fd, how) {
            Ok(()) | Err(Errno::ENOTCONN) => Ok(()),
            Err(err) => Err(err).with_context(|| format!("failed to shut down socket {fd}")),
        };
        if let Some(shared) = self
            .adopted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            let fd = shared
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_raw_fd();
            shut_down(fd, nix::sys::socket::Shutdown::Read)?;
        }
        for &fd in self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
        {
            shut_down(fd, nix::sys::socket::Shutdown::Both)?;
        }
        Ok(())
    }

    /// The address of the socket the guest listens (or will listen) on.
    ///
    /// # Errors
    ///
    /// Fails if no socket was passed.
    pub fn endpoint(&self) -> Result<SocketAddr> {
        if let Some(shared) = self
            .adopted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            return shared
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .addr_local()
                .map_err(|err| anyhow::anyhow!("listener address: {err}"));
        }
        match self
            .passed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            Some(listener) => listener
                .local_addr()
                .context("passed listener has no address"),
            None => bail!("no listening socket was passed"),
        }
    }
}

#[async_trait::async_trait]
impl VirtualNetworking for HostNetworking {
    async fn bind_tcp(
        &self,
        addr: SocketAddr,
        _only_v6: bool,
        _reuse_port: bool,
        _reuse_addr: bool,
    ) -> virtual_net::Result<Box<dyn VirtualTcpBoundSocket + Sync>> {
        if addr.port() != self.listen_port {
            return Ok(Box::new(UnservedBoundSocket { addr }));
        }
        let listener = self
            .passed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .ok_or(NetworkError::AddressInUse)?;
        let listener = LocalTcpListener::from_std_listener(listener, self.selector().clone())
            .map_err(virtual_net::io_err_into_net_error)?;
        let shared = Arc::new(Mutex::new(listener));
        *self
            .adopted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(shared.clone());
        Ok(Box::new(PassedBoundSocket {
            listener: Some(shared),
            on_listen: self.on_listen.clone(),
            connections: self.connections.clone(),
        }))
    }

    async fn listen_tcp(
        &self,
        addr: SocketAddr,
        only_v6: bool,
        reuse_port: bool,
        reuse_addr: bool,
    ) -> virtual_net::Result<Box<dyn VirtualTcpListener + Sync>> {
        self.bind_tcp(addr, only_v6, reuse_port, reuse_addr)
            .await?
            .listen()
    }

    async fn connect_tcp(
        &self,
        addr: SocketAddr,
        peer: SocketAddr,
    ) -> virtual_net::Result<Box<dyn VirtualTcpSocket + Sync>> {
        self.inner.connect_tcp(addr, peer).await
    }

    async fn resolve(
        &self,
        host: &str,
        port: Option<u16>,
        dns_server: Option<std::net::IpAddr>,
    ) -> virtual_net::Result<Vec<std::net::IpAddr>> {
        self.inner.resolve(host, port, dns_server).await
    }
}

/// The passed socket between the guest's bind and its listen.
struct PassedBoundSocket {
    listener: Option<SharedListener>,
    on_listen: Arc<dyn Fn() + Send + Sync>,
    connections: Connections,
}

impl std::fmt::Debug for PassedBoundSocket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PassedBoundSocket")
            .field("listener", &self.listener)
            .finish_non_exhaustive()
    }
}

impl VirtualTcpBoundSocket for PassedBoundSocket {
    fn addr_local(&self) -> virtual_net::Result<SocketAddr> {
        let listener = self.listener.as_ref().ok_or(NetworkError::InvalidFd)?;
        listener
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .addr_local()
    }

    fn listen(&mut self) -> virtual_net::Result<Box<dyn VirtualTcpListener + Sync>> {
        let listener = self.listener.take().ok_or(NetworkError::InvalidFd)?;
        (self.on_listen)();
        Ok(Box::new(PassedListener {
            inner: listener,
            connections: self.connections.clone(),
        }))
    }

    fn connect(
        &mut self,
        _peer: SocketAddr,
    ) -> virtual_net::Result<Box<dyn VirtualTcpSocket + Sync>> {
        Err(NetworkError::Unsupported)
    }

    fn set_ttl(&mut self, ttl: u32) -> virtual_net::Result<()> {
        let listener = self.listener.as_ref().ok_or(NetworkError::InvalidFd)?;
        listener
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .set_ttl(u8::try_from(ttl).map_err(|_| NetworkError::InvalidInput)?)
    }

    fn ttl(&self) -> virtual_net::Result<u32> {
        let listener = self.listener.as_ref().ok_or(NetworkError::InvalidFd)?;
        listener
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .ttl()
            .map(u32::from)
    }
}

/// A bind the host does not serve: it answers for its address, which is what
/// wasix-libc's port byte-order probe needs, and refuses everything else.
#[derive(Debug)]
struct UnservedBoundSocket {
    addr: SocketAddr,
}

impl VirtualTcpBoundSocket for UnservedBoundSocket {
    fn addr_local(&self) -> virtual_net::Result<SocketAddr> {
        Ok(self.addr)
    }

    fn listen(&mut self) -> virtual_net::Result<Box<dyn VirtualTcpListener + Sync>> {
        Err(NetworkError::PermissionDenied)
    }

    fn connect(
        &mut self,
        _peer: SocketAddr,
    ) -> virtual_net::Result<Box<dyn VirtualTcpSocket + Sync>> {
        Err(NetworkError::PermissionDenied)
    }

    fn set_ttl(&mut self, _ttl: u32) -> virtual_net::Result<()> {
        Ok(())
    }

    fn ttl(&self) -> virtual_net::Result<u32> {
        Ok(64)
    }
}

/// The guest's listener, shared with `HostNetworking` so that a forked child
/// can replace its socket.
#[derive(Debug)]
struct PassedListener {
    inner: SharedListener,
    connections: Connections,
}

impl VirtualTcpListener for PassedListener {
    fn try_accept(
        &mut self,
    ) -> virtual_net::Result<(Box<dyn VirtualTcpSocket + Sync>, SocketAddr)> {
        let (stream, addr) = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .try_accept_local()?;
        let guard = ConnectionGuard::track(stream.as_raw_fd(), &self.connections);
        Ok((
            Box::new(TrackedStream {
                _guard: guard,
                inner: stream,
            }),
            addr,
        ))
    }

    fn set_handler(
        &mut self,
        handler: Box<dyn virtual_mio::InterestHandler + Send + Sync>,
    ) -> virtual_net::Result<()> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .set_handler(handler)
    }

    fn addr_local(&self) -> virtual_net::Result<SocketAddr> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .addr_local()
    }

    fn set_ttl(&mut self, ttl: u8) -> virtual_net::Result<()> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .set_ttl(ttl)
    }

    fn ttl(&self) -> virtual_net::Result<u8> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .ttl()
    }
}

impl VirtualIoSource for PassedListener {
    fn remove_handler(&mut self) {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove_handler();
    }

    fn poll_read_ready(&mut self, cx: &mut Context<'_>) -> Poll<virtual_net::Result<usize>> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .poll_read_ready(cx)
    }

    fn poll_write_ready(&mut self, cx: &mut Context<'_>) -> Poll<virtual_net::Result<usize>> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .poll_write_ready(cx)
    }
}

/// An accepted connection as the guest holds it; its descriptor is known to
/// `HostNetworking` for as long as the guest keeps the stream.
#[derive(Debug)]
struct TrackedStream {
    /// Held for its drop; before `inner`, so the descriptor is forgotten
    /// before it is closed.
    _guard: ConnectionGuard,
    inner: LocalTcpStream,
}

/// Keeps one descriptor in `Connections` until dropped.
#[derive(Debug)]
struct ConnectionGuard {
    fd: RawFd,
    connections: Connections,
}

impl ConnectionGuard {
    fn track(fd: RawFd, connections: &Connections) -> Self {
        connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(fd);
        Self {
            fd,
            connections: connections.clone(),
        }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&self.fd);
    }
}

impl VirtualIoSource for TrackedStream {
    fn remove_handler(&mut self) {
        self.inner.remove_handler();
    }

    fn poll_read_ready(&mut self, cx: &mut Context<'_>) -> Poll<virtual_net::Result<usize>> {
        self.inner.poll_read_ready(cx)
    }

    fn poll_write_ready(&mut self, cx: &mut Context<'_>) -> Poll<virtual_net::Result<usize>> {
        self.inner.poll_write_ready(cx)
    }
}

impl VirtualSocket for TrackedStream {
    fn set_ttl(&mut self, ttl: u32) -> virtual_net::Result<()> {
        self.inner.set_ttl(ttl)
    }

    fn ttl(&self) -> virtual_net::Result<u32> {
        self.inner.ttl()
    }

    fn addr_local(&self) -> virtual_net::Result<SocketAddr> {
        self.inner.addr_local()
    }

    fn status(&self) -> virtual_net::Result<SocketStatus> {
        self.inner.status()
    }

    fn last_error(&self) -> virtual_net::Result<Option<NetworkError>> {
        self.inner.last_error()
    }

    fn set_handler(
        &mut self,
        handler: Box<dyn InterestHandler + Send + Sync>,
    ) -> virtual_net::Result<()> {
        self.inner.set_handler(handler)
    }
}

impl VirtualConnectedSocket for TrackedStream {
    fn set_linger(&mut self, linger: Option<Duration>) -> virtual_net::Result<()> {
        self.inner.set_linger(linger)
    }

    fn linger(&self) -> virtual_net::Result<Option<Duration>> {
        self.inner.linger()
    }

    fn try_send(&mut self, data: &[u8]) -> virtual_net::Result<usize> {
        self.inner.try_send(data)
    }

    fn try_flush(&mut self) -> virtual_net::Result<()> {
        self.inner.try_flush()
    }

    fn close(&mut self) -> virtual_net::Result<()> {
        self.inner.close()
    }

    fn try_recv(&mut self, buf: &mut [MaybeUninit<u8>], peek: bool) -> virtual_net::Result<usize> {
        self.inner.try_recv(buf, peek)
    }
}

impl VirtualTcpSocket for TrackedStream {
    fn set_recv_buf_size(&mut self, size: usize) -> virtual_net::Result<()> {
        self.inner.set_recv_buf_size(size)
    }

    fn recv_buf_size(&self) -> virtual_net::Result<usize> {
        self.inner.recv_buf_size()
    }

    fn set_send_buf_size(&mut self, size: usize) -> virtual_net::Result<()> {
        self.inner.set_send_buf_size(size)
    }

    fn send_buf_size(&self) -> virtual_net::Result<usize> {
        self.inner.send_buf_size()
    }

    fn set_nodelay(&mut self, nodelay: bool) -> virtual_net::Result<()> {
        self.inner.set_nodelay(nodelay)
    }

    fn nodelay(&self) -> virtual_net::Result<bool> {
        self.inner.nodelay()
    }

    fn set_keepalive(&mut self, keepalive: bool) -> virtual_net::Result<()> {
        self.inner.set_keepalive(keepalive)
    }

    fn keepalive(&self) -> virtual_net::Result<bool> {
        self.inner.keepalive()
    }

    fn set_dontroute(&mut self, dontroute: bool) -> virtual_net::Result<()> {
        self.inner.set_dontroute(dontroute)
    }

    fn dontroute(&self) -> virtual_net::Result<bool> {
        self.inner.dontroute()
    }

    fn addr_peer(&self) -> virtual_net::Result<SocketAddr> {
        self.inner.addr_peer()
    }

    fn shutdown(&mut self, how: Shutdown) -> virtual_net::Result<()> {
        self.inner.shutdown(how)
    }

    fn is_closed(&self) -> bool {
        self.inner.is_closed()
    }
}
