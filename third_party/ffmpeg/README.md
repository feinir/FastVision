# FastVision FFmpeg corresponding source

The macOS build uses FFmpegKit Native 6.0 at `d6be56d7aec286eb3c292d6b23ff07a6b70d8693` and FFmpeg `n6.0` at `ea3d24bbe3c58b171e55fe2151fc7ffaca3ab3d2`. [source-lock.json](source-lock.json) records each archive's source, pinned revision, SHA-256, and extraction path.

The options in [macos-full-gpl.args](macos-full-gpl.args) are based on the enabled components in the previous FastVision FFmpegKit binary. They explicitly enable the GPL components and their required libraries, target macOS 12, and build Apple Silicon and Intel slices. SDK system libraries such as zlib, bzip2 and iconv come from Xcode.

## Build on macOS

Install Xcode and its command-line tools. Put Python 3.12 or newer, Autoconf, Automake, GNU AutoGen, GNU Libtool, CMake 3.31, pkg-config, Meson, Ninja, NASM, and Yasm on PATH. For missing tools, Homebrew can install the respective formulae. Put CMake 3.31 ahead of CMake 4 on PATH. The x265 build uses policies still supported by CMake 3.31.

From the FastVision checkout, choose a new temporary build directory and run:

```sh
stage=$(mktemp -d /private/tmp/fastvision-build.XXXXXXXX)
python3 third_party/ffmpeg/build-macos.py "$stage/ffmpeg-kit-build"
```

The script verifies every archive before extracting, applies the patches under [patches](patches/), and builds from the local source trees. The upstream FFmpegKit archive includes the original build scripts and patches under `tools/patch/`. The script creates local Git metadata so the upstream build can label its version and reset files between architecture builds. The archive commits in the manifest identify the actual upstream sources.

GnuTLS is built from the signed 3.7.9 release archive with its generated inputs. The included OpenPGP signature was verified against the project keyring. The original 3.7.9 Git snapshot is present for reference. The build uses the signed release archive so it never pulls a moving gnulib branch.

A successful build leaves eight frameworks in `$stage/ffmpeg-kit-build/bundle-apple-xcframework-macos`. The 2023 Autoconf inputs are built without its C23 probe to preserve the older C declaration semantics. The native log is `$stage/ffmpeg-kit-build/build.log`.

## Use with Xcode

The application project expects the following sibling directories:

```text
FastVision/
ffmpeg-kit-build/
BTree/
Settings/
```

Run these commands from the checkout after building the frameworks, with the same `stage` variable:

```sh
mkdir "$stage/FastVision" "$stage/BTree" "$stage/Settings"
cp -R FastVision FastVision.xcodeproj Base.xcconfig LICENSE "$stage/FastVision/"
tar -xzf third_party/app-sources/BTree.tar.gz --strip-components=1 -C "$stage/BTree"
tar -xzf third_party/app-sources/Settings.tar.gz --strip-components=1 -C "$stage/Settings"
xcodebuild -project "$stage/FastVision/FastVision.xcodeproj" -scheme FastVision \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$stage/DerivedData" 'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

BTree is pinned at `407fda73e18cc9df9130453ee36f73408c22408f` and Settings at `f41475771f65379ca10852c95119a7f53f0de5a5`. Xcode resolves the remaining dependencies using the project's `Package.resolved`. Their archives and license notices are in [app-sources](../app-sources/), including the libwebp-Xcode submodule.


## License information

The `--enable-gpl` selection makes the FFmpegKit bundle subject to GPL v3. Each source archive includes its component's own notices. [licenses](licenses/) also collects the principal notices for convenient access. Distribute the corresponding sources and build scripts together with the applicable licenses. When offering a binary download, put its exact source download alongside it.
