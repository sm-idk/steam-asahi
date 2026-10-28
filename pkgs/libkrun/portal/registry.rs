//! VM-local registration of connected portal-authorized PipeWire sockets
//!
//! SOCK_SEQPACKET control records are 28 bytes: KPW1, operation u32 LE,
//! status i32 LE, token [u8; 16]. Requests have status zero; replies set
//! operation bit 31 and return zero or a negative errno
//!
//! PING=0 has no descriptors/token. REGISTER=1 carries exactly one connected
//! Unix stream FD and returns a random token. REVOKE=2 takes that token with
//! no FD. The registering control connection must stay open for the session
//! lifetime; disconnect revokes all of its pending and claimed connections
//! STATUS=3 returns success only after GPU initialization has finished;
//! it returns EAGAIN while pending and never consumes or transfers the token

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{
    FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt,
};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use nix::sys::socket::{
    accept4, bind, connect, getpeername, getsockopt, listen, send, shutdown,
    socket, sockopt, AddressFamily, Backlog, MsgFlags, Shutdown, SockFlag,
    SockType, UnixAddr,
};

const FRAME_BYTES: usize = 28;
const MAX_PEERS: usize = 64;
const MAX_REMOTES: usize = 128;
const PENDING_TTL: Duration = Duration::from_secs(30);
const PING: u32 = 0;
const REGISTER: u32 = 1;
const REVOKE: u32 = 2;
const STATUS: u32 = 3;
const REPLY: u32 = 1 << 31;
type Token = [u8; 16];

fn failure(code: i32) -> io::Error {
    io::Error::from_raw_os_error(code)
}

fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct Entry {
    owner: u64,
    socket: File,
    expires: Option<Instant>,
    claimed: bool,
    ready: bool,
}

impl Entry {
    fn stop(self) {
        // Shutdown reaches every duplicate of this exact connected stream
        let _ = shutdown(self.socket.as_raw_fd(), Shutdown::Both);
    }
}

struct State {
    entries: BTreeMap<Token, Entry>,
    live: bool,
}

impl State {
    fn revoke(&mut self, token: &Token) {
        if let Some(entry) = self.entries.remove(token) {
            entry.stop();
        }
    }

    fn revoke_owner(&mut self, owner: u64) {
        let tokens: Vec<_> = self
            .entries
            .iter()
            .filter_map(|(token, entry)| {
                (entry.owner == owner).then_some(*token)
            })
            .collect();
        for token in tokens {
            self.revoke(&token);
        }
    }

    fn expire(&mut self) {
        let now = Instant::now();
        let tokens: Vec<_> = self
            .entries
            .iter()
            .filter_map(|(token, entry)| {
                entry
                    .expires
                    .filter(|deadline| *deadline <= now)
                    .map(|_| *token)
            })
            .collect();
        for token in tokens {
            self.revoke(&token);
        }
    }

    fn stop(&mut self) {
        self.live = false;
        for (_, entry) in std::mem::take(&mut self.entries) {
            entry.stop();
        }
    }
}

pub(super) struct PortalLease {
    token: Token,
    state: Weak<Mutex<State>>,
}

pub(super) struct PortalReadiness {
    token: Token,
    state: Weak<Mutex<State>>,
}

impl PortalReadiness {
    pub(super) fn ready(&self) {
        if let Some(state) = self.state.upgrade() {
            let mut state = lock(&state);
            if let Some(entry) = state.entries.get_mut(&self.token) {
                entry.ready = true;
            }
        }
    }
}

impl PortalLease {
    pub(super) fn readiness(&self) -> PortalReadiness {
        PortalReadiness {
            token: self.token,
            state: self.state.clone(),
        }
    }
}

impl Drop for PortalLease {
    fn drop(&mut self) {
        if let Some(state) = self.state.upgrade() {
            lock(&state).revoke(&self.token);
        }
    }
}

struct Listener {
    socket: OwnedFd,
    path: PathBuf,
    identity: (u64, u64),
    _lock: File,
}

