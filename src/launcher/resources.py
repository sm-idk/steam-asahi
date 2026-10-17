"""Translate file resources using the requesting process's mount namespace"""

from __future__ import annotations

import ctypes
import fcntl
import hashlib
import io
import os
import re
import select
import socket
import stat
import struct
import tempfile
import warnings
from contextlib import ExitStack, suppress
from pathlib import Path
from typing import Annotated, Literal
from urllib.parse import urlsplit, urlunsplit
from uuid import uuid4

import msgspec

lazy from boltons.fileutils import atomic_save

lazy import psutil
lazy from PIL import Image

HOST_ROOT = Path("/run/muvm-host")
MAX_RESOURCE_REQUEST_BYTES = 2 * 1024 * 1024
MAX_ICON_BYTES = 1100000
MAX_ICON_SOURCE_BYTES = 4 * 1024 * 1024
MAX_ICON_SOURCE_PIXELS = 4 * 1024 * 1024
MAX_ICON_DIMENSION = 512
MAX_ICON_CACHE_BYTES = 64 * 1024 * 1024
MAX_ICON_CACHE_FILES = 1024
HOST_IDENTITY_XATTR = "user.steam_asahi.host_identity.v1"
HOST_IDENTITY = struct.Struct("<8sQQII")
DESCRIPTOR_ACCESS = {
    os.O_RDONLY: "read",
    os.O_WRONLY: "write",
    os.O_RDWR: "read-write",
}


class ResourceReply(msgspec.Struct):
    uri: str
    kind: Literal["file", "directory", "new-file"] | None = None


type DeviceId = Annotated[int, msgspec.Meta(ge=0)]
type FileOffset = Annotated[int, msgspec.Meta(ge=0, le=2**63 - 1)]


class DescriptorIdentity(msgspec.Struct):
    device: DeviceId
    inode: DeviceId
    type: Literal[32768, 16384]  # Linux S_IFREG and S_IFDIR

    def __post_init__(self) -> None:
        # msgspec's numeric constraints support only signed 64-bit bounds
        if self.device >= 2**64 or self.inode >= 2**64:
            raise ValueError("invalid descriptor identity")


class SharedFileManifest(msgspec.Struct):
    version: Literal[1]
    kind: Literal["shared-file"]
    identity: DescriptorIdentity
    access: Literal["read", "write", "read-write", "path"]
    uri: str
    append: bool = False
    offset: FileOffset | None = None


def local_file_uri(uri: str) -> tuple[Path, str, str]:
    if any(ord(character) < 32 or ord(character) == 127 for character in uri):
        raise ValueError("file URI contains an unescaped control character")
    parsed = urlsplit(uri)
    if parsed.scheme.casefold() != "file":
        raise ValueError("expected a local file URI")
    if parsed.netloc.casefold() not in ("", "localhost"):
        raise ValueError("remote file URI authorities are unsupported")
    if re.search(r"%(?![0-9a-fA-F]{2})", parsed.path):
        raise ValueError("invalid escape in file URI")
    path = Path.from_uri(
        urlunsplit(parsed._replace(netloc="", query="", fragment=""))
    )
    if "\0" in str(path):
        raise ValueError("file path contains a nul byte")
    return path, parsed.query, parsed.fragment


def file_uri(path: Path, query: str = "", fragment: str = "") -> str:
    parsed = urlsplit(path.as_uri())
    return urlunsplit(parsed._replace(query=query, fragment=fragment))


def resolve_host_uri(uri: str, mode: str) -> dict[str, str]:
    """Check the host resource without creating a file or invoking an opener"""
    if mode not in ("read", "write", "save"):
        raise ValueError("unsupported file access mode")
    path, query, fragment = local_file_uri(uri)
    document_roots = {
        Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.geteuid()}")
        / "doc",
        Path(f"/run/user/{os.geteuid()}/doc"),
    }
    document_root = next(
        (root for root in document_roots if path.is_relative_to(root)), None
    )
    # Resolve on the host before adding the guest export prefix: absolute
    # symlinks below that prefix would otherwise resolve in the guest root
    resolved = path.resolve(strict=mode != "save")
    if document_root is not None and not resolved.is_relative_to(
        document_root.resolve(strict=True)
    ):
        raise ValueError("document selection resolves outside its portal grant")
    path = resolved
    if mode == "save":
        parent = path.parent.resolve(strict=True)
        path = parent / path.name
        if not os.access(parent, os.W_OK | os.X_OK, effective_ids=True):
            raise PermissionError("save directory is not writable on the host")
        if not path.exists():
            return {"uri": file_uri(path, query, fragment), "kind": "new-file"}
    metadata = path.stat()
    if stat.S_ISDIR(metadata.st_mode):
        if mode != "read":
            raise ValueError("a save destination must be a regular file")
        access = os.R_OK | os.X_OK
        kind = "directory"
    elif stat.S_ISREG(metadata.st_mode):
        access = os.R_OK if mode == "read" else os.W_OK
        kind = "file"
    else:
        raise ValueError("only regular files and directories can be shared")
    if not os.access(path, access, effective_ids=True):
        raise PermissionError(
            "requested file access is unavailable on the host"
        )
    return {"uri": file_uri(path, query, fragment), "kind": kind}


