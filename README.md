# LiteWebTV-iOS 📺

**iOS 版本 —— 基于 WKWebView 的央视频直播客户端。**

> 本项目移植自开源项目 [YukonKong/LiteWebTV](https://github.com/YukonKong/LiteWebTV)。
> 核心自动化 JS 脚本与架构设计版权归属原作者 YukonKong。
> 本仓库在原项目基础上，使用 Swift + SwiftUI + WKWebView 进行了 iOS 平台的原生重写。

## ✨ 特性

- **自动化流程**：自动选择 1080P 画质、开启声音、全屏播放
- **智能幕布**：换台时优雅过渡，视频就绪后自动升起
- **魅影紫开屏**：带呼吸灯效果的高级感开屏动画
- **手势操控**：
  - 上/下滑 → 换台（3 秒防抖）
  - 左滑 → 节目单 | 右滑 → 频道列表
  - 左侧上下拖拽 → 亮度调节
  - 右侧上下拖拽 → 音量调节
  - 双击 → 播放/暂停
- **广告拦截**：底层拦截统计脚本和无用资源

## 📥 安装（通过 TrollStore）

1. 前往 [Releases](../../releases) 页面下载最新 `.ipa` 文件
2. 将 `.ipa` 文件发送到 iPhone（AirDrop / 微信文件传输助手）
3. 使用 TrollStore 打开并安装

## 🛠️ 构建

本项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成 Xcode 工程。

```bash
# 安装 XcodeGen
brew install xcodegen

# 生成 Xcode 工程
cd LiteWebTV-iOS
xcodegen generate

# 打开 Xcode
open LiteWebTV.xcodeproj
```

也可以直接推送到 GitHub，利用 GitHub Actions 自动构建 `.ipa`。

## 📜 许可证

本项目遵循 [CC BY-SA 4.0](LICENSE) 协议，与上游项目保持一致。

## 🙏 鸣谢

- [YukonKong/LiteWebTV](https://github.com/YukonKong/LiteWebTV) — 原始 Android 版本
