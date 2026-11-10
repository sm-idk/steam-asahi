"""Mirror the effective Nix package set without consulting upstream releases"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from packaging.requirements import Requirement
from packaging.specifiers import SpecifierSet
from packaging.utils import canonicalize_name
from packaging.version import Version
import tomlkit


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("metadata", type=Path)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
metadata = json.loads(args.metadata.read_text())
versions = metadata["versions"]
python_minor = metadata["pythonMinor"]


def nix_version(name):
    if name not in versions:
        raise ValueError(
            f"{name}: add its Nix package to nix/update/python.nix"
        )
    return versions[name]


def align(requirements):
    for index, value in enumerate(requirements):
        requirement = Requirement(value)
        name = canonicalize_name(requirement.name)
        version = nix_version(name)
        if requirement.url:
            raise ValueError(f"{name}: declare Git sources in tool.uv.sources")
        # Keep equivalent spellings, such as Nix's 0.9 and PyPI's 0.9.0
        specifiers = list(requirement.specifier)
        if (
            len(specifiers) == 1
            and specifiers[0].operator == "=="
            and not specifiers[0].version.endswith(".*")
            and Version(specifiers[0].version) == Version(version)
        ):
            continue
        requirement.specifier = SpecifierSet(f"=={version}")
        requirements[index] = str(requirement)


def align_document(document):
    document["requires-python"] = f"=={python_minor}.*"
    align(document.get("dependencies", []))
    for requirements in document.get("optional-dependencies", {}).values():
        align(requirements)


def check_lock(content, project_name):
    for package in tomlkit.parse(content)["package"]:
        if package["name"] == project_name:
            continue
        name = package["name"]
        if Version(package["version"]) != Version(nix_version(name)):
            raise ValueError(
                f"{name}: uv.lock does not match the Nix package set"
            )


project_path = Path("pyproject.toml")
project = tomlkit.parse(project_path.read_text())
align_document(project["project"])
for requirements in project.get("dependency-groups", {}).values():
    align(requirements)
align(project["tool"]["uv"].get("constraint-dependencies", []))
for name, source in project["tool"]["uv"].get("sources", {}).items():
    # A Git source must follow Nix's actual revision, not a guessed version tag
    nix_source = metadata["gitSources"][name]
    if source["git"].removesuffix(".git") != nix_source["git"].removesuffix(
        ".git"
    ):
        raise ValueError(f"{name}: uv and Nix use different Git repositories")
    source.pop("tag", None)
    source.pop("branch", None)
    source["rev"] = nix_source["rev"]
project["tool"]["ruff"]["target-version"] = "py" + python_minor.replace(".", "")
project["tool"]["ty"]["environment"]["python-version"] = python_minor

script_path = Path("pkgs/steam/arm64/proton/configure.py")
script = script_path.read_text()
block = re.search(r"(?m)^# /// script\n((?:#.*\n)+?)# ///$", script)
if block is None:
    raise ValueError(f"{script_path}: missing PEP 723 metadata")
inline = tomlkit.parse(
    "".join(line.removeprefix("# ") for line in block[1].splitlines(True))
)
align_document(inline)
inline_text = "".join(
    f"# {line}\n" for line in tomlkit.dumps(inline).splitlines()
)
script = script[: block.start(1)] + inline_text + script[block.end(1) :]
script = re.sub(
    r"\A#!/usr/bin/env python[0-9.]+",
    f"#!/usr/bin/env python{python_minor}",
    script,
)

outputs = {
    project_path: tomlkit.dumps(project),
    script_path: script,
    Path(".python-version"): metadata["pythonVersion"] + "\n",
}
lock_path = Path("uv.lock")
if args.check:
    for path, content in outputs.items():
        if path.read_text() != content:
            sys.exit(f"{path}: run nix run .#update-python-deps")
    check_lock(lock_path.read_text(), project["project"]["name"])
    subprocess.run(
        [
            "uv",
            "lock",
            "--check",
            "--python",
            metadata["python"],
            "--no-python-downloads",
        ],
        check=True,
    )
else:
    # Resolve before writing, so unavailable releases leave the checkout intact
    with tempfile.TemporaryDirectory(prefix="steam-asahi-python-") as directory:
        staging = Path(directory)
        (staging / "pyproject.toml").write_text(outputs[project_path])
        (staging / "uv.lock").write_text(lock_path.read_text())
        subprocess.run(
            [
                "uv",
                "lock",
                "--directory",
                directory,
                "--python",
                metadata["python"],
                "--no-python-downloads",
            ],
            check=True,
        )
        outputs[lock_path] = (staging / "uv.lock").read_text()
        check_lock(outputs[lock_path], project["project"]["name"])
    for path, content in outputs.items():
        if path.read_text() != content:
            path.write_text(content)
            print(f"Aligned {path}")
