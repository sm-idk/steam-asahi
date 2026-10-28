//! Bounded Unix descriptor receive and complete stream writes

use std::fs::File;
use std::io::{self, IoSlice};
use std::mem::{size_of, zeroed};
use std::os::fd::{FromRawFd, RawFd};
use std::time::{Duration, Instant};

use nix::libc;
use nix::sys::socket::{sendmsg, shutdown, ControlMessage, MsgFlags, Shutdown};

pub(crate) const MAX_DESCRIPTORS: usize = 253;

pub(crate) fn receive(
    fd: RawFd,
    bytes: &mut [u8],
    max_descriptors: usize,
    flags: libc::c_int,
) -> io::Result<(usize, Vec<File>)> {
    // Word alignment is required for cmsghdr; this also holds Linux's full
    // SCM_MAX_FD payload, so excess descriptors can be closed on rejection
    let mut ancillary = [0usize; 256];
    let mut vector = libc::iovec {
        iov_base: bytes.as_mut_ptr().cast(),
        iov_len: bytes.len(),
    };
    // SAFETY: zero is a valid empty msghdr; pointers below outlive recvmsg
    let mut message: libc::msghdr = unsafe { zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = ancillary.as_mut_ptr().cast();
    message.msg_controllen = size_of::<[usize; 256]>();
    // SAFETY: every receive buffer is writable and lives through the syscall
    let length = unsafe {
        libc::recvmsg(fd, &mut message, flags | libc::MSG_CMSG_CLOEXEC)
    };
    if length < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut descriptors = Vec::new();
    let mut invalid = false;
    // SAFETY: recvmsg initialized the bounded ancillary region. Parse even
    // truncated records to close every descriptor the kernel installed
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&message);
        while !header.is_null() {
            let start = header as usize;
            let base = message.msg_control as usize;
            let minimum = libc::CMSG_LEN(0) as usize;
            if start < base
                || start - base > message.msg_controllen
                || size_of::<libc::cmsghdr>()
                    > message.msg_controllen - (start - base)
                || (*header).cmsg_len < minimum
                || (*header).cmsg_len > message.msg_controllen - (start - base)
            {
                invalid = true;
                break;
            }
            if (*header).cmsg_level == libc::SOL_SOCKET
                && (*header).cmsg_type == libc::SCM_RIGHTS
            {
                let payload = (*header).cmsg_len - minimum;
                if payload % size_of::<RawFd>() != 0 {
                    invalid = true;
                }
                let data = libc::CMSG_DATA(header).cast::<RawFd>();
                for index in 0..payload / size_of::<RawFd>() {
                    let descriptor = data.add(index).read_unaligned();
                    if descriptor < 0 {
                        invalid = true;
                    } else {
                        descriptors.push(File::from_raw_fd(descriptor));
                    }
                }
            } else {
                invalid = true;
            }
            header = libc::CMSG_NXTHDR(&message, header);
        }
    }
    if invalid
        || message.msg_flags & (libc::MSG_TRUNC | libc::MSG_CTRUNC) != 0
        || descriptors.len() > max_descriptors
    {
        return Err(io::Error::from_raw_os_error(libc::EMSGSIZE));
    }
    Ok((length as usize, descriptors))
}

#[allow(dead_code)]
pub(crate) fn send_all(
    fd: RawFd,
    data: &[u8],
    descriptors: &[RawFd],
) -> io::Result<usize> {
    if data.is_empty() {
        return if descriptors.is_empty() {
            Ok(0)
        } else {
            Err(io::Error::from_raw_os_error(libc::EINVAL))
        };
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut offset = 0;
    let result = (|| {
        while offset < data.len() {
            if Instant::now() >= deadline {
                return Err(io::Error::from_raw_os_error(libc::ETIMEDOUT));
            }
            let rights = [ControlMessage::ScmRights(descriptors)];
            let control = if offset == 0 && !descriptors.is_empty() {
                &rights[..]
            } else {
                &[]
            };
            match sendmsg::<()>(
                fd,
                &[IoSlice::new(&data[offset..])],
                control,
                MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_NOSIGNAL,
                None,
            ) {
                Ok(0) => return Err(io::Error::from_raw_os_error(libc::EPIPE)),
                Ok(length) => offset += length,
                Err(nix::errno::Errno::EINTR) => continue,
                Err(nix::errno::Errno::EAGAIN) => {
                    let remaining =
                        deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(io::Error::from_raw_os_error(
                            libc::ETIMEDOUT,
                        ));
                    }
                    let mut event = libc::pollfd {
                        fd,
                        events: libc::POLLOUT,
                        revents: 0,
                    };
                    let timeout =
                        remaining.as_millis().clamp(1, 100) as libc::c_int;
                    // SAFETY: event is initialized and writable for one record
                    let polled = unsafe { libc::poll(&mut event, 1, timeout) };
                    if polled < 0 {
                        let error = io::Error::last_os_error();
                        if error.kind() == io::ErrorKind::Interrupted {
                            continue;
                        }
                        return Err(error);
                    }
                    if event.revents
                        & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL)
                        != 0
                    {
                        return Err(io::Error::from_raw_os_error(libc::EPIPE));
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
        Ok(offset)
    })();
    if result.is_err() {
        // A partial failed message cannot be safely followed by another one
        // Shutdown also wakes blocked readers and pending revocation cleanup
        let _ = shutdown(fd, Shutdown::Both);
    }
    result
}
