import 'package:flutter_test/flutter_test.dart';
import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/id_generator.dart';
import 'package:clip_flow/core/services/deduplication_service.dart';
import 'package:clip_flow/core/services/clipboard/universal_clipboard_detector.dart';
import 'package:clip_flow/core/services/clipboard/clipboard_processor.dart';
import 'package:clip_flow/core/utils/color_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ID Generation and Deduplication Chain Tests', () {
    test('IDs should be consistent for same content', () {
      // Test text content
      const textContent = 'Hello, World!';
      final id1 = IdGenerator.generateId(
        ClipType.text,
        textContent,
        null,
        {},
      );
      final id2 = IdGenerator.generateId(
        ClipType.text,
        textContent,
        null,
        {},
      );
      expect(id1, equals(id2));
      expect(id1.length, equals(64)); // SHA256 hash length

      // Test color content with different formats
      const color1 = '#FF0000';
      const color2 = '#ff0000';
      const color3 = 'rgb(255, 0, 0)';

      final colorId1 = IdGenerator.generateId(
        ClipType.color,
        color1,
        null,
        {},
      );
      final colorId2 = IdGenerator.generateId(
        ClipType.color,
        color2,
        null,
        {},
      );

      // Colors should normalize to same ID
      expect(colorId1, equals(colorId2));
      expect(colorId1.length, equals(64));
    });

    test('ClipboardProcessor should use unified ID generation', () async {
      // This test verifies the flow described in the implementation
      // Note: Full clipboard processing test requires platform channels

      // Verify that ClipboardDetector creates ClipItem without ID
      final detector = ClipboardDetector();

      // Create a mock detection result
      final mockResult = ClipboardDetectionResult(
        detectedType: ClipType.text,
        contentToSave: 'Test content',
        originalData: null,
        confidence: 1.0,
        formatAnalysis: {},
      );

      // Create ClipItem from detection result
      final item1 = mockResult.createClipItem();
      final item2 = mockResult.createClipItem();

      // IDs should be generated and consistent
      expect(item1.id, equals(item2.id));
      expect(item1.id.length, equals(64));
      expect(IdGenerator.isValidId(item1.id), isTrue);
    });

    test('File identifier extraction should ignore timestamp prefixes', () {
      // Test file path with timestamp
      const filePath1 = 'media/files/image_1704067200000_abc123.jpg';
      const filePath2 = 'media/files/image_1704067201000_abc123.jpg';
      const filePath3 = 'media/files/abc123.jpg';

      final id1 = IdGenerator.generateId(
        ClipType.image,
        null,
        filePath1,
        {},
      );
      final id2 = IdGenerator.generateId(
        ClipType.image,
        null,
        filePath2,
        {},
      );
      final id3 = IdGenerator.generateId(
        ClipType.image,
        null,
        filePath3,
        {},
      );

      // Should extract same identifier (abc123.jpg) from files with same name but different timestamps
      expect(id1, equals(id2));
      expect(id1, equals(id3));
    });

    test('Color normalization should produce consistent IDs', () {
      // Test various color formats
      const colors = [
        '#FF0000',
        '#ff0000',
        '#F00',
        '#f00',
        'rgb(255, 0, 0)',
        'rgba(255, 0, 0, 1)',
      ];

      // Normalize colors first
      final normalized = colors.map((c) {
        if (c.startsWith('#') && ColorUtils.isColorValue(c)) {
          return ColorUtils.normalizeColorHex(c);
        }
        return c;
      }).toList();

      // Generate IDs
      final ids = normalized
          .map(
            (c) => IdGenerator.generateId(
              ClipType.color,
              c,
              null,
              {},
            ),
          )
          .toList();

      // First four (hex formats) should produce same ID
      expect(ids[0], equals(ids[1]));
      expect(ids[1], equals(ids[2]));
      expect(ids[2], equals(ids[3]));

      // All IDs should be 64 characters
      for (final id in ids) {
        expect(id.length, equals(64));
        expect(IdGenerator.isValidId(id), isTrue);
      }
    });

    test('DeduplicationService validates SHA256-shaped IDs', () {
      expect(
        DeduplicationService.instance.isValidId('a' * 64),
        isTrue,
      );
      expect(
        DeduplicationService.instance.isValidId('invalid_id'),
        isFalse,
      );
    });

    test('Batch deduplication works correctly', () async {
      const validId1 =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const validId2 =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final items = [
        ClipItem(
          id: validId1,
          type: ClipType.text,
          content: 'Content 1',
          metadata: {},
        ),
        ClipItem(
          id: validId2,
          type: ClipType.text,
          content: 'Content 2',
          metadata: {},
        ),
        ClipItem(
          id: validId1, // Duplicate
          type: ClipType.text,
          content: 'Content 1',
          metadata: {},
        ),
        ClipItem(
          id: '', // Invalid ID
          type: ClipType.text,
          content: 'Content 3',
          metadata: {},
        ),
      ];

      final uniqueItems = await DeduplicationService.instance.batchDeduplicate(
        items,
      );

      expect(uniqueItems.length, equals(3)); // Should remove one duplicate
      expect(uniqueItems[0].id, equals(validId1));
      expect(uniqueItems[1].id, equals(validId2));
      expect(uniqueItems[2].id, equals('')); // Invalid ID should be kept
    });
  });
}
