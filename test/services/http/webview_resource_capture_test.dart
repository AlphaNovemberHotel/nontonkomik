import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/http/webview_resource_capture.dart';

void main() {
  group('WebviewResourceCaptureConfig', () {
    test('defaults keep media-shaped URLs and drop unrelated ones', () {
      const config = WebviewResourceCaptureConfig();

      expect(
        config.accept('https://r2.cloudflarestorage.com/vip/file.mkv?sig=abc'),
        isNotNull,
      );
      expect(config.accept('https://cdn.example/anime/master.m3u8'), isNotNull);
      expect(
        config.accept('https://googlevideo.com/videoplayback?id=1'),
        isNotNull,
      );
      expect(config.accept('https://cdn.example/cover.jpg'), isNull);
    });

    test('an explicit empty pattern list captures every http(s) URL', () {
      final config = WebviewResourceCaptureConfig.fromJson({'patterns': []});

      expect(config.accept('https://cdn.example/cover.jpg'), isNotNull);
      expect(config.accept('http://cdn.example/segment.bin'), isNotNull);
      expect(config.accept('blob:https://filedon.co/123'), isNull);
      expect(config.accept('data:video/mp4;base64,AAAA'), isNull);
      expect(config.accept('file:///tmp/video.mkv'), isNull);
    });

    test('custom patterns are substrings, case-insensitive', () {
      final config = WebviewResourceCaptureConfig.fromJson({
        'patterns': ['FILEDON', 'media.example'],
      });

      expect(config.accept('https://filedon.co/embed/1'), isNotNull);
      expect(config.accept('https://media.example/play'), isNotNull);
      expect(config.accept('https://example.com/file.mkv'), isNull);
    });

    test('numeric limits are clamped', () {
      final low = WebviewResourceCaptureConfig.fromJson({
        'maxResults': 0,
        'settleMs': -1,
      });
      final high = WebviewResourceCaptureConfig.fromJson({
        'maxResults': 9999,
        'settleMs': 999999,
      });

      expect(low.maxResults, 1);
      expect(low.settleMs, 0);
      expect(high.maxResults, 200);
      expect(high.settleMs, 15000);
    });
  });

  group('WebviewResourceCapture', () {
    test('de-duplicates by URL and reports newly accepted resources', () {
      final capture = WebviewResourceCapture(
        WebviewResourceCaptureConfig.fromJson({'patterns': []}),
      );

      expect(
        capture.add(url: 'https://cdn.example/a.mkv', source: 'onLoadResource'),
        isTrue,
      );
      expect(
        capture.add(url: 'https://cdn.example/a.mkv', source: 'onLoadResource'),
        isFalse,
      );
      expect(capture.resources, hasLength(1));
    });

    test('stops at maxResults and marks the result truncated', () {
      final capture = WebviewResourceCapture(
        WebviewResourceCaptureConfig.fromJson({
          'patterns': [],
          'maxResults': 2,
        }),
      );

      expect(capture.add(url: 'https://cdn.example/1', source: 'x'), isTrue);
      expect(capture.add(url: 'https://cdn.example/2', source: 'x'), isTrue);
      expect(capture.add(url: 'https://cdn.example/3', source: 'x'), isFalse);
      expect(capture.resources, hasLength(2));
      expect(capture.truncated, isTrue);
    });

    test('keeps callback metadata without headers', () {
      final capture = WebviewResourceCapture(
        WebviewResourceCaptureConfig.fromJson({'patterns': []}),
      );

      capture.add(
        url: 'https://cdn.example/video.mkv?token=secret',
        source: 'shouldInterceptRequest',
        isForMainFrame: false,
      );

      expect(capture.resources.single, {
        'url': 'https://cdn.example/video.mkv?token=secret',
        'source': 'shouldInterceptRequest',
        'isForMainFrame': false,
      });
    });
  });

  test('redactUrlForLog removes path, query and fragment', () {
    expect(
      redactUrlForLog('https://cdn.example:8443/secret/video.mkv?sig=abc#t=1'),
      'https://cdn.example:8443',
    );
    expect(redactUrlForLog('not a url'), '<invalid-url>');
  });
}
