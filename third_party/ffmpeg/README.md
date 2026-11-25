# FastVision FFmpeg corresponding source

FastVision uses the same LGPL media frameworks for its GitHub DMG and Mac App Store builds.
The native FFmpegKit 6.0 commit is `d6be56d7aec286eb3c292d6b23ff07a6b70d8693` and the FFmpeg
`n6.0` commit is `ea3d24bbe3c58b171e55fe2151fc7ffaca3ab3d2`.
[source-lock.json](source-lock.json) pins the source archives and build tools.

The shared [macOS build options](macos-lgpl.args) disable GPL and nonfree components and enable
VideoToolbox for H.264 and HEVC. The BSD-licensed dav1d and libvpx are included.
The frameworks use local-file media access. The build excludes network protocols,
Audible AA and AAX decryption, encrypted ASF and OpenMG, and the retired ciphers they used.
Unencrypted ASF and OpenMG remain readable. Standard AES support for interoperable media
encryption, including MP4 Common Encryption, remains available.
GNU config and gas-preprocessor are build tools. They are not linked into the frameworks.

## Build the frameworks on macOS

Install Xcode and its command-line tools. Put Python 3.12 or later, pkg-config, Meson, Ninja,
NASM and Yasm on PATH. From a FastVision checkout, run:

```sh
stage=$(mktemp -d /private/tmp/fastvision-build.XXXXXXXX)
python3 third_party/ffmpeg/build-macos.py "$stage/ffmpeg-kit-lgpl-build"
```

When using the standalone corresponding source archive, run `python3 build-macos.py "$stage/ffmpeg-kit-lgpl-build"`
from the extracted source directory.

The script verifies the inputs, applies the macOS patches and checks the license and compiler
configuration in both slices of the finished libavutil binary. The output includes eight
universal XCFrameworks in `bundle-apple-xcframework-macos` and the license notices and
corresponding source archive in `FFmpeg-LGPL`.

## Build FastVision

The Xcode project expects these sibling directories:

```text
FastVision/
ffmpeg-kit-lgpl-build/
BTree/
Settings/
```

Prepare the application source and local packages inside the same staging directory:

```sh
mkdir "$stage/FastVision" "$stage/BTree" "$stage/Settings"
cp -R FastVision FastVision.xcodeproj Base.xcconfig AppStore.xcconfig LICENSE "$stage/FastVision/"
tar -xzf third_party/app-sources/BTree.tar.gz --strip-components=1 -C "$stage/BTree"
tar -xzf third_party/app-sources/Settings.tar.gz --strip-components=1 -C "$stage/Settings"
xcodebuild -project "$stage/FastVision/FastVision.xcodeproj" -scheme FastVision \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$stage/DerivedData" 'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

For a sandboxed build, select the **FastVision App Store** scheme and the `AppStore`
configuration. It uses the same frameworks and source archive. The sandboxed app asks you
to select a folder and restores folder access from a security-scoped bookmark. Opening a
single file grants access to that file.

BTree is pinned at `407fda73e18cc9df9130453ee36f73408c22408f` and Settings at
`f41475771f65379ca10852c95119a7f53f0de5a5`. Xcode resolves the remaining dependencies
using `Package.resolved`. The source archives are in [app-sources](../app-sources/).

## License information

The media frameworks use LGPL v3. FastVision itself uses GNU GPL v3. The **About FastVision**
panel links to the bundled corresponding source, the license and the pinned upstream projects.
When distributing a build, make its exact corresponding source available alongside it.
See the [FFmpeg project license guidance](https://ffmpeg.org/legal.html).
