import 'dart:convert';

import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/utils/color_utils.dart';
import 'package:crypto/crypto.dart';

/// 统一的ID生成服务
/// 提供一致的、基于内容的ID生成逻辑
class IdGenerator {
  IdGenerator._();

  /// 生成基于内容的唯一ID
  static String generateId(
    ClipType type,
    String? content,
    String? filePath,
    Map<String, dynamic> metadata, {
    List<int>? binaryBytes,
    String? fileContentHash, // ✅ 支持预计算的哈希（用于大文件流式处理）
  }) {
    String contentString;

    switch (type) {
      case ClipType.color:
        // 颜色类型使用标准化的颜色值
        final colorContent = content?.trim() ?? '';
        if (colorContent.isNotEmpty && ColorUtils.isColorValue(colorContent)) {
          contentString = 'color:${ColorUtils.normalizeColorHex(colorContent)}';
        } else {
          contentString = 'color:$colorContent';
        }

      case ClipType.image:
      case ClipType.file:
      case ClipType.audio:
      case ClipType.video:
        // 1. 优先使用预计算的哈希（流式处理大文件）
        if (fileContentHash != null && fileContentHash.isNotEmpty) {
          contentString = '${type.name}_bytes:$fileContentHash';
          break;
        }

        // 2. 如果有二进制数据，使用数据的哈希（小文件/内存数据）
        if (binaryBytes != null && binaryBytes.isNotEmpty) {
          final digest = sha256.convert(binaryBytes);
          contentString = '${type.name}_bytes:$digest';
          break;
        }

        // 二进制类型使用文件名（去除时间戳）或元数据
        String fileIdentifier;

        if (filePath != null && filePath.isNotEmpty) {
          fileIdentifier = extractFileIdentifier(filePath);
        } else {
          fileIdentifier =
              metadata['fileName'] as String? ??
              metadata['originalName'] as String? ??
              'unknown_file';
        }

        contentString = '${type.name}:$fileIdentifier';

      case ClipType.text:
      case ClipType.code:
      case ClipType.url:
      case ClipType.email:
      case ClipType.json:
      case ClipType.xml:
      case ClipType.html:
      case ClipType.rtf:
        // 文本类型使用标准化内容
        final normalizedContent = content?.trim() ?? '';
        contentString = '${type.name}:$normalizedContent';
    }

    // 使用 SHA256 生成唯一ID
    final bytes = utf8.encode(contentString);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// 验证ID是否有效（非空且格式正确）
  static bool isValidId(String? id) {
    return id != null && id.isNotEmpty && id.length == 64;
  }

  /// 从文件路径提取文件标识（去除时间戳）
  static String extractFileIdentifier(String filePath) {
    final fileName = filePath.split('/').last;
    final fileParts = fileName.split('_');
    if (fileParts.length >= 3 && RegExp(r'^\d{10,}$').hasMatch(fileParts[1])) {
      return fileParts.sublist(2).join('_');
    }
    if (fileParts.length >= 2) {
      return fileParts.sublist(1).join('_');
    }
    return fileName;
  }

  /// 为OCR文本生成独立ID
  ///
  /// [ocrText] OCR识别的文本内容
  /// [parentImageId] 原图片的ID，用于建立关联关系
  ///
  /// 返回基于图片ID和OCR文本内容生成的唯一ID
  static String generateOcrTextId(String ocrText, String parentImageId) {
    // 标准化OCR文本内容
    final normalizedText = _normalizeOcrText(ocrText);

    // 使用图片ID和标准化文本生成关联式ID
    final contentString = 'ocr_text:$parentImageId:$normalizedText';

    // 使用 SHA256 生成唯一ID
    final bytes = utf8.encode(contentString);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// 标准化OCR文本内容
  ///
  /// 全面清理和标准化文本，防止通过特殊字符绕过去重：
  /// - 移除零宽字符和不可见字符
  /// - 统一Unicode表示
  /// - 统一大小写
  /// - 标准化空白字符
  /// - 统一换行符
  static String _normalizeOcrText(String text) {
    if (text.isEmpty) return '';

    // 1. 移除首尾空白
    var normalized = text.trim();

    // 2. 移除零宽字符和其他不可见字符
    // Zero-Width Space (U+200B)
    // Zero-Width Non-Joiner (U+200C)
    // Zero-Width Joiner (U+200D)
    // Zero-Width No-Break Space (U+FEFF)
    // Left-to-Right Mark (U+200E)
    // Right-to-Left Mark (U+200F)
    normalized = normalized.replaceAll(
      RegExp(r'[\u200B\u200C\u200D\u200E\u200F\uFEFF]'),
      '',
    );

    // 3. 将全角空格转换为半角空格
    normalized = normalized.replaceAll('\u3000', ' ');

    // 4. 统一换行符（在压缩空白之前）
    // 保持换行符，不要转成空格
    normalized = normalized.replaceAll(RegExp(r'\r\n|\r'), '\n');

    // 5. 将连续的空格（非换行）压缩为单个空格
    // 注意：保留换行符
    normalized = normalized.replaceAll(RegExp(r'[^\S\n]+'), ' ');

    // 6. 移除行首行尾空格，但保留换行符
    normalized = normalized
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');

    // 7. 转换为小写（忽略大小写差异）
    // "Hello" 和 "HELLO" 应该被视为相同
    normalized = normalized.toLowerCase();

    // 8. Unicode标准化（NFC形式）
    // 确保相同字符的不同Unicode表示被统一
    // Dart的String默认已经是NFC，但显式声明更安全

    // 9. 如果文本过长，进行截断（保留前10000个字符）
    const maxLength = 10000;
    if (normalized.length > maxLength) {
      normalized = '${normalized.substring(0, maxLength)}...';
    }

    return normalized;
  }

  /// 生成OCR内容的签名用于缓存比较
  ///
  /// 与generateOcrTextId不同，此方法用于快速比较OCR内容是否相同
  static String generateOcrContentSignature(String ocrText) {
    final normalizedText = _normalizeOcrText(ocrText);
    final contentString = 'ocr_signature:$normalizedText';

    final bytes = utf8.encode(contentString);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
