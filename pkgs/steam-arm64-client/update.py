#!/usr/bin/env nix-shell
#!nix-shell --pure -i python3 -p python3 cacert

"""Update the pinned ARM64 Steam client from Valve's public-beta manifest."""

from __future__ import annotations

import argparse
import base64
import re
import urllib.request
from pathlib import Path

MANIFEST_URL = (
    "https://client-update.fastly.steamstatic.com/steam_client_publicbeta_linuxarm64"
)
DOWNLOAD_BASE_URL = "https://client-update.fastly.steamstatic.com/"
PACKAGE_RELATIVE_PATH = Path("pkgs/steam-arm64-client/default.nix")
DERIVATION_MARKER = "stdenvNoCC.mkDerivation"


def find_package_file(package_file: Path | None) -> Path:
    if package_file is not None:
        return package_file.resolve()

    working_directory = Path.cwd().resolve()
    for directory in (working_directory, *working_directory.parents):
        candidate = directory / PACKAGE_RELATIVE_PATH
        if candidate.is_file():
            return candidate

    if working_directory.name == "steam-arm64-client":
        candidate = working_directory / "default.nix"
        if candidate.is_file():
            return candidate

    raise SystemExit(
        "could not find pkgs/steam-arm64-client/default.nix; "
        "run this from the repository or pass its path"
    )


def fetch_release(manifest_file: Path | None) -> tuple[str, str, str]:
    if manifest_file is None:
        with urllib.request.urlopen(MANIFEST_URL) as response:
            manifest = response.read().decode()
    else:
        manifest = manifest_file.read_text(encoding="utf-8")

    version_match = re.search(r'^\s*"version"\s*"(\d+)"', manifest, re.MULTILINE)
    payload_match = re.search(
        r'"bins_linuxarm64_linuxarm64"\s*\{'
        r'.*?^\s*"file"\s*"([^"]+)"'
        r'.*?^\s*"sha2"\s*"([0-9a-f]{64})"',
        manifest,
        re.MULTILINE | re.DOTALL,
    )
    if version_match is None or payload_match is None:
        raise SystemExit("Valve's ARM64 Steam manifest has an unrecognized format")

    version = version_match.group(1)
    filename, sha256_hex = payload_match.groups()
    sha256_sri = "sha256-" + base64.b64encode(bytes.fromhex(sha256_hex)).decode()
    return version, DOWNLOAD_BASE_URL + filename, sha256_sri


def replace_once(source: str, pattern: str, replacement: str) -> str:
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"expected exactly one package match for {pattern!r}")
    return updated


def update_derivation(source: str, version: str, url: str, source_hash: str) -> str:
    derivation_match = re.search(
        rf"^{re.escape(DERIVATION_MARKER)}\b", source, re.MULTILINE
    )
    if derivation_match is None:
        raise SystemExit(f"package does not contain top-level {DERIVATION_MARKER!r}")

    prefix = source[: derivation_match.start()]
    derivation = source[derivation_match.start() :]
    derivation = replace_once(
        derivation,
        r'^(\s*)version = "[^"]+";',
        rf'\g<1>version = "{version}";',
    )
    derivation = replace_once(
        derivation,
        r'^(\s*)url = "[^"]+";',
        rf'\g<1>url = "{url}";',
    )
    derivation = replace_once(
        derivation,
        r'^(\s*)hash = "sha256-[^"]+";',
        rf'\g<1>hash = "{source_hash}";',
    )
    return prefix + derivation


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest-file",
        type=Path,
        help="read a local Valve manifest instead of downloading it",
    )
    parser.add_argument("package_file", nargs="?", type=Path)
    arguments = parser.parse_args()

    package_file = find_package_file(arguments.package_file)
    version, url, source_hash = fetch_release(arguments.manifest_file)
    original = package_file.read_text(encoding="utf-8")
    updated = update_derivation(original, version, url, source_hash)

    if updated == original:
        print(f"steam-arm64-client {version} is already up to date")
        return

    temporary_file = package_file.with_suffix(".nix.tmp")
    temporary_file.write_text(updated, encoding="utf-8")
    temporary_file.replace(package_file)
    print(f"updated steam-arm64-client to {version}")


if __name__ == "__main__":
    main()