def reopen_descriptor(manifest: dict) -> int:
    """Reopen an attested shared object for portal file/directory operations"""
    resource = msgspec.convert(manifest, type=SharedFileManifest, strict=True)
    identity = resource.identity
    access, append, offset = resource.access, resource.append, resource.offset
    modes = {value: key for key, value in DESCRIPTOR_ACCESS.items()}
    modes["path"] = os.O_PATH
    if identity.type == stat.S_IFDIR and (append or offset is not None):
        raise ValueError("directory cursor transfer is unsupported")
    if access == "path" and (append or offset is not None):
        raise ValueError("path descriptors cannot carry an I/O cursor")
    path, query, fragment = local_file_uri(resource.uri)
    if query or fragment:
        raise ValueError("descriptor URI cannot contain a query or fragment")
    pinned = os.open(path, os.O_PATH | os.O_CLOEXEC)
    result = None
    try:
        metadata = os.fstat(pinned)
        if (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IFMT(metadata.st_mode),
        ) != (identity.device, identity.inode, identity.type):
            raise ValueError(
                "host path does not identify the original shared object"
            )
        if access == "path":
            result = os.dup(pinned)
        else:
            flags = modes[access] | os.O_CLOEXEC | os.O_NONBLOCK
            if append:
                flags |= os.O_APPEND
            result = os.open(f"/proc/self/fd/{pinned}", flags)
            if offset is not None:
                os.lseek(result, offset, os.SEEK_SET)
        os.set_inheritable(result, False)
        return result
    except BaseException:
        if result is not None:
            os.close(result)
        raise
    finally:
        os.close(pinned)


class IconStore:
    """Keep bounded notification images until their VM broker stops"""

    def __init__(self, runtime: Path) -> None:
        self.directory = tempfile.TemporaryDirectory(
            prefix=".notification-icons-", dir=runtime
        )
        self.files: dict[str, int] = {}
        self.size = 0

    def __enter__(self) -> IconStore:
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def close(self) -> None:
        self.directory.cleanup()

    def put(self, data: bytes) -> str:
        if not 24 <= len(data) <= MAX_ICON_BYTES:
            raise ValueError("notification icon exceeds the byte limit")
        try:
            with (
                warnings.catch_warnings(
                    action="error", category=Image.DecompressionBombWarning
                ),
                Image.open(io.BytesIO(data), formats=("PNG",)) as image,
            ):
                if not (
                    0 < image.width <= MAX_ICON_DIMENSION
                    and 0 < image.height <= MAX_ICON_DIMENSION
                ):
                    raise ValueError(
                        "notification icon exceeds the dimension limit"
                    )
                image.load()
        except (
            Image.DecompressionBombWarning,
            Image.DecompressionBombError,
        ) as error:
            raise ValueError(
                "notification icon exceeds the dimension limit"
            ) from error
        name = hashlib.sha256(data).hexdigest() + ".png"
        path = Path(self.directory.name) / name
        if name not in self.files:
            if (
                self.size + len(data) > MAX_ICON_CACHE_BYTES
                or len(self.files) >= MAX_ICON_CACHE_FILES
            ):
                raise ValueError("notification icon cache is full")
            with atomic_save(
                path,
                overwrite=False,
                file_perms=0o600,
                part_file=f".{uuid4().hex}",
            ) as output:
                output.write(data)
            self.files[name] = len(data)
            self.size += len(data)
        return path.as_uri()


class OpenHow(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint64),
        ("mode", ctypes.c_uint64),
        ("resolve", ctypes.c_uint64),
    ]


