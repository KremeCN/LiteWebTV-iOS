# LiteWebTV-iOS 📺

**LiteWebTV 的全原生 iOS 重构版本 —— 基于 Swift + SwiftUI 打造的纯净直播客户端。**

> ⚠️ **声明与致谢**  
> 本项目是基于开源项目 [YukonKong/LiteWebTV](https://github.com/YukonKong/LiteWebTV) 重新实现的 iOS 版本。  
> 核心产品理念、UI 布局逻辑以及核心自动化 Web 脚本（跳过片头、自动清晰度等）的版权均归属原作者 YukonKong。  
> 本仓库在保留原汁原味体验的基础上，使用了苹果原生的 **SwiftUI + WKWebView** 架构进行了从 0 到 1 的彻底重构，以完美适配 iOS 设备的交互规范与硬件特性。

## ✨ iOS 原生特性增强

除了完美继承原版所有的核心功能（极速秒播、智能幕布、广告拦截）之外，iOS 版深度定制了以下独占特性：

- 🍏 **满血 SwiftUI 原生架构**：彻底抛弃跨平台中间件，丝滑流畅的视图构建与切换。
- 📱 **刘海 / 灵动岛完美避让**：通过底层 `UIWindow` 直接抓取物理安全区数据，无论左转横屏还是右转横屏，UI 完美贴合屏幕边缘，不差一根像素。
- 👆 **沉浸式手势触控**：
  - **边缘滑动**：左边缘向右滑呼出「节目单」 | 右边缘向左滑呼出「频道列表」
  - **上下滑动（防抖）**：全屏幕上下滑动快速切换频道（内置 3 秒防抖，防止误触连切）
  - **亮度与音量**：屏幕左侧上下拖拽调节**系统亮度** | 屏幕右侧上下拖拽调节**系统音量**
  - **双击**：双击屏幕中央切换 播放 / 暂停 状态
- 🎨 **高级视觉规范**：内置基于系统渲染引擎的魅影紫呼吸灯开屏、以及符合 iOS 规范的圆角（Squircle）桌面图标。
- 🤖 **全自动 CI/CD 打包**：内置 GitHub Actions 脚本，推送代码即自动生成最新编译的 `.ipa` 安装包。

## 📥 安装运行（TrollStore 巨魔推荐）

由于苹果的限制，本项目更适合通过签名工具侧载安装。

1. 进入当前仓库的 **[Actions](https://github.com/KremeCN/LiteWebTV-iOS/actions)** 页面（或 **Releases** 页面如果已发布）。
2. 下载最新构建的 `LiteWebTV-iOS.ipa` 安装包文件。
3. 将 `.ipa` 发送到你的 iPhone 或 iPad 上（推荐使用 AirDrop 或文件传输助手）。
4. 使用 **TrollStore（巨魔商店）** 或 **AltStore / 签名证书** 进行安装。

## 🛠️ 源码编译与定制

本项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 进行工程文件的统一管理，避免了 Git 冲突。

```bash
# 1. 克隆代码仓库
git clone https://github.com/KremeCN/LiteWebTV-iOS.git
cd LiteWebTV-iOS

# 2. 安装 XcodeGen 环境 (通过 Homebrew)
brew install xcodegen

# 3. 生成 Xcode 工程文件
xcodegen generate

# 4. 双击打开工程开始编译！
open LiteWebTV.xcodeproj
```

> **提示**：本项目已配置 GitHub Actions 工作流。Fork 本项目后，只需推送代码（`git push`），即可自动触发 CI 流程并构建 `.ipa` 安装包，构建产物可在仓库的 Actions 页面获取。

## 📜 许可证

本项目为免费的开源软件，并严格遵循与上游项目一致的 **[CC BY-SA 4.0](LICENSE)** 许可协议。

## 🙏 鸣谢

- [YukonKong/LiteWebTV](https://github.com/YukonKong/LiteWebTV) — 原始项目与卓越的播放器设计灵感。
