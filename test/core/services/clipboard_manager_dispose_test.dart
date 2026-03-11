import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/clipboard/clipboard_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClipboardManager dispose', () {
    test('flushes buffered items before shutdown completes', () async {
      final flushedBatches = <List<ClipItem>>[];
      final manager = ClipboardManager.test(
        batchInsertOverride: (items) async {
          flushedBatches.add(List<ClipItem>.from(items));
        },
      );
      final item = ClipItem(
        id: 'dispose-buffered-item',
        type: ClipType.text,
        content: 'buffered text',
        metadata: const {},
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

      manager.debugBufferItem(item);
      expect(manager.debugBufferedItemCount, 1);

      await manager.dispose();

      expect(manager.debugBufferedItemCount, 0);
      expect(flushedBatches, hasLength(1));
      expect(flushedBatches.single.single.id, item.id);
    });
  });
}
