import 'dart:io';

import 'package:shadcn_add/src/fetcher.dart';
import 'package:shadcn_add/src/installer.dart';
import 'package:shadcn_add/src/path_fetcher.dart';

/// Spike CLI for flutter-shadcn-ui issue #286.
///
///   dart run bin/shadcn_add.dart <component> [--target <dir>] [--dry-run]
///                                            [--overwrite] [--ref <git-ref>]
///
/// Deliberately hand-rolled arg parsing so the package has zero dependencies
/// and `dart pub get` cannot fail.
Future<int> main(List<String> argv) async {
  final args = _Args.parse(argv);

  if (args.showHelp || args.component == null) {
    stdout.writeln(_usage);
    return args.component == null && !args.showHelp ? 64 : 0;
  }

  final targetDir = Directory(args.target);
  if (!targetDir.existsSync()) {
    stderr.writeln('error: target directory does not exist: ${targetDir.path}');
    return 66;
  }
  final pubspec = File('${targetDir.path}${Platform.pathSeparator}pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln(
      'error: no pubspec.yaml in ${targetDir.path} '
      '(is this a Flutter project?)',
    );
    return 66;
  }

  // Accept both `button` and `button.dart`, plus nested `form/fields/x`.
  final entry = args.component!.endsWith('.dart')
      ? args.component!
      : '${args.component!}.dart';

  final fetcher = args.fromPath != null
      ? PathFetcher(args.fromPath!)
      : Fetcher(ref: args.ref);
  final installer = Installer(fetcher: fetcher, targetDir: targetDir);

  try {
    stdout.writeln('Resolving "$entry" from ${fetcher.owner}/${fetcher.repo}'
        '@${fetcher.ref} ...');

    final resolved = await installer.resolve(entry);

    if (resolved.sources.isEmpty) {
      stderr.writeln('error: component not found: $entry');
      stderr.writeln('  looked for lib/src/components/$entry');
      return 69;
    }
    if (resolved.missing.isNotEmpty) {
      stderr.writeln('warning: could not fetch: ${resolved.missing.join(', ')}');
    }

    final files = await installer.install(
      resolved,
      dryRun: args.dryRun,
      overwrite: args.overwrite,
    );

    _report(files, resolved, installer, dryRun: args.dryRun);
    return 0;
  } on FetchException catch (e) {
    stderr.writeln('error: ${e.message}');
    return 70;
  } finally {
    fetcher.close();
  }
}

void _report(
  List<InstalledFile> files,
  ResolveResult resolved,
  Installer installer, {
  required bool dryRun,
}) {
  final entry = files.length == 1 ? 'component' : 'components';
  stdout.writeln('\nResolved ${files.length} $entry:');

  for (final file in files) {
    final status = dryRun
        ? '[dry-run]'
        : file.wrote
            ? '[written]'
            : '[skipped, exists]';
    stdout.writeln('  $status ${installer.destination}/${file.subPath}');

    for (final rewrite in file.rewrittenImports) {
      stdout.writeln('      rewrote  $rewrite');
    }
  }

  final deps = resolved.edges.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => '  ${e.key} -> ${(e.value.toList()..sort()).join(', ')}')
      .toList()
    ..sort();
  if (deps.isNotEmpty) {
    stdout.writeln('\nComponent dependency graph:');
    deps.forEach(stdout.writeln);
  }

  final kept = Installer.keptPackageImports(files);
  if (kept.isNotEmpty) {
    stdout.writeln(
      '\nStill imported from package:shadcn_ui (${kept.length} files) — '
      'keep the dependency:',
    );
    for (final entry in kept.entries) {
      stdout.writeln('  ${entry.key}  (${entry.value})');
    }
    stdout.writeln(
      '\nThis is the same shape as shadcn/ui in React: the component source is '
      'yours,\nbut the runtime (theme, utils, primitives) stays a dependency.',
    );
  }

  final skipped = files.where((f) => f.alreadyExisted && !f.wrote).length;
  if (skipped > 0 && !dryRun) {
    stdout.writeln(
      '\n$skipped file(s) already existed and were left untouched. '
      'Use --overwrite to replace them.',
    );
  }
}

class _Args {
  _Args({
    required this.component,
    required this.target,
    required this.dryRun,
    required this.overwrite,
    required this.ref,
    required this.fromPath,
    required this.showHelp,
  });

  final String? component;
  final String target;
  final bool dryRun;
  final bool overwrite;
  final String ref;
  final String? fromPath;
  final bool showHelp;

  static _Args parse(List<String> argv) {
    String? component;
    var target = Directory.current.path;
    var dryRun = false;
    var overwrite = false;
    var ref = 'main';
    String? fromPath;
    var showHelp = false;

    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      switch (arg) {
        case '--dry-run':
          dryRun = true;
        case '--overwrite':
          overwrite = true;
        case '-h':
        case '--help':
          showHelp = true;
        case '--target':
          if (i + 1 < argv.length) target = argv[++i];
        case '--ref':
          if (i + 1 < argv.length) ref = argv[++i];
        case '--from-path':
          if (i + 1 < argv.length) fromPath = argv[++i];
        default:
          if (arg.startsWith('--target=')) {
            target = arg.substring('--target='.length);
          } else if (arg.startsWith('--ref=')) {
            ref = arg.substring('--ref='.length);
          } else if (arg.startsWith('--from-path=')) {
            fromPath = arg.substring('--from-path='.length);
          } else if (!arg.startsWith('-')) {
            component ??= arg;
          }
      }
    }

    return _Args(
      component: component,
      target: target,
      dryRun: dryRun,
      overwrite: overwrite,
      ref: ref,
      fromPath: fromPath,
      showHelp: showHelp,
    );
  }
}

const _usage = '''
shadcn_add — copy shadcn_ui component source into your project.

Spike for https://github.com/nank1ro/flutter-shadcn-ui/issues/286

Usage:
  dart run bin/shadcn_add.dart <component> [options]

Options:
  --target <dir>   Flutter project to install into (default: current directory)
  --dry-run        Report what would happen without writing files
  --overwrite      Replace files that already exist
  --ref <ref>      Git ref to pull from (default: main)
  --from-path <p>  Copy from a local shadcn_ui checkout instead of GitHub.
                   Preferred for real use: source then matches the package
                   version the project actually depends on.
  -h, --help       Show this help

Examples:
  dart run bin/shadcn_add.dart button --target ../my_app
  dart run bin/shadcn_add.dart date_picker --target ../my_app --dry-run
''';
