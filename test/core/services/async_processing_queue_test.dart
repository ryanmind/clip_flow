import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/async_processing_queue.dart';
import 'package:flutter_test/flutter_test.dart';

ClipItem _item(String id) {
  return ClipItem(
    id: id,
    type: ClipType.text,
    content: id,
    metadata: const {},
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AsyncProcessingQueue', () {
    test(
      'processes higher priority items before lower priority items',
      () async {
        final queue = AsyncProcessingQueue(maxConcurrentTasks: 1);
        final order = <String>[];

        final normalFuture = queue.addClipboardTask(
          item: _item('normal'),
          processor: (item) async {
            order.add(item.id);
            return item;
          },
        );
        final highFuture = queue.addClipboardTask(
          item: _item('high'),
          priority: Priority.high,
          processor: (item) async {
            order.add(item.id);
            return item;
          },
        );

        queue.start();

        final results = await Future.wait([highFuture, normalFuture]);

        expect(results.whereType<ClipItem>().map((item) => item.id), [
          'high',
          'normal',
        ]);
        expect(order, ['high', 'normal']);
        queue.stop();
      },
    );

    test('drops the lowest priority oldest queued task when full', () async {
      final queue = AsyncProcessingQueue(
        maxConcurrentTasks: 1,
        maxQueueSize: 2,
      );
      final processed = <String>[];

      final droppedFuture = queue.addClipboardTask(
        item: _item('low-oldest'),
        priority: Priority.low,
        processor: (item) async {
          processed.add(item.id);
          return item;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      final keptLowFuture = queue.addClipboardTask(
        item: _item('low-newer'),
        priority: Priority.low,
        processor: (item) async {
          processed.add(item.id);
          return item;
        },
      );
      final highFuture = queue.addClipboardTask(
        item: _item('high-priority'),
        priority: Priority.high,
        processor: (item) async {
          processed.add(item.id);
          return item;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(await droppedFuture, isNull);
      expect(queue.getStats()['pendingItems'], 2);

      queue.start();

      final highResult = await highFuture;
      final lowResult = await keptLowFuture;
      final retryResult = await queue.addClipboardTask(
        item: _item('low-oldest'),
        processor: (item) async {
          processed.add('${item.id}-retry');
          return item;
        },
      );

      expect(highResult?.id, 'high-priority');
      expect(lowResult?.id, 'low-newer');
      expect(retryResult?.id, 'low-oldest');
      expect(processed, ['high-priority', 'low-newer', 'low-oldest-retry']);
      queue.stop();
    });

    test(
      'continues draining queued tasks after the first batch completes',
      () async {
        final queue = AsyncProcessingQueue(maxConcurrentTasks: 2);
        final processed = <String>[];

        queue.start();

        final futures = List.generate(6, (index) {
          final item = _item('task-$index');
          return queue.addClipboardTask(
            item: item,
            processor: (queuedItem) async {
              await Future<void>.delayed(const Duration(milliseconds: 5));
              processed.add(queuedItem.id);
              return queuedItem;
            },
          );
        });

        final results = await Future.wait(futures);

        expect(results.whereType<ClipItem>().length, 6);
        expect(processed, hasLength(6));
        expect(queue.getStats()['totalProcessed'], 6);
        queue.stop();
      },
    );
  });
}
