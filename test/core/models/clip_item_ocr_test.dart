import 'package:flutter_test/flutter_test.dart';
import 'package:clip_flow/core/models/clip_item.dart';

void main() {
  group('ClipItem OCR Tests', () {
    const imageId =
        'a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef1234567890';
    const ocrTextId =
        'f6e5d4c3b2a1098765432109876543210fedcba09876543210fedcba0987654321';

    test('should create ClipItem with OCR fields', () {
      final clipItem = ClipItem(
        type: ClipType.image,
        content: 'image content',
        metadata: {'fileName': 'test.png', 'parentImageId': imageId},
        ocrText: 'Sample OCR text',
        ocrTextId: ocrTextId,
        isOcrExtracted: true,
      );

      expect(clipItem.ocrText, equals('Sample OCR text'));
      expect(clipItem.ocrTextId, equals(ocrTextId));
      expect(clipItem.metadata['parentImageId'], equals(imageId));
      expect(clipItem.isOcrExtracted, equals(true));
    });

    test('should create ClipItem with default OCR values', () {
      final clipItem = ClipItem(
        type: ClipType.image,
        content: 'image content',
        metadata: {'fileName': 'test.png'},
      );

      expect(clipItem.ocrText, isNull);
      expect(clipItem.ocrTextId, isNull);
      expect(clipItem.metadata['parentImageId'], isNull);
      expect(clipItem.isOcrExtracted, equals(false));
    });

    test('should serialize OCR fields to JSON', () {
      final clipItem = ClipItem(
        type: ClipType.image,
        content: 'image content',
        metadata: {'fileName': 'test.png', 'parentImageId': imageId},
        ocrText: 'Sample OCR text',
        ocrTextId: ocrTextId,
        isOcrExtracted: true,
      );

      final json = clipItem.toJson();

      expect(json['ocrText'], equals('Sample OCR text'));
      expect(json['ocrTextId'], equals(ocrTextId));
      expect(json['metadata']['parentImageId'], equals(imageId));
      expect(json['isOcrExtracted'], equals(true));
    });

    test('should deserialize OCR fields from JSON', () {
      final json = {
        'id': imageId,
        'type': 'image',
        'content': 'image content',
        'metadata': {'fileName': 'test.png', 'parentImageId': imageId},
        'ocrText': 'Sample OCR text',
        'ocrTextId': ocrTextId,
        'isOcrExtracted': true,
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final clipItem = ClipItem.fromJson(json);

      expect(clipItem.ocrText, equals('Sample OCR text'));
      expect(clipItem.ocrTextId, equals(ocrTextId));
      expect(clipItem.metadata['parentImageId'], equals(imageId));
      expect(clipItem.isOcrExtracted, equals(true));
    });

    test('should handle missing OCR fields in JSON', () {
      final json = {
        'id': imageId,
        'type': 'image',
        'content': 'image content',
        'metadata': {'fileName': 'test.png'},
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final clipItem = ClipItem.fromJson(json);

      expect(clipItem.ocrText, isNull);
      expect(clipItem.ocrTextId, isNull);
      expect(clipItem.metadata['parentImageId'], isNull);
      expect(clipItem.isOcrExtracted, equals(false));
    });

    test('should copy with OCR fields', () {
      final originalItem = ClipItem(
        type: ClipType.image,
        content: 'image content',
        metadata: {'fileName': 'test.png', 'parentImageId': imageId},
        ocrText: 'Original OCR text',
        ocrTextId: ocrTextId,
        isOcrExtracted: true,
      );

      final updatedItem = originalItem.copyWith(
        ocrText: 'Updated OCR text',
        isOcrExtracted: false,
      );

      expect(updatedItem.ocrText, equals('Updated OCR text'));
      expect(updatedItem.ocrTextId, equals(ocrTextId)); // unchanged
      expect(
        updatedItem.metadata['parentImageId'],
        equals(imageId),
      ); // unchanged
      expect(updatedItem.isOcrExtracted, equals(false));
      expect(updatedItem.id, equals(originalItem.id)); // unchanged
    });

    test('should create OCR text item linked to parent image', () {
      final ocrTextItem = ClipItem(
        type: ClipType.text,
        content: 'Extracted OCR text',
        metadata: {'source': 'ocr', 'parentImageId': imageId},
        ocrText: 'Extracted OCR text',
        ocrTextId: ocrTextId,
        isOcrExtracted: true,
      );

      expect(ocrTextItem.type, equals(ClipType.text));
      expect(ocrTextItem.content, equals('Extracted OCR text'));
      expect(ocrTextItem.ocrText, equals('Extracted OCR text'));
      expect(ocrTextItem.ocrTextId, equals(ocrTextId));
      expect(ocrTextItem.metadata['parentImageId'], equals(imageId));
      expect(ocrTextItem.isOcrExtracted, equals(true));
    });

    test('should handle null OCR fields gracefully', () {
      final clipItem = ClipItem(
        type: ClipType.image,
        content: 'image content',
        metadata: {'fileName': 'test.png'},
        ocrText: null,
        ocrTextId: null,
      );

      final copiedItem = clipItem.copyWith();

      expect(copiedItem.ocrText, isNull);
      expect(copiedItem.ocrTextId, isNull);
      expect(copiedItem.metadata['parentImageId'], isNull);
      expect(copiedItem.isOcrExtracted, equals(false));
    });

    test('should handle boolean conversion from JSON', () {
      final jsonWithTrue = {
        'id': imageId,
        'type': 'image',
        'content': 'image content',
        'metadata': {'fileName': 'test.png'},
        'isOcrExtracted': true,
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final jsonWithFalse = {
        'id': imageId,
        'type': 'image',
        'content': 'image content',
        'metadata': {'fileName': 'test.png'},
        'isOcrExtracted': false,
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final jsonWithNull = {
        'id': imageId,
        'type': 'image',
        'content': 'image content',
        'metadata': {'fileName': 'test.png'},
        'isOcrExtracted': null,
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final itemWithTrue = ClipItem.fromJson(jsonWithTrue);
      final itemWithFalse = ClipItem.fromJson(jsonWithFalse);
      final itemWithNull = ClipItem.fromJson(jsonWithNull);

      expect(itemWithTrue.isOcrExtracted, equals(true));
      expect(itemWithFalse.isOcrExtracted, equals(false));
      expect(itemWithNull.isOcrExtracted, equals(false)); // default to false
    });

    test('should maintain immutability with OCR fields', () {
      final originalItem = ClipItem(
        type: ClipType.image,
        content: 'image content',
        metadata: {'fileName': 'test.png'},
        ocrText: 'Original OCR text',
      );

      final modifiedItem = originalItem.copyWith(
        ocrText: 'Modified OCR text',
      );

      // Original item should remain unchanged
      expect(originalItem.ocrText, equals('Original OCR text'));
      expect(originalItem.isOcrExtracted, equals(false));

      // Modified item should have the new values
      expect(modifiedItem.ocrText, equals('Modified OCR text'));
      expect(modifiedItem.isOcrExtracted, equals(false));
      expect(modifiedItem.id, equals(originalItem.id));
    });
  });
}
