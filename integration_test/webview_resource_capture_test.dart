import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:mangayomi/services/http/m_client.dart';

/// Android emulator check for the native resource observer:
/// - a cross-origin iframe fetches a media-shaped URL;
/// - `evaluateJavascriptViaWebviewWithResourceCapture` reports it;
/// - the old `evaluateJavascriptViaWebview` endpoint still returns its
///   script's `setResponse` value.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer pageServer;
  late HttpServer frameServer;
  late String pageUrl;
  late String frameUrl;
  final frameRequests = <String>[];

  setUpAll(() async {
    await webviewServer();
    expect(cfPort, isNot(0));

    pageServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    frameServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    final pageOrigin = 'http://127.0.0.1:${pageServer.port}';
    final frameOrigin = 'http://127.0.0.1:${frameServer.port}';

    frameServer.listen((request) async {
      final response = request.response;
      response.headers.removeAll('x-frame-options');
      frameRequests.add(request.uri.path);
      if (request.uri.path == '/frame.html') {
        final body = '''
<!doctype html>
<html><body>
<script src="/probe.mkv"></script>
</body></html>
''';
        response
          ..headers.contentType = ContentType.html
          ..contentLength = utf8.encode(body).length
          ..write(body);
      } else if (request.uri.path == '/probe.mkv') {
        final body = 'not-a-real-video';
        response
          ..headers.contentType = ContentType('video', 'x-matroska')
          ..contentLength = utf8.encode(body).length
          ..write(body);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    pageServer.listen((request) async {
      final response = request.response;
      response.headers.removeAll('x-frame-options');
      if (request.uri.path == '/page.html') {
        final body =
            '''
<!doctype html>
<html><body>
<iframe src="$frameOrigin/frame.html" width="400" height="300"></iframe>
</body></html>
''';
        response
          ..headers.contentType = ContentType.html
          ..contentLength = utf8.encode(body).length
          ..write(body);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    pageUrl = '$pageOrigin/page.html';
    frameUrl = '$frameOrigin/frame.html';
  });

  tearDownAll(() async {
    await pageServer.close(force: true);
    await frameServer.close(force: true);
    await stopwebviewServer();
  });

  Future<Map<String, dynamic>> postCapture(
    WidgetTester tester, {
    String? url,
    required List<String> scripts,
    required Map<String, dynamic> capture,
    int time = 20,
  }) async {
    final result = await tester.runAsync(() async {
      final response = await http.post(
        Uri.parse(
          'http://127.0.0.1:$cfPort'
          '/evaluateJavascriptViaWebviewWithResourceCapture',
        ),
        headers: {HttpHeaders.contentTypeHeader: 'application/json'},
        body: jsonEncode({
          'url': url ?? pageUrl,
          'headers': <String, String>{},
          'scripts': scripts,
          'time': time,
          'capture': capture,
        }),
      );
      expect(response.statusCode, 200, reason: response.body);
      return jsonDecode(response.body) as Map<String, dynamic>;
    });
    return result!;
  }

  testWidgets('captures a media request from the top-level page', (
    tester,
  ) async {
    final result = await postCapture(
      tester,
      url: frameUrl,
      scripts: [
        '''
(async function(){
  await new Promise(r => setTimeout(r, 1500));
  window.flutter_inappwebview.callHandler('setResponse', 'done');
})();
''',
      ],
      capture: {'patterns': ['.mkv'], 'settleMs': 500, 'maxResults': 20},
    );

    expect(result['status'], 'ok', reason: result.toString());
    expect(
      frameRequests,
      contains('/probe.mkv'),
      reason: 'the top-level page did not request the probe: $frameRequests',
    );
    final resources = (result['resources'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      resources.map((resource) => resource['url'] as String),
      contains(frameUrl.replaceFirst('/frame.html', '/probe.mkv')),
      reason: result.toString(),
    );
  });

  testWidgets('captures a media request from a cross-origin iframe', (
    tester,
  ) async {
    final result = await postCapture(
      tester,
      scripts: [
        '''
(async function(){
  await new Promise(r => setTimeout(r, 2000));
  window.flutter_inappwebview.callHandler('setResponse', 'done');
})();
''',
      ],
      capture: {'patterns': [], 'settleMs': 1000, 'maxResults': 20},
    );

    expect(result['status'], 'ok', reason: result.toString());
    expect(
      frameRequests,
      contains('/probe.mkv'),
      reason: 'the iframe script did not request the probe: $frameRequests',
    );
    final resources = (result['resources'] as List)
        .cast<Map<String, dynamic>>();
    final urls = resources.map((resource) => resource['url'] as String);

    expect(
      urls.any((url) => url.endsWith('/probe.mkv')),
      isTrue,
      reason: '${result.toString()} frameRequests=$frameRequests',
    );
    expect(
      resources.any(
        (resource) => resource['source'] == 'shouldInterceptRequest',
      ),
      isTrue,
      reason: result.toString(),
    );
    expect(
      resources.any((resource) => (resource['url'] as String).contains('?')),
      isFalse,
      reason: 'the probe URL carries no query string',
    );
  });

  testWidgets('old evaluateJavascriptViaWebview still works', (tester) async {
    final body = await tester.runAsync(() async {
      final response = await http.post(
        Uri.parse('http://127.0.0.1:$cfPort/evaluateJavascriptViaWebview'),
        headers: {HttpHeaders.contentTypeHeader: 'application/json'},
        body: jsonEncode({
          'url': pageUrl,
          'headers': <String, String>{},
          'scripts': [
            "window.flutter_inappwebview.callHandler('setResponse', 'legacy-ok');",
          ],
          'time': 20,
        }),
      );
      expect(response.statusCode, 200, reason: response.body);
      return jsonDecode(response.body) as Map<String, dynamic>;
    });

    expect(body!['result'], 'legacy-ok');
  });
}
