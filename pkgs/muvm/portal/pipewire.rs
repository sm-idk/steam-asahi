//! Attach one guest stream to a registered portal PipeWire remote

use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;

use anyhow::{ensure, Context, Result};
use nix::sys::socket::{getpeername, getsockopt, sockopt, SockType, UnixAddr};

fn main() -> Result<()> {
    env_logger::init();
    let mut arguments = std::env::args().skip(1);
    let argument = arguments
        .next()
        .context("usage: muvm-portal-pipewire --check | SOCKET_FD")?;
    if argument == "--check" {
        ensure!(arguments.next().is_none(), "unexpected check arguments");
        muvm::guest::bridge::pipewire::check_registered_support()?;
        println!("PORTAL_PIPEWIRE_V1");
        return Ok(());
    }
    let descriptor: i32 =
        argument.parse().context("invalid stream descriptor")?;
    ensure!(
        arguments.next().is_none() && descriptor > 2,
        "invalid stream descriptor arguments"
    );
    // SAFETY: fcntl validates the inherited descriptor without taking ownership
    let flags = unsafe { nix::libc::fcntl(descriptor, nix::libc::F_GETFD) };
    ensure!(flags >= 0, "the inherited stream descriptor is closed");
    // SAFETY: ownership of this inherited descriptor belongs to this helper
    let socket = unsafe { OwnedFd::from_raw_fd(descriptor) };
    ensure!(
        getsockopt(&socket, sockopt::SockType)? == SockType::Stream,
        "the inherited descriptor must be a Unix stream"
    );
    let _ = getpeername::<UnixAddr>(socket.as_raw_fd())?;
    // SAFETY: socket is live and fcntl does not borrow Rust memory
    if unsafe {
        nix::libc::fcntl(
            socket.as_raw_fd(),
            nix::libc::F_SETFD,
            flags | nix::libc::FD_CLOEXEC,
        )
    } < 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    // Tokens stay out of argv and logs. The parent supplies exactly one
    // token over a private stdin pipe, then closes the pipe
    let mut token = [0u8; 16];
    std::io::stdin().lock().read_exact(&mut token)?;
    ensure!(token != [0; 16], "invalid registration token");
    muvm::guest::bridge::pipewire::bridge_registered(
        UnixStream::from(socket),
        token,
    )
}