class Namespace:
    """Pin the socket creator and resolve paths inside its filesystem root"""

    def __init__(
        self, pid: int, pidfd: int, root: int, mount_namespace: int
    ) -> None:
        self.pid = pid
        self.pidfd = pidfd
        self.root = root
        self.mount_namespace = mount_namespace

    @classmethod
    def from_socket(cls, connection: socket.socket) -> Namespace:
        # SO_PEERPIDFD pins the actual socket creator, avoiding PID reuse
        # between SO_PEERCRED and looking up its root in procfs (Linux 6.5+)
        return cls._capture(
            connection.getsockopt(
                socket.SOL_SOCKET, getattr(socket, "SO_PEERPIDFD", 77)
            )
        )

    @classmethod
    def current(cls) -> Namespace:
        return cls._capture(os.pidfd_open(os.getpid()))

    @classmethod
    def _capture(cls, pidfd: int) -> Namespace:
        with ExitStack() as descriptors:
            descriptors.callback(os.close, pidfd)
            os.set_inheritable(pidfd, False)
            fields = dict(
                line.split(":", 1)
                for line in Path(f"/proc/self/fdinfo/{pidfd}")
                .read_text()
                .splitlines()
                if ":" in line
            )
            pid = int(fields.get("Pid", "-1"))
            if pid <= 0:
                raise ProcessLookupError("the requesting process has exited")
            mount_namespace = os.open(
                f"/proc/{pid}/ns/mnt", os.O_RDONLY | os.O_CLOEXEC
            )
            descriptors.callback(os.close, mount_namespace)
            root = os.open(
                f"/proc/{pid}/root", os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC
            )
            descriptors.callback(os.close, root)
            namespace = cls(pid, pidfd, root, mount_namespace)
            namespace.ensure_alive()
            root_mount = next(
                line.partition(":")[2].strip()
                for line in Path(f"/proc/self/fdinfo/{root}")
                .read_text()
                .splitlines()
                if line.startswith("mnt_id:")
            )
            if not any(
                line.startswith(root_mount + " ")
                for line in Path(f"/proc/{pid}/mountinfo")
                .read_text()
                .splitlines()
            ):
                raise ValueError("the caller's root changed during capture")
            namespace.ensure_alive()
            descriptors.pop_all()
        return namespace

    def close(self) -> None:
        for name in ("root", "pidfd", "mount_namespace"):
            descriptor = getattr(self, name)
            if descriptor >= 0:
                os.close(descriptor)
                setattr(self, name, -1)

    def ensure_alive(self) -> None:
        if self.pidfd < 0 or select.select([self.pidfd], [], [], 0)[0]:
            raise ProcessLookupError("the requesting process has exited")
        current_namespace = os.stat(f"/proc/{self.pid}/ns/mnt")
        root = os.fstat(self.root)
        current_root = os.stat(f"/proc/{self.pid}/root")
        if current_namespace.st_ino != os.fstat(
            self.mount_namespace
        ).st_ino or (root.st_dev, root.st_ino) != (
            current_root.st_dev,
            current_root.st_ino,
        ):
            raise ValueError(
                "the requesting process changed its filesystem root"
            )

    def open(self, path: Path, flags: int = os.O_PATH) -> int:
        self.ensure_alive()
        if not path.is_absolute() or "\0" in str(path):
            raise ValueError("resource paths must be absolute")
        allowed = (
            os.O_PATH
            | os.O_DIRECTORY
            | os.O_CLOEXEC
            | os.O_NONBLOCK
            | os.O_WRONLY
            | os.O_RDWR
        )
        if flags & ~allowed:
            raise ValueError(
                "resource resolution cannot create or truncate files"
            )
        # openat2 is syscall 437 on both supported Linux architectures
        #
        # IN_ROOT resolves absolute symlinks in the caller's root; merely
        # opening /proc/PID/root/path would follow them in the broker's root
        # NO_MAGICLINKS rejects procfs descriptor links escaping that root
        how = OpenHow(
            flags=os.O_PATH | os.O_CLOEXEC | (flags & os.O_DIRECTORY),
            resolve=0x10 | 0x02,
        )
        libc = ctypes.CDLL(None, use_errno=True)
        result = libc.syscall(
            ctypes.c_long(437),
            ctypes.c_int(self.root),
            ctypes.c_char_p(os.fsencode(path).lstrip(b"/") or b"."),
            ctypes.byref(how),
            ctypes.c_size_t(ctypes.sizeof(how)),
        )
        if result < 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(path))
        if not flags & os.O_PATH:
            # Inspect the pinned inode before opening it for I/O. This keeps
            # special files from being opened and avoids a replacement race
            pinned = result
            try:
                metadata = os.fstat(pinned)
                if not (
                    stat.S_ISREG(metadata.st_mode)
                    or stat.S_ISDIR(metadata.st_mode)
                ):
                    raise ValueError(
                        "only regular files and directories are shared"
                    )
                result = os.open(
                    f"/proc/self/fd/{pinned}",
                    flags | os.O_CLOEXEC | os.O_NONBLOCK,
                )
            finally:
                os.close(pinned)
        try:
            self.ensure_alive()
        except BaseException:
            os.close(result)
            raise
        return result

    def host_path_for_fd(self, descriptor: int) -> Path:
        from desktop import read_mounts, shared_mount_roots

        self.ensure_alive()
        details = dict(
            line.split(":", 1)
            for line in Path(f"/proc/self/fdinfo/{descriptor}")
            .read_text()
            .splitlines()
            if ":" in line
        )
        mount_id = details["mnt_id"].strip()
        mounts = read_mounts(Path(f"/proc/{self.pid}"))
        selected = next(
            (entry for entry in mounts if entry[0] == mount_id), None
        )
        if (
            selected is None
            or selected[selected.index("-", 6) + 1] != "virtiofs"
        ):
            raise ValueError("file is not on shared host storage")
        target = Path(os.readlink(f"/proc/self/fd/{descriptor}"))
        if not target.is_relative_to(selected[4]):
            raise ValueError("cannot locate file inside the requesting mount")
        relative = target.relative_to(selected[4])
        process = psutil.Process(self.pid)
        for _ in range(64):
            if root := shared_mount_roots(mounts).get(selected[2]):
                self.ensure_alive()
                return root / selected[3].removeprefix("/") / relative
            try:
                process = process.parent()
                if process is None:
                    break
                mounts = read_mounts(Path(f"/proc/{process.pid}"))
            except OSError, psutil.Error:
                break
        raise ValueError("the shared mount ancestry is unavailable")

    def host_path(self, path: Path, *, save: bool = False) -> Path:
        try:
            descriptor = self.open(path)
        except FileNotFoundError:
            if not save:
                raise
            descriptor = self.open(path.parent, os.O_PATH | os.O_DIRECTORY)
            try:
                return self.host_path_for_fd(descriptor) / path.name
            finally:
                os.close(descriptor)
        try:
            metadata = os.fstat(descriptor)
            if not (
                stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)
            ):
                raise ValueError(
                    "only regular files and directories are shared"
                )
            return self.host_path_for_fd(descriptor)
        finally:
            os.close(descriptor)

    def host_uri(self, uri: str, *, save: bool = False) -> str:
        path, query, fragment = local_file_uri(uri)
        return file_uri(self.host_path(path, save=save), query, fragment)

    def descriptor_manifest(self, descriptor: int) -> dict:
        """Describe one pinned shared FD without exposing a guest device ID"""
        self.ensure_alive()
        metadata = os.fstat(descriptor)
        kind = stat.S_IFMT(metadata.st_mode)
        if kind not in (stat.S_IFREG, stat.S_IFDIR):
            raise ValueError("only regular files and directories are supported")
        if metadata.st_nlink == 0:
            raise ValueError(
                "unlinked files require a separate resource transfer"
            )
        path = self.host_path_for_fd(descriptor)
        # The patched server returns identity from its pinned inode File
        # Ordinary guest st_dev is virtual, and synthetic virtiofs entries
        # deliberately cannot provide this private read-only metadata
        data = os.getxattr(f"/proc/self/fd/{descriptor}", HOST_IDENTITY_XATTR)
        if len(data) != HOST_IDENTITY.size:
            raise ValueError("invalid host descriptor attestation")
        magic, device, inode, host_kind, reserved = HOST_IDENTITY.unpack(data)
        if magic != b"SAFI0001" or reserved != 0 or host_kind != kind:
            raise ValueError("invalid host descriptor attestation")
        flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
        access = (
            "path"
            if flags & os.O_PATH
            else DESCRIPTOR_ACCESS.get(flags & os.O_ACCMODE)
        )
        if access is None:
            raise ValueError("unsupported descriptor access mode")
        append = bool(flags & os.O_APPEND) if access != "path" else False
        offset = (
            os.lseek(descriptor, 0, os.SEEK_CUR)
            if kind == stat.S_IFREG and access != "path"
            else None
        )
        self.ensure_alive()
        return {
            "version": 1,
            "kind": "shared-file",
            "uri": path.as_uri(),
            "identity": {"device": device, "inode": inode, "type": kind},
            "access": access,
            "offset": offset,
            "append": append,
        }

    def _notification_image(self, target: str | Path) -> Image.Image:
        target = os.fspath(target)
        path = (
            local_file_uri(target)[0]
            if target.casefold().startswith("file:")
            else Path(target)
        )
        descriptor = self.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError("notification icon must be a regular file")
            if metadata.st_size > MAX_ICON_SOURCE_BYTES:
                raise ValueError(
                    "notification icon source exceeds the byte limit"
                )
            data = source.read(MAX_ICON_SOURCE_BYTES + 1)
        if len(data) > MAX_ICON_SOURCE_BYTES:
            raise ValueError("notification icon source exceeds the byte limit")
        try:
            with (
                warnings.catch_warnings(
                    action="error", category=Image.DecompressionBombWarning
                ),
                Image.open(io.BytesIO(data)) as original,
            ):
                if original.width * original.height > MAX_ICON_SOURCE_PIXELS:
                    raise ValueError(
                        "notification icon source exceeds the pixel limit"
                    )
                original.thumbnail((MAX_ICON_DIMENSION, MAX_ICON_DIMENSION))
                image = original.convert("RGBA")
                image.info.clear()
        except (
            Image.DecompressionBombWarning,
            Image.DecompressionBombError,
        ) as error:
            raise ValueError(
                "notification icon source exceeds the pixel limit"
            ) from error
        try:
            self.ensure_alive()
        except BaseException:
            image.close()
            raise
        return image

    def notification_image(
        self, target: str | Path
    ) -> tuple[int, int, int, bool, int, int, bytes]:
        """Produce the standard (iiibiiay) notification image-data value"""
        with self._notification_image(target) as image:
            return (
                image.width,
                image.height,
                image.width * 4,
                True,
                8,
                4,
                image.tobytes(),
            )

    async def notification_icon(self, target: str | Path) -> str:
        # app_icon is a filename/URI rather than a pixel variant. Cache a
        # normalized PNG on the host so a separate image hint remains intact
        output = io.BytesIO()
        with self._notification_image(target) as image:
            image.save(output, format="PNG")
        data = output.getvalue()
        if len(data) > MAX_ICON_BYTES:
            raise ValueError("notification icon exceeds the byte limit")
        response = await resource_request("cacheIcon", data=data)
        uri = response.uri
        local_file_uri(uri)
        return uri

    async def guest_uri(self, uri: str, *, mode: str = "read") -> str:
        response = await resource_request("resolve", target=uri, mode=mode)
        if response.kind is None:
            raise ValueError("the host returned an invalid file resource")
        canonical, query, fragment = local_file_uri(response.uri)
        failures = []
        for candidate in (HOST_ROOT / canonical.relative_to("/"), canonical):
            try:
                if response.kind == "new-file":
                    descriptor = self.open(
                        candidate.parent, os.O_PATH | os.O_DIRECTORY
                    )
                    try:
                        if (
                            self.host_path_for_fd(descriptor)
                            != canonical.parent
                        ):
                            raise ValueError(
                                "save directory maps to another host path"
                            )
                        if not os.access(
                            ".",
                            os.W_OK | os.X_OK,
                            dir_fd=descriptor,
                            effective_ids=True,
                        ):
                            raise PermissionError(
                                "save directory is not writable"
                            )
                    finally:
                        os.close(descriptor)
                    with suppress(FileNotFoundError):
                        if self.host_path(candidate) != canonical:
                            raise ValueError(
                                "save destination maps to another host path"
                            )
                else:
                    access = os.O_RDONLY if mode == "read" else os.O_WRONLY
                    descriptor = self.open(candidate, access | os.O_NONBLOCK)
                    try:
                        metadata = os.fstat(descriptor)
                        if not (
                            stat.S_ISREG(metadata.st_mode)
                            or stat.S_ISDIR(metadata.st_mode)
                        ):
                            raise ValueError("unsupported selected file type")
                        if self.host_path_for_fd(descriptor) != canonical:
                            raise ValueError(
                                "selected file maps to another host path"
                            )
                    finally:
                        os.close(descriptor)
                return file_uri(candidate, query, fragment)
            except (OSError, ValueError) as error:
                failures.append(str(error))
        raise ValueError(
            "selected host file is unavailable to the caller: "
            + "; ".join(failures)
        )


async def resource_request(method: str, **arguments) -> ResourceReply:
    from portal.rpc import RPC, capnp, connect
    from transport import OPEN_PORT

    try:
        async with connect(OPEN_PORT, RPC.Desktop) as desktop:
            response = await getattr(desktop, method)(**arguments)
            return msgspec.convert(
                response.to_dict(),
                type=ResourceReply,
            )
    except capnp.KjException as error:
        raise ValueError(str(error)) from error
