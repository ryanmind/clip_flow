import 'package:clip_flow/core/services/clipboard_service.dart';
import 'package:clip_flow/shared/providers/app_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('clipboard_service');

  group('clipboardServiceProvider', () {
    test(
      'returns the singleton without triggering platform initialization',
      () async {
        var methodCallCount = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (call) async {
              methodCallCount++;
              return 1;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(methodChannel, null);
        });

        final container = ProviderContainer();
        addTearDown(container.dispose);

        final service = container.read(clipboardServiceProvider);

        expect(service, same(ClipboardService.instance));
        expect(methodCallCount, 0);
      },
    );
  });
}
