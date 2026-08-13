import 'dart:io';

import 'fetcher.dart';
import 'import_analyzer.dart';

/// Resolves a component's transitive component dependencies, rewrites their
/// imports, and writes them into a consuming Flutter project.
class Installer {
  Installer({
    required this.fetcher,
    required this.targetDir,
    this.destination = 'lib/shadcn',
    ImportAnalyzer? analyzer,
  }) : analyzer = analyzer ?? ImportAnalyzer();

  final Fetcher fetcher;

  /// Root of the consuming Flutter project.
  final Directory targetDir;

  /// Where component source lands, relative to [targetDir].
  final String destination;

  final ImportAnalyzer analyzer;

  static const _componentRoot = 'lib/src/components';

  /// Walks the component dependency graph breadth-first from [entry].
  ///
  /// [entry] is a sub-path under `src/components/`, e.g. `button.dart`. Returns
  /// resolved sources keyed by that sub-path. A visited set makes the walk safe
  /// against both diamonds and genuine cycles.
  Future<ResolveResult> resolve(String entry) async {
    final sources = <String, String>{};
    final missing = <String>[];
    final edges = <String, Set<String>>{};

    final queue = <String>[entry];
    final seen = <String>{entry};

    while (queue.isNotEmpty) {
      final subPath = queue.removeAt(0);
      final source = await fetcher.fetch('$_componentRoot/$subPath');

      if (source == null) {
        missing.add(subPath);
        continue;
      }
      sources[subPath] = source;

      final deps = analyzer.componentDeps(source);
      edges[subPath] = deps;

      for (final dep in deps) {
        if (seen.add(dep)) queue.add(dep);
      }
    }

    return ResolveResult(sources: sources, missing: missing, edges: edges);
  }

  /// Rewrites and writes every resolved file. Returns one record per file.
  ///
  /// When [dryRun] is true nothing touches disk, but every rewrite is still
  /// computed so the report is identical to a real run.
  Future<List<InstalledFile>> install(
    ResolveResult resolved, {
    bool dryRun = false,
    bool overwrite = false,
  }) async {
    final results = <InstalledFile>[];

    // Sort for deterministic output — important for a tool whose diff a
    // maintainer will read.
    final subPaths = resolved.sources.keys.toList()..sort();

    for (final subPath in subPaths) {
      final rewrite = analyzer.rewrite(resolved.sources[subPath]!, subPath);
      final file = File(_absolutePathFor(subPath));

      final existed = file.existsSync();
      var wrote = false;

      if (!dryRun && (!existed || overwrite)) {
        await file.parent.create(recursive: true);
        await file.writeAsString(rewrite.source);
        wrote = true;
      }

      results.add(InstalledFile(
        subPath: subPath,
        path: file.path,
        rewrittenImports: rewrite.rewritten,
        keptImports: rewrite.kept,
        alreadyExisted: existed,
        wrote: wrote,
      ));
    }

    return results;
  }

  String _absolutePathFor(String subPath) =>
      '${targetDir.path}${Platform.pathSeparator}'
      '${destination.replaceAll('/', Platform.pathSeparator)}'
      '${Platform.pathSeparator}'
      '${subPath.replaceAll('/', Platform.pathSeparator)}';

  /// Every distinct non-component import across all resolved files, mapped to
  /// the reason it was kept. This is what the consuming project still needs the
  /// `shadcn_ui` package for.
  static Map<String, String> keptPackageImports(List<InstalledFile> files) {
    final out = <String, String>{};
    for (final file in files) {
      for (final directive in file.keptImports) {
        out[directive.libPath] = directive.keepReason ?? 'package internal';
      }
    }
    return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }
}

class ResolveResult {
  ResolveResult({
    required this.sources,
    required this.missing,
    required this.edges,
  });

  /// Component sub-path -> raw source.
  final Map<String, String> sources;

  /// Sub-paths that 404'd. Non-empty means the component name was wrong or the
  /// upstream layout changed.
  final List<String> missing;

  /// Component sub-path -> the component sub-paths it imports.
  final Map<String, Set<String>> edges;
}

class InstalledFile {
  InstalledFile({
    required this.subPath,
    required this.path,
    required this.rewrittenImports,
    required this.keptImports,
    required this.alreadyExisted,
    required this.wrote,
  });

  final String subPath;
  final String path;
  final List<String> rewrittenImports;
  final List<ShadcnDirective> keptImports;
  final bool alreadyExisted;
  final bool wrote;
}
