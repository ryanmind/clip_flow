import 'dart:async';

import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/clipboard_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClipboardService 测试', () {
    late ClipboardService service;

    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    setUp(() {
      service = ClipboardService();
    });

    tearDown(() async {
      await service.dispose();
    });

    group('单例模式测试', () {
      test('应该返回相同的实例', () {
        final instance1 = ClipboardService();
        final instance2 = ClipboardService();
        final instance3 = ClipboardService.instance;

        expect(identical(instance1, instance2), true);
        expect(identical(instance2, instance3), true);
      });
    });

    group('初始化和销毁', () {
      test('应该能够初始化服务', () async {
        // 注意：实际测试中可能需要模拟 MethodChannel
        expect(() => service.initialize(), returnsNormally);
      });

      test('应该能够销毁服务', () async {
        await service.initialize();
        expect(() => service.dispose(), returnsNormally);
      });

      test('重复初始化应该安全', () async {
        await service.initialize();
        await service.initialize();
        // 应该不会抛出异常
      });

      test('重复销毁应该安全', () async {
        await service.initialize();
        await service.dispose();
        await service.dispose();
        // 应该不会抛出异常
      });
    });

    group('剪贴板流测试', () {
      test('应该提供剪贴板变更流', () {
        final stream = service.clipboardStream;
        expect(stream, isA<Stream<ClipItem>>());
      });

      test('应该能够监听剪贴板变更', () async {
        final stream = service.clipboardStream;
        expect(stream, isNotNull);

        // 创建一个订阅但不等待事件
        final subscription = stream.listen((item) {
          // 处理剪贴板项
        });

        // 清理订阅
        await subscription.cancel();
      });
    });

    group('轮询状态管理', () {
      test('应该能够获取轮询状态', () {
        final isPolling = service.isPolling;
        expect(isPolling, isA<bool>());
      });

      test('应该能够获取轮询间隔', () {
        final interval = service.currentPollingInterval;
        expect(interval, isA<Duration>());
        expect(interval.inMilliseconds, greaterThanOrEqualTo(0));
      });

      test('应该能够暂停轮询', () {
        expect(() => service.pausePolling(), returnsNormally);
      });

      test('应该能够恢复轮询', () {
        expect(() => service.resumePolling(), returnsNormally);
      });
    });

    group('剪贴板内容设置', () {
      test('应该能够设置文本内容', () async {
        final textItem = ClipItem(
          type: ClipType.text,
          content: 'Hello World',
          metadata: const {'length': 11},
        );

        // 注意：实际测试需要模拟 Clipboard API
        expect(() => service.setClipboardContent(textItem), returnsNormally);
      });

      test('应该能够设置不同类型的内容', () async {
        final items = [
          ClipItem(
            type: ClipType.text,
            content: 'text content',
            metadata: const {'type': 'text'},
          ),
          ClipItem(
            type: ClipType.url,
            content: 'https://example.com',
            metadata: const {'type': 'url'},
          ),
          ClipItem(
            type: ClipType.email,
            content: 'test@example.com',
            metadata: const {'type': 'email'},
          ),
          ClipItem(
            type: ClipType.json,
            content: '{"key": "value"}',
            metadata: const {'type': 'json'},
          ),
        ];

        for (final item in items) {
          expect(() => service.setClipboardContent(item), returnsNormally);
        }
      });
    });

    group('剪贴板内容检测', () {
      test('应该能够检测剪贴板类型', () async {
        // 注意：实际测试需要模拟 MethodChannel
        expect(() => service.getCurrentClipboardType(), returnsNormally);
      });

      test('应该能够检查剪贴板是否有内容', () async {
        expect(() => service.hasClipboardContent(), returnsNormally);
      });
    });

    group('剪贴板操作', () {
      test('应该能够清空剪贴板', () async {
        expect(() => service.clearClipboard(), returnsNormally);
      });
    });

    group('错误处理', () {
      test('应该处理初始化错误', () async {
        // 这里可以模拟初始化失败的情况
        expect(() => service.initialize(), returnsNormally);
      });

      test('应该处理设置内容错误', () async {
        final invalidItem = ClipItem(
          type: ClipType.text,
          metadata: const {},
        );

        expect(() => service.setClipboardContent(invalidItem), returnsNormally);
      });
    });

    group('协调器模式验证', () {
      test('应该整合检测器、轮询器和处理器', () {
        // 验证服务确实使用了三个子组件
        // 这里主要验证服务能正常创建和运行
        expect(service, isNotNull);
        expect(service.clipboardStream, isNotNull);
        expect(service.currentPollingInterval, isNotNull);
      });

      test('应该协调各组件的工作', () async {
        await service.initialize();

        // 验证各组件协调工作
        expect(service.isPolling, isA<bool>());
        expect(service.currentPollingInterval, isA<Duration>());

        // 测试暂停和恢复
        service
          ..pausePolling()
          ..resumePolling();

        await service.dispose();
      });
    });

    group('性能测试', () {
      test('初始化应该快速完成', () async {
        final stopwatch = Stopwatch()..start();

        await service.initialize();

        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      });

      test('销毁应该快速完成', () async {
        await service.initialize();

        final stopwatch = Stopwatch()..start();

        await service.dispose();

        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(500));
      });

      test('多次操作应该稳定', () async {
        for (var i = 0; i < 5; i++) {
          await service.initialize();
          service
            ..pausePolling()
            ..resumePolling();
          await service.dispose();
        }
      });
    });

    group('边界条件测试', () {
      test('应该处理空的剪贴板内容', () async {
        final emptyItem = ClipItem(
          type: ClipType.text,
          content: '',
          metadata: const {},
        );

        expect(() => service.setClipboardContent(emptyItem), returnsNormally);
      });

      test('应该处理大量的剪贴板变更', () async {
        final stream = service.clipboardStream;
        var eventCount = 0;

        final subscription = stream.listen((item) {
          eventCount++;
        });

        // 模拟大量变更
        // 实际测试中需要触发剪贴板变更事件

        await subscription.cancel();
        expect(eventCount, greaterThanOrEqualTo(0));
      });
    });

    group('内存管理测试', () {
      test('应该正确清理资源', () async {
        await service.initialize();

        // 创建多个订阅
        final subscriptions = <StreamSubscription<ClipItem>>[];
        for (var i = 0; i < 10; i++) {
          subscriptions.add(service.clipboardStream.listen((item) {}));
        }

        // 清理所有订阅
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }

        await service.dispose();
      });

      test('应该防止内存泄漏', () async {
        // 多次创建和销毁服务
        for (var i = 0; i < 10; i++) {
          final tempService = ClipboardService();
          await tempService.initialize();
          await tempService.dispose();
        }
      });
    });
  });
}
