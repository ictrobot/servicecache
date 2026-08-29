//! Networking for the guest: the listening socket comes from the manager.
//!
//! Stock wasmer-wasix binds sockets itself. Here the manager creates the
//! guest's listening socket and passes it over the control channel; when
//! the guest binds its `listen_port` it gets that socket, and a forked child
//! replaces it with the socket passed for the child. Any other bind is
//! refused: a clone must never bind a real host port. Outbound connections
//! (the initializer's) go to the host network unchanged.

use std::{
    net::{SocketAddr, TcpListener},
    sync::{Arc, Mutex},
    task::{Context, Poll},
};

use anyhow::{Context as _, Result, bail};
use virtual_net::{
    NetworkError, VirtualIoSource, VirtualNetworking, VirtualTcpBoundSocket, VirtualTcpListener,
    VirtualTcpSocket,
    host::{LocalNetworking, LocalTcpListener},
};

type SharedListener = Arc<Mutex<LocalTcpListener>>;

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
            return Err(NetworkError::PermissionDenied);
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
        Ok(Box::new(PassedListener { inner: listener }))
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

/// The guest's listener, shared with `HostNetworking` so that a forked child
/// can replace its socket.
#[derive(Debug)]
struct PassedListener {
    inner: SharedListener,
}

impl VirtualTcpListener for PassedListener {
    fn try_accept(
        &mut self,
    ) -> virtual_net::Result<(Box<dyn VirtualTcpSocket + Sync>, SocketAddr)> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .try_accept()
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
