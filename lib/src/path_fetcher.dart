import 'dart:io';

import 'fetcher.dart';

/// Reads component source from a local checkout or pub-cache copy of the
/// `shadcn_ui` package instead of GitHub.
///
/// This is the correct default for a real implementation: copied source should
/// match the package version the project actually depends on, not whatever is
/// currently on `main`. Pulling from a git ref can hand the user source that is
/// newer than their installed package, producing code that references
/// infrastructure their version does not have.
class PathFetcher extends Fetcher {
  PathFetcher(this.packageRoot) : super();

  /// Root of the shadcn_ui package (the directory containing its `lib/`).
  final String packageRoot;

  final Map<String, String?> _cache = {};

  @override
  Future<String?> fetch(String repoPath) async {
    if (_cache.containsKey(repoPath)) return _cache[repoPath];

    final file = File(
      '$packageRoot${Platform.pathSeparator}'
      '${repoPath.replaceAll('/', Platform.pathSeparator)}',
    );
    if (!file.existsSync()) return _cache[repoPath] = null;
    return _cache[repoPath] = await file.readAsString();
  }

  @override
  void close() {}

  @override
  String get owner => 'local';

  @override
  String get repo => packageRoot;

  @override
  String get ref => 'path';
}
