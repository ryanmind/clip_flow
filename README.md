# ClipFlow - 跨平台剪贴板历史管理工具

[![Flutter](https://img.shields.io/badge/Flutter-3.19+-02569B?logo=flutter)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.9+-0175C2?logo=dart)](https://dart.dev/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

一款基于 Flutter 的智能剪贴板历史管理工具。支持 macOS（已验证）、Windows 和 Linux（待测试）。

## 特性

- **多格式支持** - 文本、富文本、图片、代码、JSON、URL、文件等
- **智能识别** - 自动识别内容类型，提取元数据
- **双模式界面** - 经典模式 + 紧凑模式
- **极速性能** - 毫秒级监听、智能去重、异步处理
- **OCR 识别** - 图片文字提取
- **数据加密** - AES-256-GCM 本地加密
- **国际化** - 中英文支持

## 快速开始

### 安装

**下载安装**：macOS 用户可直接下载 `ClipFlow.dmg`

**从源码构建**：
```bash
git clone https://github.com/ryanmind/clip_flow.git
cd clip_flow
flutter pub get
flutter run              # 开发
flutter build macos      # 构建
```

### 权限配置 (macOS)

系统偏好设置 → 安全性与隐私 → 隐私 → 辅助功能 → 添加 ClipFlow

## 快捷键

| 功能 | macOS | Windows/Linux |
|------|-------|---------------|
| 显示/隐藏 | `Cmd + Option + \`` | `Ctrl + Alt + \`` |
| 快速粘贴 | `Cmd + Ctrl + V` | `Ctrl + Win + V` |
| 历史记录 | `Cmd + F9` | `Ctrl + F9` |
| 搜索 | `Cmd + Shift + F` | `Ctrl + Shift + F` |
| OCR | `Cmd + F8` | `Ctrl + F8` |

## 界面预览

| 经典模式 | 紧凑模式 |
|:--------:|:--------:|
| ![](readme_images/classicMode.png) | ![](readme_images/compact.png) |

## 开发

```bash
flutter analyze           # 代码分析
flutter test --coverage   # 测试
flutter gen-l10n          # 国际化
./scripts/build.sh --dmg  # 构建 DMG
```

## 对比

| 特性 | ClipFlow | Alfred | Paste | Raycast |
|------|:--------:|:------:|:-----:|:-------:|
| 开源免费 | ✅ | ❌ | ❌ | ❌ |
| 跨平台 | ✅ | ❌ | ❌ | ❌ |
| OCR | ✅ | ❌ | ✅ | ✅ |
| 本地存储 | ✅ | ⚠️ | ⚠️ | ⚠️ |

## 许可证

[MIT](LICENSE)

## 链接

- **项目主页**：https://github.com/ryanmind/clip_flow
- **问题反馈**：https://github.com/ryanmind/clip_flow/issues