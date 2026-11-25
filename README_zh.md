<p align="center">
<h1 align="center">FastVision</h1>
<h3 align="center">Fast 系列的 macOS 瀑布流图片浏览器</h3>
</p>


## 预览

以下截图来自上游 FlowVision。

### 浅色模式
![preview](./docs/preview_2.png)

### 黑暗模式
![preview](./docs/preview_1.png)

## 应用特点:

 - 自适应布局模式、浅色/深色模式

 - 方便的文件管理（操作类似 Finder）

 - 右键手势、快速查找上一个/下一个有图片/视频的文件夹

 - 针对目录下大量图片情况的性能优化

 - 高质量的缩放（减轻摩尔纹等问题）

 - 支持视频播放

 - 支持HDR显示

 - 支持递归模式

## 安装使用

### 系统需求

 - macOS 12.0+

### 隐私与安全性

 - 开源软件
 - 无网络请求

当前可按下文的编译步骤构建本地版本。

## 操作说明

### 图片浏览:
 - 双击打开/关闭图片
 - 按住右键/左键滚动滚轮可以缩放
 - 按住中键拖动可以移动窗口
 - 长按左键切换 100%缩放
 - 长按右键切换缩放到视图
### 右键手势:
 - 向右/左：切换到下一个/上一个有图片/视频的文件夹(逻辑上等同于将整个磁盘中的文件夹排序后的下一个)
 - 向上：切换到上级目录
 - 向下：返回到上一次的目录
 - 向上右：切换到与当前文件夹平级的下一个有图片的文件夹
 - 向下右：关闭当前标签页/窗口
### 键盘按键:
 - W：同右键手势 向上
 - A/D：同右键手势 向左/右
 - S：同右键手势 向下

## 编译

按 [FFmpeg 对应源码和构建说明](./third_party/ffmpeg/README.md) 从本地固定源码构建 macOS 双架构框架，然后按说明准备 Xcode 工程所需的同级目录。[应用依赖源码清单](./third_party/app-sources/source-lock.json) 记录了各自的固定提交。

## 上游来源与许可

FastVision 基于 [netdcy/FlowVision](https://github.com/netdcy/FlowVision)，由 FastVision 项目独立维护。感谢 netdcy 和 FlowVision 的贡献者。

2026-11-25，FastVision 修改了应用名称、工程标识和中英文文档。有关改动可在 Git 提交记录中查看。

本项目按 GNU GPL v3 发布，许可证全文见 [LICENSE](./LICENSE)。第三方组件适用各自的许可证。
