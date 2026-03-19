# 图标使用指南

## 快速生成

```bash
python3 scripts/fresh_clipboard_icon_generator.py
flutter clean
flutter build macos --release
```

## 图标尺寸

| 平台 | 尺寸 |
|------|------|
| macOS | 16, 32, 64, 128, 256, 512, 1024 |
| Web | 32, 192, 512 |

## 文件位置

```
assets/icons/                    # SVG 源文件
macos/Runner/Assets.xcassets/   # macOS 图标
web/icons/                       # Web 图标
```

## 自定义图标

1. 编辑 `assets/icons/app_icon_1024.svg`
2. 保持 1024×1024 画布
3. 运行生成脚本

## 故障排查

- **图标不显示**：运行 `flutter clean`
- **图标模糊**：检查 SVG 源文件质量
