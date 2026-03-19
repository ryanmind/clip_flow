# ClipFlow 构建与发布指南

本文档说明构建流程、代码签名和发布策略。

## 快速开始

### 环境要求

- Flutter 3.19+
- Dart 3.9+
- macOS: Xcode 14+

### 常用命令

```bash
# 开发运行
flutter run -d macos

# 构建发布版本
flutter build macos --release

# 使用脚本构建（推荐）
./scripts/build-unsigned.sh --dmg
```

## 构建脚本

项目提供以下脚本：

| 脚本 | 用途 |
|------|------|
| `build.sh` | 通用构建脚本 |
| `build-unsigned.sh` | 无签名构建 |
| `release.sh` | 发布流程 |
| `switch-env.sh` | 环境切换 |
| `version-manager.sh` | 版本管理 |

### 无签名构建

```bash
# 基本构建
./scripts/build-unsigned.sh

# 构建并创建 DMG
./scripts/build-unsigned.sh --clean --dmg

# 生产环境构建
./scripts/build-unsigned.sh --env prod --dmg
```

### 发布流程

```bash
# 完整发布（自动版本号）
./scripts/release.sh --clean --dmg --yes

# 指定版本
./scripts/release.sh v1.0.0 --clean --dmg --yes
```

## 环境配置

### 开发环境

- 包名: `com.clipflow.app.dev`
- 应用名: `ClipFlow Dev`

### 生产环境

- 包名: `com.clipflow.app`
- 应用名: `ClipFlow`

```bash
# 切换环境
./scripts/switch-env.sh dev   # 开发
./scripts/switch-env.sh prod  # 生产
```

## 代码签名

### 无证书情况

ClipFlow 目前没有 Apple 开发者证书，用户安装时会遇到安全警告。

**解决方案**：

1. **右键打开**：右键点击应用 → 选择"打开" → 点击"打开"
2. **终端豁免**：
   ```bash
   xattr -dr com.apple.quarantine "/Applications/ClipFlow.app"
   ```

### 申请证书（推荐）

公开分发建议申请 Apple Developer 账号（$99/年）：
1. 获取 Developer ID 证书
2. 进行代码签名
3. 提交公证

## 安装包制作

### DMG 安装包

```bash
# 使用脚本自动生成
./scripts/build-unsigned.sh --dmg

# 手动创建
hdiutil create -volname "ClipFlow" \
  -srcfolder "build/macos/Build/Products/Release/ClipFlow.app" \
  -ov -format UDZO ClipFlow.dmg
```

### PKG 安装器（一键安装）

```bash
# 准备目录结构
mkdir -p build/pkgroot/Applications
cp -R build/macos/Build/Products/Release/ClipFlow.app \
      build/pkgroot/Applications/

# 生成 PKG
pkgbuild --root build/pkgroot \
  --install-location / \
  --identifier com.clipflow.app \
  --version "1.0.0" \
  build/ClipFlow-1.0.0-macos.pkg
```

## 常见问题

### 应用无法打开

macOS 安全机制阻止未签名应用：

```bash
# 解除隔离
xattr -dr com.apple.quarantine "/Applications/ClipFlow.app"
```

### 权限重复弹窗

将应用安装到 `/Applications` 目录，保持路径稳定。

### 构建失败

```bash
# 清理缓存
flutter clean && flutter pub get
```

## 文件命名规范

```
ClipFlow-v1.0.0-macos.dmg
ClipFlow-v1.0.0-macos.dmg.sha256
```

## 参考资源

- [Apple Developer Program](https://developer.apple.com/programs/)
- [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
