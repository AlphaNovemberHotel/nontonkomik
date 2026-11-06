/// Filtering, de-duplication and redaction for
/// `evaluateJavascriptViaWebviewWithResourceCapture`.
///
/// Kept free of Flutter imports so the policy can be tested without a
/// WebView: the platform layer only feeds URLs and metadata in.
class WebviewResourceCaptureConfig {
  /// Media-shaped URLs common to media mirrors. An extension can pass its own
  /// `patterns`; an explicit empty list captures every http(s) resource.
  static const List<String> defaultPatterns = [
    '.mkv',
    '.mp4',
    '.m3u8',
    '.mpd',
    'googlevideo.com',
    'r2.cloudflarestorage.com',
  ];

  final List<String> patterns;
  final int maxResults;

  /// How long to keep listening after the page scripts report completion.
  final int settleMs;

  /// Return as soon as the first matching resource is seen.
  final bool stopOnFirstMatch;

  const WebviewResourceCaptureConfig({
    this.patterns = defaultPatterns,
    this.maxResults = 50,
    this.settleMs = 1500,
    this.stopOnFirstMatch = false,
  });

  factory WebviewResourceCaptureConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const WebviewResourceCaptureConfig();

    final rawPatterns = json['patterns'];
    final patterns = rawPatterns is List
        ? rawPatterns
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .toList(growable: false)
        : defaultPatterns;

    return WebviewResourceCaptureConfig(
      patterns: patterns,
      maxResults: _clamp(json['maxResults'], fallback: 50, min: 1, max: 200),
      settleMs: _clamp(json['settleMs'], fallback: 1500, min: 0, max: 15000),
      stopOnFirstMatch: json['stopOnFirstMatch'] == true,
    );
  }

  /// The URL to report for [rawUrl], or null when it is not an http(s)
  /// resource this capture accepts.
  String? accept(String? rawUrl) {
    final uri = Uri.tryParse(rawUrl ?? '');
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final url = uri.toString();
    if (patterns.isEmpty) return url;

    final lower = url.toLowerCase();
    return patterns.any((p) => lower.contains(p.toLowerCase())) ? url : null;
  }

  static int _clamp(
    Object? value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final number = value is num ? value.toInt() : fallback;
    if (number < min) return min;
    if (number > max) return max;
    return number;
  }
}

/// Collects captured resources in arrival order, de-duplicated by URL and
/// bounded by [WebviewResourceCaptureConfig.maxResults].
class WebviewResourceCapture {
  WebviewResourceCapture(this.config);

  final WebviewResourceCaptureConfig config;
  final List<Map<String, dynamic>> resources = [];
  final Set<String> _seen = {};

  bool truncated = false;

  /// Adds one observation. Returns true when it was newly accepted, so the
  /// caller can reset its settle timer.
  bool add({
    String? url,
    required String source,
    String? initiatorType,
    bool? isForMainFrame,
    double? startTime,
    double? duration,
  }) {
    final accepted = config.accept(url);
    if (accepted == null || !_seen.add(accepted)) return false;

    if (resources.length >= config.maxResults) {
      truncated = true;
      return false;
    }

    final effectiveInitiator = initiatorType?.isEmpty ?? true
        ? null
        : initiatorType;
    resources.add({
      'url': accepted,
      'source': source,
      'initiatorType': ?effectiveInitiator,
      'isForMainFrame': ?isForMainFrame,
      'startTime': ?startTime,
      'duration': ?duration,
    });
    return true;
  }
}

/// Origin only: signed URLs carry their token in the query string and
/// sometimes in the path, and this value is only ever written to logs.
String redactUrlForLog(String? rawUrl) {
  final uri = Uri.tryParse(rawUrl ?? '');
  if (uri == null || uri.host.isEmpty) return '<invalid-url>';
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port';
}
