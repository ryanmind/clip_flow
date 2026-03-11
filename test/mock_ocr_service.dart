import 'dart:typed_data';

import 'package:clip_flow/core/services/ocr_service.dart';

/// 用于测试的模拟OCR服务
class MockOcrService implements OcrService {
  @override
  Future<bool> isAvailable() async {
    return true;
  }

  @override
  List<String> getSupportedLanguages() {
    return ['en', 'zh', 'auto'];
  }

  @override
  Future<List<String>> getAvailableLanguages() async {
    return getSupportedLanguages();
  }

  @override
  Future<OcrResult?> recognizeText(
    Uint8List imageBytes, {
    String language = 'auto',
    double? minConfidence,
  }) async {
    // 模拟OCR处理
    if (imageBytes.isEmpty) {
      return null;
    }

    // 模拟无效图像数据检测（简单的启发式：太小的数据可能无效）
    if (imageBytes.length < 10) {
      return null;
    }

    // 对于测试，返回固定的结果
    return OcrResult(
      text: 'Mock OCR Result',
      confidence: 0.95,
    );
  }

  @override
  Future<void> dispose() async {
    // 模拟清理
  }
}
