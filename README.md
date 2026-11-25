<p align="center">
<h1 align="center">FastVision</h1>
<h3 align="center">A Fast-series waterfall image viewer for macOS<br><br><a href="./README_zh.md">[中文说明]</a></h3>
</p>


## Screenshots

These screenshots are from upstream FlowVision.

### Light Mode
![preview](./docs/preview_2.png)

### Dark Mode
![preview](./docs/preview_1.png)

## Features:
 - Adaptive layout mode, light/dark mode
 - Convenient file management (similar to Finder)
 - Right-click gestures, quickly find the previous/next folder with images/videos
 - Performance optimizations for directories with a large number of images
 - High-quality scaling (reduces moiré and other issues)
 - Support for video playback
 - Support for HDR display
 - Recursive mode

## Installation and Usage

### System Requirements

 - macOS 12.0 or later

### Privacy and Security

 - Open source
 - No Internet connection

Follow the build steps below to run a local copy.

## Instructions:
### In Image View:
 - Double-click to open/close the image
 - Hold down the right/left mouse button and scroll the wheel to zoom
 - Hold down the middle mouse button and drag to move the window
 - Long press the left mouse button to switch to 100% zoom
 - Long press the right mouse button to fit the image to the view
### Right-Click Gestures:
 - Right/Left: Switch to the next/previous folder with images/videos (logically equivalent to the next folder when sorting all folders on the disk)
 - Up: Switch to the parent directory
 - Down: Return to the previous directory
 - Up-Right: Switch to the next folder with images at the same level as the current folder
 - Down-Right: Close the tab/window
### Keyboard Shortcuts:
 - W: Same as the right-click gesture Up
 - A/D: Same as the right-click gesture Left/Right
 - S: Same as the right-click gesture Down

## Build

Build the FFmpeg frameworks from [the pinned local sources](./third_party/ffmpeg/README.md). The documented directory layout also applies to the Xcode project. [Application dependency sources](./third_party/app-sources/source-lock.json) are versioned by their upstream commits.

## Upstream and license

FastVision is an independently maintained fork of [netdcy/FlowVision](https://github.com/netdcy/FlowVision). Thanks to netdcy and the FlowVision contributors.

On 2026-11-25, FastVision changed the application name, project identifiers, and English and Chinese documentation. See the Git history for changes.

FastVision is released under GNU GPL v3. See [LICENSE](./LICENSE) for the full text. Third-party components retain their own licenses.