impl Listener {
    fn new(path: PathBuf) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(failure(libc::EINVAL));
        }
        let parent = path.parent().ok_or_else(|| failure(libc::EINVAL))?;
        let metadata = fs::metadata(parent)?;
        // SAFETY: geteuid has no pointer arguments or ownership effects
        let uid = unsafe { libc::geteuid() };
        if !metadata.is_dir()
            || metadata.uid() != uid
            || metadata.mode() & 0o077 != 0
        {
            return Err(failure(libc::EACCES));
        }
        let owner_lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(path.with_extension("lock"))?;
        // SAFETY: owner_lock is live and the flags do not borrow memory
        if unsafe {
            libc::flock(owner_lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB)
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        match fs::symlink_metadata(&path) {
            Ok(old) => {
                if !old.file_type().is_socket() || old.uid() != uid {
                    return Err(failure(libc::EACCES));
                }
                let probe = socket(
                    AddressFamily::Unix,
                    SockType::SeqPacket,
                    SockFlag::SOCK_CLOEXEC | SockFlag::SOCK_NONBLOCK,
                    None,
                )?;
                match connect(probe.as_raw_fd(), &UnixAddr::new(&path)?) {
                    Err(nix::errno::Errno::ECONNREFUSED) => {
                        fs::remove_file(&path)?
                    }
                    Err(nix::errno::Errno::ENOENT) => (),
                    Err(error) => return Err(error.into()),
                    Ok(()) => return Err(failure(libc::EADDRINUSE)),
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(error),
        }
        let socket = socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_CLOEXEC | SockFlag::SOCK_NONBLOCK,
            None,
        )?;
        bind(socket.as_raw_fd(), &UnixAddr::new(&path)?)?;
        let metadata = fs::symlink_metadata(&path)?;
        let listener = Self {
            socket,
            path,
            identity: (metadata.dev(), metadata.ino()),
            _lock: owner_lock,
        };
        fs::set_permissions(&listener.path, fs::Permissions::from_mode(0o600))?;
        listen(&listener.socket, Backlog::new(MAX_PEERS as i32)?)?;
        Ok(listener)
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path) {
            if (metadata.dev(), metadata.ino()) == self.identity {
                let _ = fs::remove_file(&self.path);
            }
        }
        // Keep the lock inode: unlinking it could split competing owners
    }
}

pub(super) struct PortalRegistry {
    state: Arc<Mutex<State>>,
    wake: UnixStream,
    worker: Option<JoinHandle<()>>,
}

impl PortalRegistry {
    pub(super) fn from_environment() -> Option<Arc<Self>> {
        let path = std::env::var_os("KRUN_PIPEWIRE_REGISTRY")?;
        match Self::new(PathBuf::from(path)) {
            Ok(registry) => Some(Arc::new(registry)),
            Err(error) => {
                log::warn!("portal PipeWire registration unavailable: {error}");
                None
            }
        }
    }

    fn new(path: PathBuf) -> io::Result<Self> {
        let listener = Listener::new(path)?;
        let (wake, worker_wake) = UnixStream::pair()?;
        wake.set_nonblocking(true)?;
        worker_wake.set_nonblocking(true)?;
        let state = Arc::new(Mutex::new(State {
            entries: BTreeMap::new(),
            live: true,
        }));
        let worker_state = state.clone();
        let worker = thread::Builder::new()
            .name("portal remotes".into())
            .spawn(move || {
                let result = run(&listener, worker_wake, &worker_state);
                lock(&worker_state).stop();
                if let Err(error) = result {
                    log::warn!("portal PipeWire registration stopped: {error}");
                }
                // Keep the socket lock through remote revocation
                drop(listener);
            })?;
        Ok(Self {
            state,
            wake,
            worker: Some(worker),
        })
    }

    pub(super) fn claim(
        &self,
        token: Token,
    ) -> io::Result<(File, PortalLease)> {
        let mut state = lock(&self.state);
        if !state.live {
            return Err(failure(libc::ENOTCONN));
        }
        state.expire();
        let entry = state
            .entries
            .get_mut(&token)
            .ok_or_else(|| failure(libc::ENOENT))?;
        if entry.claimed {
            return Err(failure(libc::EALREADY));
        }
        // Transfer the original registered FD; keep a duplicate for revocation
        let cancellation = entry.socket.try_clone()?;
        let connection = std::mem::replace(&mut entry.socket, cancellation);
        entry.claimed = true;
        entry.expires = None;
        Ok((
            connection,
            PortalLease {
                token,
                state: Arc::downgrade(&self.state),
            },
        ))
    }
}

