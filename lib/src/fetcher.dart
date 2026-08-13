import 'dart:convert';
import 'dart:io';

/// Fetches raw file content from the flutter-shadcn-ui repository.
///
/// Uses raw.githubusercontent.com, which needs no authentication and no API
/// token, so the CLI works out of the box for any user.
class Fetcher {
  Fetcher({
    String owner = 'nank1ro',
    String repo = 'flutter-shadcn-ui',
    String ref = 'main',
    HttpClient? client,
  })  : _owner = owner,
        _repo = repo,
        _ref = ref,
        _client = client ?? HttpClient();

  final String _owner;
  final String _repo;
  final String _ref;
  final HttpClient _client;

  // Overridable so alternative sources (e.g. a local package checkout) can
  // report their own provenance in the CLI's output.
  String get owner => _owner;
  String get repo => _repo;
  String get ref => _ref;

  /// In-memory cache so a diamond in the dependency graph (e.g. both `calendar`
  /// and `date_picker` importing `button`) only costs one request.
  final Map<String, String?> _cache = {};

  Uri rawUri(String repoPath) => Uri.https(
        'raw.githubusercontent.com',
        '/$owner/$repo/$ref/$repoPath',
      );

  /// Returns the file's contents, or null if the file does not exist (404).
  ///
  /// Throws [FetchException] on any other failure so a network problem is never
  /// silently reported as "component not found".
  Future<String?> fetch(String repoPath) async {
    if (_cache.containsKey(repoPath)) return _cache[repoPath];

    final uri = rawUri(repoPath);
    try {
      final request = await _client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode == 404) {
        await response.drain<void>();
        return _cache[repoPath] = null;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw FetchException(
          'Unexpected HTTP ${response.statusCode} fetching $uri',
        );
      }
      return _cache[repoPath] = await response.transform(utf8.decoder).join();
    } on SocketException catch (e) {
      throw FetchException('Network error fetching $uri: ${e.message}');
    }
  }

  void close() => _client.close(force: true);
}

class FetchException implements Exception {
  FetchException(this.message);
  final String message;
  @override
  String toString() => 'FetchException: $message';
}
