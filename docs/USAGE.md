# ClipFlow 使用说明

## 环境要求

- Flutter 3.19+
- Dart 3.9+
- macOS: Xcode 14+

## 快速开始

```bash
# 安装依赖
flutter pub get

# 运行开发版本
flutter run -d macos

# 构建发布版本
flutter build macos --release
```

## 构建脚本

```bash
# 无签名构建
./scripts/build-unsigned.sh

# 构建并创建 DMG
./scripts/build-unsigned.sh --dmg

# 发布流程
./scripts/release.sh --clean --dmg --yes
```

## 环境切换

```bash
./scripts/switch-env.sh dev   # 开发环境
./scripts/switch-env.sh prod  # 生产环境
```

## 常见问题

| 问题 | 解决方案 |
|------|----------|
| 依赖安装失败 | `flutter clean && flutter pub get` |
| 权限问题 | 系统设置 → 隐私与安全性 → 辅助功能 |
| 构建体积大 | Release 构建包含 Flutter 引擎，属正常 |
| 应用无法打开 | 右键 → 打开，或终端豁免 |

## 终端豁免

```bash
xattr -dr com.apple.quarantine "/Applications/ClipFlow.app"
```

## 目录结构

```
lib/
├── core/          # 核心服务
├── features/      # 功能模块
├── shared/        # 共享组件
└── l10n/          # 国际化

scripts/           # 构建脚本
test/              # 测试文件
```