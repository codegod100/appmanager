/// Downloads and hashing, all asynchronous so the window never freezes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'env.dart';
import 'store.dart';

typedef Progress = void Function(int received, int total);

class DownloadError implements Exception {
  final String message;
  DownloadError(this.message);
  @override
  String toString() => message;
}

final _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 20)
  ..userAgent = 'appmanager'
  // Honour http_proxy/https_proxy/no_proxy like curl does.
  ..findProxy = HttpClient.findProxyFromEnvironment;

final _active = <HttpClientRequest>{};

/// Aborts every download still running, so quitting doesn't leave any
/// behind.
void stopDownloads() {
  for (final r in List.of(_active)) {
    r.abort();
  }
  _active.clear();
}

bool _isGitHubApi(String url) => url.startsWith('$gitHubApi/');

/// Downloads `url` to `dest`. `range` is an HTTP byte range such as
/// "0-16383". Throws `DownloadError`. `onProgress` gets the bytes received
/// so far and the expected total (0 when unknown).
Future<void> download(String url, String dest,
    {String range = '', int expected = 0, Progress? onProgress}) async {
  if (!(url.startsWith('https://') || url.startsWith('http://'))) {
    throw DownloadError('not a web address: $url');
  }
  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await _downloadOnce(url, dest, range, expected, onProgress);
      return;
    } on DownloadError catch (e) {
      removeFile(dest);
      // Client errors won't go away by asking again.
      if (e.message.startsWith('HTTP 4')) throw _explain(url, e);
      lastError = e;
    } on Exception catch (e) {
      removeFile(dest);
      lastError = e;
    }
  }
  throw _explain(url, DownloadError('$lastError'));
}

DownloadError _explain(String url, DownloadError e) {
  if (_isGitHubApi(url) && (e.message.contains('403') || e.message.contains('429'))) {
    return DownloadError('${e.message} (GitHub rate limit? Set GITHUB_TOKEN to raise it)');
  }
  return e;
}

Future<void> _downloadOnce(
    String url, String dest, String range, int expected, Progress? onProgress) async {
  final request = await _client.getUrl(Uri.parse(url));
  _active.add(request);
  try {
    if (range.isNotEmpty) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$range');
    if (_isGitHubApi(url)) {
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final token = env('GITHUB_TOKEN').trim();
      if (token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
    }
    final response = await request.close();
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw DownloadError('HTTP ${response.statusCode} ${response.reasonPhrase} for $url');
    }
    final total = expected > 0 ? expected : (response.contentLength > 0 ? response.contentLength : 0);
    final sink = File(dest).openWrite();
    var received = 0;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (onProgress != null && now.difference(lastReport).inMilliseconds >= 100) {
          lastReport = now;
          onProgress(received, total);
        }
      }
    } finally {
      await sink.close();
    }
    onProgress?.call(received, total);
  } finally {
    _active.remove(request);
  }
}

int _tempCounter = 0;

String tempFile(String ext) =>
    '${Directory.systemTemp.path}/appmanager-$pid-${++_tempCounter}$ext';

Future<String> fetchText(String url, {String range = ''}) async {
  final dest = tempFile('.txt');
  try {
    await download(url, dest, range: range);
    return utf8.decode(await File(dest).readAsBytes(), allowMalformed: true);
  } finally {
    removeFile(dest);
  }
}

Future<Object?> fetchJson(String url) async {
  final text = await fetchText(url);
  try {
    return jsonDecode(text);
  } on FormatException {
    throw DownloadError('Unexpected reply from $url');
  }
}

/// The lower-case hex SHA-1 of the file at `path`.
Future<String> sha1File(String path) async {
  try {
    final digest = await sha1.bind(File(path).openRead()).first;
    return digest.toString();
  } on FileSystemException catch (e) {
    throw DownloadError('Could not hash ${path.split('/').last}: ${e.message}');
  }
}
