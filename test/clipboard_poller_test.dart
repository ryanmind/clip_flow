import 'package:clip_flow/core/services/clipboard_poller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('clipboard_service');
  const eventChannel = EventChannel('clipboard_events');

  late ClipboardPoller poller;
  late MockStreamHandlerEventSink eventSink;
  late bool shouldFailStream;
  late int mockSequence;

  setUp(() {
    poller = ClipboardPoller();
    shouldFailStream = false;
    mockSequence = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          if (call.method == 'getClipboardSequence') {
            return mockSequence;
          }
          return null;
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          eventChannel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {
              if (shouldFailStream) {
                events.error(code: 'STREAM_ERROR', message: 'stream failed');
                return;
              }
              eventSink = events;
            },
          ),
        );
  });

  tearDown(() {
    poller.stopPolling();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
  });

  group('ClipboardPoller', () {
    test('初始状态为未监听，间隔为 0', () {
      expect(poller.isPolling, isFalse);
      expect(poller.currentInterval, Duration.zero);
    });

    test('启动后优先进入原生事件模式', () async {
      poller.startPolling();
      await Future<void>.delayed(Duration.zero);

      final stats = poller.getPollingStats();
      expect(poller.isPolling, isTrue);
      expect(stats['monitoringMode'], 'native_events');
      expect(stats['isUsingFallbackPolling'], isFalse);
      expect(poller.currentInterval, Duration.zero);
    });

    test('收到原生事件后触发回调并更新统计', () async {
      var callbackCount = 0;
      poller.startPolling(onClipboardChanged: () => callbackCount++);
      await Future<void>.delayed(Duration.zero);

      eventSink.success(<String, Object?>{
        'sequence': 1,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'platform': 'linux',
        'source': 'owner-change',
        'monitoringIntervalMs': 0,
      });
      await Future<void>.delayed(Duration.zero);

      final stats = poller.getPollingStats();
      expect(callbackCount, 1);
      expect(stats['totalNativeEvents'], 1);
      expect(stats['successfulChecks'], 1);
      expect(stats['monitoringMode'], 'native_events');
    });

    test('事件流失败时回退到 Dart 轮询', () async {
      shouldFailStream = true;
      final errors = <String>[];

      poller.startPolling(onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final stats = poller.getPollingStats();
      expect(stats['monitoringMode'], 'fallback_polling');
      expect(stats['isUsingFallbackPolling'], isTrue);
      expect(poller.currentInterval, const Duration(milliseconds: 500));
      expect(errors.single, contains('已回退到轮询监听'));
    });

    test('pause 和 resume 会切换活动状态', () async {
      poller.startPolling();
      await Future<void>.delayed(Duration.zero);
      expect(poller.isPolling, isTrue);

      poller.pausePolling();
      expect(poller.isPolling, isFalse);

      poller.resumePolling();
      await Future<void>.delayed(Duration.zero);
      expect(poller.isPolling, isTrue);
    });

    test('checkOnce 使用序列号比较变化', () async {
      mockSequence = 1;
      expect(await poller.checkOnce(), isTrue);

      expect(await poller.checkOnce(), isFalse);

      mockSequence = 2;
      expect(await poller.checkOnce(), isTrue);

      final stats = poller.getPollingStats();
      expect(stats['totalChecks'], 3);
      expect(stats['successfulChecks'], 2);
    });

    test('快速连续事件会进入快速复制模式', () async {
      poller.startPolling();
      await Future<void>.delayed(Duration.zero);

      for (var i = 1; i <= 3; i++) {
        eventSink.success(<String, Object?>{
          'sequence': i,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'platform': 'windows',
          'source': 'wm_clipboardupdate',
          'monitoringIntervalMs': 0,
        });
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      final stats = poller.getPollingStats();
      expect(stats['isRapidCopyMode'], isTrue);
      expect(stats['rapidCopyCount'], greaterThanOrEqualTo(3));
    });
  });
}
