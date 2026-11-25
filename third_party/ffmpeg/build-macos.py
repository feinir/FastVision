#!/usr/bin/env python3
"""Prepare and build the pinned native FFmpegKit sources for macOS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile


def extract(archive, destination):
    if destination.is_symlink() or (destination.exists() and any(destination.iterdir())):
        raise SystemExit(f"Source extraction target is already populated: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        top = source.next().name
        for member in source.getmembers():
            if member.name == top:
                continue
            member.name = str(Path(member.name).relative_to(top))
            if member.islnk():
                member.linkname = str(Path(member.linkname).relative_to(top))
            source.extract(member, destination, filter="data")


def prepare_git(directory, ref=None, paths=()):
    git = ["git", "-C", str(directory)]
    subprocess.run([*git, "init", "-q"], check=True)
    if paths:
        subprocess.run([*git, "add", "--force", "--", *paths], check=True)
    subprocess.run([
        *git, "-c", "user.name=FastVision Source Build",
        "-c", "user.email=build@fastvision.invalid", "commit", "--quiet",
        "--allow-empty", "-m", "Local build metadata for verified source archives",
    ], check=True)
    if ref:
        subprocess.run([*git, "tag", ref], check=True)


def verify(supply):
    records = json.loads((supply / "source-lock.json").read_text())
    for record in records:
        path = supply / record["archive"]
        with path.open("rb") as data:
            digest = hashlib.file_digest(data, "sha256").hexdigest()
        if digest != record["sha256"] or path.stat().st_size != record["bytes"]:
            raise SystemExit(f"Source verification failed for {path}")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_directory", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()

    if not args.prepare_only:
        cmake_version = subprocess.check_output(["cmake", "--version"], text=True).splitlines()[0]
        if not cmake_version.startswith("cmake version 3."):
            raise SystemExit("Use CMake 3.31 on PATH for the pinned x265 build scripts.")

    supply = Path(__file__).resolve().parent
    build = args.build_directory.resolve()
    records = verify(supply)
    if build.exists():
        raise SystemExit(f"Choose a new build directory: {build}")
    for record in records:
        destination = record.get("build_path")
        if destination is not None:
            extract(supply / record["archive"], build / destination)

    for patch in sorted((supply / "patches").glob("*.patch")):
        with patch.open("rb") as data:
            subprocess.run(["patch", "-p1", "-f"], cwd=build, stdin=data, check=True)

    prepare_git(build, "v6.0")
    prepare_git(build / "src" / "ffmpeg", "n6.0", (
        "ffbuild", "libavformat/file.c", "libavformat/protocols.c", "libavutil",
    ))
    prepare_git(build / "src" / "x265", "3.4")
    prepare_git(build / "src" / "xvidcore", paths=("xvidcore/build/generic/configure.in",))
    if args.prepare_only:
        return
    environment = os.environ.copy()
    environment["ac_cv_prog_cc_c23"] = "no"
    environment["GIT_CEILING_DIRECTORIES"] = str(build / "src")
    options = (supply / "macos-full-gpl.args").read_text().split()
    subprocess.run(["/bin/bash", "macos.sh", *options], cwd=build, env=environment, check=True)
    frameworks = Path("prebuilt/bundle-apple-xcframework-macos")
    if len(list((build / frameworks).glob("*.xcframework"))) != 8:
        raise SystemExit("The macOS build did not produce all eight XCFrameworks.")
    (build / frameworks.name).symlink_to(frameworks, target_is_directory=True)


if __name__ == "__main__":
    main()
