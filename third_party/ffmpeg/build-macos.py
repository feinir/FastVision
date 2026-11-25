#!/usr/bin/env python3
"""Prepare and build the pinned native FFmpegKit sources for macOS."""

import argparse
import hashlib
import json
import os
import shutil
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


def verify_lgpl_frameworks(frameworks):
    libraries = list(frameworks.glob("libavutil.xcframework/*/libavutil.framework/libavutil"))
    if len(libraries) != 1:
        raise SystemExit("Expected a single universal macOS libavutil framework.")
    required = (
        "--disable-gpl", "--disable-nonfree", "--enable-version3",
        "--enable-videotoolbox", "--enable-shared", "--disable-static",
        "--disable-network", "--disable-demuxer=aa",
    )
    forbidden = (
        "--enable-gpl", "--enable-nonfree", "--enable-libx264",
        "--enable-libx265", "--enable-libxvid", "--enable-libvidstab",
    )
    retired_ciphers = ("blowfish", "camellia", "cast5", "des", "rc4", "tea", "twofish", "xtea")
    legacy_prefixes = tuple(f"_av_{cipher}_" for cipher in retired_ciphers)
    media_binaries = tuple(
        bundle / bundle.stem for bundle in frameworks.glob("libav*.xcframework/*/*.framework")
    )
    for arch in ("arm64", "x86_64"):
        for binary in media_binaries:
            symbols = subprocess.check_output(
                ["xcrun", "nm", "-arch", arch, "-gU", str(binary)],
                text=True, errors="replace",
            )
            if any(line.split()[-1].startswith(legacy_prefixes)
                   for line in symbols.splitlines() if line.strip()):
                raise SystemExit(f"Unexpected legacy media cipher in {binary.name} ({arch}).")
        strings = subprocess.check_output(
            ["xcrun", "strings", "-arch", arch, "-a", str(libraries[0])],
            text=True, errors="replace",
        ).splitlines()
        configs = [line.split() for line in strings if "--enable-version3" in line]
        if "libavutil license: LGPL version 3 or later" not in strings or not any(
            all(flag in flags for flag in required) and not any(flag in flags for flag in forbidden)
            for flags in configs
        ):
            raise SystemExit(f"Could not verify the LGPL configuration for {arch}.")


def package_source(supply, build, patches):
    notices = build / "FFmpeg-LGPL"
    notices.mkdir()
    for name, license_path in (
        ("LGPL-3.0.txt", "ffmpeg/COPYING.LGPLv3"),
        ("GPL-3.0.txt", "ffmpeg/COPYING.GPLv3"),
    ):
        shutil.copyfile(supply / "licenses" / license_path, notices / name)
    with tarfile.open(notices / "FFmpegKit-LGPL-source.tar.gz", "w:gz", dereference=True) as archive:
        prefix = "FastVision-FFmpegKit-LGPL"
        for name in ("README.md", "macos-lgpl.args", "build-macos.py", "source-lock.json"):
            archive.add(supply / name, arcname=f"{prefix}/{name}")
        for record in json.loads((supply / "source-lock.json").read_text()):
            name = record["archive"]
            archive.add(supply / name, arcname=f"{prefix}/{name}")
        for patch in patches:
            archive.add(patch, arcname=f"{prefix}/patches/{patch.name}")
        for component in ("ffmpeg", "ffmpeg-kit", "dav1d", "libvpx"):
            archive.add(supply / "licenses" / component, arcname=f"{prefix}/licenses/{component}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_directory", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()

    supply = Path(__file__).resolve().parent
    build = args.build_directory.resolve()
    records = verify(supply)
    if build.exists():
        raise SystemExit(f"Choose a new build directory: {build}")
    for record in records:
        destination = record.get("build_path")
        if destination is not None:
            extract(supply / record["archive"], build / destination)
        if destination_file := record.get("build_file"):
            path = build / destination_file
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(supply / record["archive"], path)
            path.chmod(0o755)

    patches = sorted((supply / "patches").glob("*.patch"))
    patches = [patch for patch in patches if patch.name.startswith(("0006-", "0007-", "0008-", "0009-"))]
    for patch in patches:
        with patch.open("rb") as data:
            subprocess.run(["patch", "-p1", "-f"], cwd=build, stdin=data, check=True)

    prepare_git(build, "v6.0")
    prepare_git(build / "src" / "ffmpeg", "n6.0", (
        "ffbuild", "libavformat/file.c", "libavformat/protocols.c", "libavutil",
    ))
    if args.prepare_only:
        return
    # FFmpegKit logs the child environment. Pass only settings used by the build tools.
    inherit = ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL")
    environment = {key: os.environ[key] for key in inherit if key in os.environ}
    environment["ac_cv_prog_cc_c23"] = "no"
    environment["GIT_CEILING_DIRECTORIES"] = str(build / "src")
    options = (supply / "macos-lgpl.args").read_text().split()
    subprocess.run(["/bin/bash", "macos.sh", *options], cwd=build, env=environment, check=True)
    frameworks = Path("prebuilt/bundle-apple-xcframework-macos")
    if len(list((build / frameworks).glob("*.xcframework"))) != 8:
        raise SystemExit("The macOS build did not produce all eight XCFrameworks.")
    verify_lgpl_frameworks(build / frameworks)
    package_source(supply, build, patches)
    (build / frameworks.name).symlink_to(frameworks, target_is_directory=True)


if __name__ == "__main__":
    main()