impl Drop for PortalRegistry {
    fn drop(&mut self) {
        lock(&self.state).stop();
        let _ = self.wake.write(&[1]);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

struct Packet {
    operation: u32,
    token: Token,
    descriptors: Vec<File>,
}

fn receive(fd: RawFd) -> io::Result<Packet> {
    let mut bytes = [0u8; FRAME_BYTES + 1];
    let (length, descriptors) = super::sys::unix_stream::receive(
        fd,
        &mut bytes,
        super::sys::unix_stream::MAX_DESCRIPTORS,
        libc::MSG_DONTWAIT,
    )?;
    if length != FRAME_BYTES || &bytes[..4] != b"KPW1" || bytes[8..12] != [0; 4]
    {
        return Err(failure(libc::EPROTO));
    }
    let mut token = [0; 16];
    token.copy_from_slice(&bytes[12..28]);
    Ok(Packet {
        operation: u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
        token,
        descriptors,
    })
}

fn execute(
    packet: &mut Packet,
    owner: u64,
    state: &Mutex<State>,
    random: &mut File,
) -> io::Result<Token> {
    let mut state = lock(state);
    if !state.live {
        return Err(failure(libc::ENOTCONN));
    }
    state.expire();
    match packet.operation {
        PING if packet.descriptors.is_empty() && packet.token == [0; 16] => {
            Ok([0; 16])
        }
        REGISTER
            if packet.descriptors.len() == 1 && packet.token == [0; 16] =>
        {
            if state.entries.len() >= MAX_REMOTES {
                return Err(failure(libc::ENOSPC));
            }
            let descriptor = packet
                .descriptors
                .pop()
                .ok_or_else(|| failure(libc::EINVAL))?;
            if getsockopt(&descriptor, sockopt::SockType)? != SockType::Stream {
                return Err(failure(libc::EPROTOTYPE));
            }
            let _ = getpeername::<UnixAddr>(descriptor.as_raw_fd())?;
            let mut token = [0; 16];
            for _ in 0..8 {
                random.read_exact(&mut token)?;
                if token != [0; 16] && !state.entries.contains_key(&token) {
                    state.entries.insert(
                        token,
                        Entry {
                            owner,
                            socket: descriptor,
                            expires: Some(Instant::now() + PENDING_TTL),
                            claimed: false,
                            ready: false,
                        },
                    );
                    return Ok(token);
                }
            }
            Err(failure(libc::EAGAIN))
        }
        REVOKE if packet.descriptors.is_empty() => {
            let entry = state
                .entries
                .get(&packet.token)
                .ok_or_else(|| failure(libc::ENOENT))?;
            if entry.owner != owner {
                return Err(failure(libc::EACCES));
            }
            state.revoke(&packet.token);
            Ok(packet.token)
        }
        STATUS if packet.descriptors.is_empty() => {
            let entry = state
                .entries
                .get(&packet.token)
                .ok_or_else(|| failure(libc::ENOENT))?;
            if entry.owner != owner {
                return Err(failure(libc::EACCES));
            }
            if !entry.ready {
                return Err(failure(libc::EAGAIN));
            }
            Ok(packet.token)
        }
        _ => Err(failure(libc::EINVAL)),
    }
}

fn reply(
    fd: RawFd,
    operation: u32,
    status: i32,
    token: Token,
) -> io::Result<()> {
    let mut frame = [0u8; FRAME_BYTES];
    frame[..4].copy_from_slice(b"KPW1");
    frame[4..8].copy_from_slice(&(operation | REPLY).to_le_bytes());
    frame[8..12].copy_from_slice(&status.to_le_bytes());
    frame[12..].copy_from_slice(&token);
    if send(fd, &frame, MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_NOSIGNAL)?
        != FRAME_BYTES
    {
        return Err(failure(libc::EIO));
    }
    Ok(())
}

fn run(
    listener: &Listener,
    wake: UnixStream,
    state: &Mutex<State>,
) -> io::Result<()> {
    let mut peers = BTreeMap::<u64, OwnedFd>::new();
    let mut next_owner = 1u64;
    let mut random = File::open("/dev/urandom")?;
    // SAFETY: geteuid has no pointer arguments or ownership effects
    let uid = unsafe { libc::geteuid() };
    loop {
        let owners: Vec<_> = peers.keys().copied().collect();
        let mut events: Vec<_> =
            [wake.as_raw_fd(), listener.socket.as_raw_fd()]
                .into_iter()
                .chain(peers.values().map(AsRawFd::as_raw_fd))
                .map(|fd| libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                })
                .collect();
        // SAFETY: events is initialized and writable for its declared length
        let result = unsafe {
            libc::poll(events.as_mut_ptr(), events.len() as libc::nfds_t, 1000)
        };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if events[0].revents != 0 {
            return Ok(());
        }
        if events[1].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL)
            != 0
        {
            return Err(failure(libc::ENOTCONN));
        }
        if events[1].revents & libc::POLLIN != 0 {
            match accept4(
                listener.socket.as_raw_fd(),
                SockFlag::SOCK_CLOEXEC | SockFlag::SOCK_NONBLOCK,
            ) {
                Ok(fd) => {
                    // SAFETY: accept4 returned a new owned descriptor
                    let peer = unsafe { OwnedFd::from_raw_fd(fd) };
                    if peers.len() < MAX_PEERS
                        && getsockopt(&peer, sockopt::PeerCredentials)?.uid()
                            == uid
                    {
                        peers.insert(next_owner, peer);
                        next_owner = next_owner
                            .checked_add(1)
                            .ok_or_else(|| failure(libc::ENOSPC))?;
                    }
                }
                Err(nix::errno::Errno::EAGAIN | nix::errno::Errno::EINTR) => (),
                Err(error) => return Err(error.into()),
            }
        }
        for (owner, event) in owners.into_iter().zip(events.into_iter().skip(2))
        {
            if event.revents == 0 {
                continue;
            }
            let mut keep = event.revents
                & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL)
                == 0;
            if event.revents & libc::POLLIN != 0 {
                match receive(event.fd) {
                    Ok(mut packet) => {
                        let (status, token) = match execute(
                            &mut packet,
                            owner,
                            state,
                            &mut random,
                        ) {
                            Ok(token) => (0, token),
                            Err(error) => (
                                -error.raw_os_error().unwrap_or(libc::EINVAL),
                                packet.token,
                            ),
                        };
                        keep &=
                            reply(event.fd, packet.operation, status, token)
                                .is_ok();
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock
                                | io::ErrorKind::Interrupted
                        ) =>
                    {
                        ()
                    }
                    Err(_) => keep = false,
                }
            }
            if !keep {
                peers.remove(&owner);
                lock(state).revoke_owner(owner);
            }
        }
        lock(state).expire();
    }
}
