import 'dart:io';

import 'package:shadcn_add/src/fetcher.dart';
import 'package:shadcn_add/src/installer.dart';
import 'package:test/test.dart';

/// A Fetcher that serves canned sources instead of hitting the network, so the
/// resolver's graph walking is tested deterministically and offline.
class FakeFetcher extends Fetcher {
  FakeFetcher(this.files) : super();

  /// Keyed by full repo path, e.g. `lib/src/components/button.dart`.
  final Map<String, String> files;
  final List<String> requested = [];

  @override
  Future<String?> fetch(String repoPath) async {
    requested.add(repoPath);
    return files[repoPath];
  }

  @override
  void close() {}
}

String comp(List<String> componentImports, {List<String> infra = const []}) {
  final lines = [
    "import 'package:flutter/widgets.dart';",
    ...componentImports
        .map((c) => "import 'package:shadcn_ui/src/components/$c';"),
    ...infra.map((i) => "import 'package:shadcn_ui/src/$i';"),
  ];
  return '${lines.join('\n')}\n\nclass Thing {}\n';
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('shadcn_add_test');
    File('${temp.path}${Platform.pathSeparator}pubspec.yaml')
        .writeAsStringSync('name: fake_app\n');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Installer installerFor(FakeFetcher fetcher) =>
      Installer(fetcher: fetcher, targetDir: temp);

  group('resolve', () {
    test('a leaf component resolves to itself only', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/button.dart': comp([], infra: ['theme/theme.dart']),
      });
      final result = await installerFor(fetcher).resolve('button.dart');

      expect(result.sources.keys, ['button.dart']);
      expect(result.missing, isEmpty);
      expect(result.edges['button.dart'], isEmpty);
    });

    test('walks a transitive chain', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/a.dart': comp(['b.dart']),
        'lib/src/components/b.dart': comp(['c.dart']),
        'lib/src/components/c.dart': comp([]),
      });
      final result = await installerFor(fetcher).resolve('a.dart');

      expect(result.sources.keys.toSet(), {'a.dart', 'b.dart', 'c.dart'});
      expect(result.edges['a.dart'], {'b.dart'});
      expect(result.edges['b.dart'], {'c.dart'});
    });

    test('a diamond fetches the shared dependency exactly once', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/top.dart': comp(['left.dart', 'right.dart']),
        'lib/src/components/left.dart': comp(['shared.dart']),
        'lib/src/components/right.dart': comp(['shared.dart']),
        'lib/src/components/shared.dart': comp([]),
      });
      final result = await installerFor(fetcher).resolve('top.dart');

      expect(result.sources.keys.toSet(),
          {'top.dart', 'left.dart', 'right.dart', 'shared.dart'});
      expect(
        fetcher.requested
            .where((p) => p.endsWith('shared.dart'))
            .length,
        1,
        reason: 'visited set must prevent refetching a diamond',
      );
    });

    test('terminates on a genuine cycle', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/x.dart': comp(['y.dart']),
        'lib/src/components/y.dart': comp(['x.dart']),
      });
      final result = await installerFor(fetcher).resolve('x.dart');

      expect(result.sources.keys.toSet(), {'x.dart', 'y.dart'});
      expect(result.edges['x.dart'], {'y.dart'});
      expect(result.edges['y.dart'], {'x.dart'});
    });

    test('a self-import does not loop', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/solo.dart': comp(['solo.dart']),
      });
      final result = await installerFor(fetcher).resolve('solo.dart');
      expect(result.sources.keys, ['solo.dart']);
    });

    test('a missing dependency is recorded, not thrown', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/a.dart': comp(['ghost.dart']),
      });
      final result = await installerFor(fetcher).resolve('a.dart');

      expect(result.sources.keys, ['a.dart']);
      expect(result.missing, ['ghost.dart']);
    });

    test('an unknown entry component yields no sources', () async {
      final fetcher = FakeFetcher({});
      final result = await installerFor(fetcher).resolve('nope.dart');

      expect(result.sources, isEmpty);
      expect(result.missing, ['nope.dart']);
    });
  });

  group('install', () {
    test('writes every resolved file with imports rewritten', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/parent.dart':
            comp(['child.dart'], infra: ['theme/theme.dart']),
        'lib/src/components/child.dart': comp([]),
      });
      final installer = installerFor(fetcher);
      final files = await installer.install(await installer.resolve('parent.dart'));

      expect(files, hasLength(2));
      expect(files.every((f) => f.wrote), isTrue);

      final parent = File(
        '${temp.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
        'shadcn${Platform.pathSeparator}parent.dart',
      );
      expect(parent.existsSync(), isTrue);

      final text = parent.readAsStringSync();
      expect(text, contains("import './child.dart';"));
      expect(text, isNot(contains('package:shadcn_ui/src/components/')));
      // Infrastructure must survive untouched.
      expect(text, contains("import 'package:shadcn_ui/src/theme/theme.dart';"));
    });

    test('dry run writes nothing but still reports rewrites', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/parent.dart': comp(['child.dart']),
        'lib/src/components/child.dart': comp([]),
      });
      final installer = installerFor(fetcher);
      final files = await installer.install(
        await installer.resolve('parent.dart'),
        dryRun: true,
      );

      expect(files.every((f) => !f.wrote), isTrue);
      expect(
        files.firstWhere((f) => f.subPath == 'parent.dart').rewrittenImports,
        isNotEmpty,
      );
      expect(
        Directory('${temp.path}${Platform.pathSeparator}lib').existsSync(),
        isFalse,
      );
    });

    test('existing files are skipped unless overwrite is set', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/button.dart': comp([]),
      });
      final installer = installerFor(fetcher);
      final resolved = await installer.resolve('button.dart');

      final target = File(
        '${temp.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
        'shadcn${Platform.pathSeparator}button.dart',
      );
      target.parent.createSync(recursive: true);
      target.writeAsStringSync('// my edits');

      final skipped = await installer.install(resolved);
      expect(skipped.single.wrote, isFalse);
      expect(skipped.single.alreadyExisted, isTrue);
      expect(target.readAsStringSync(), '// my edits',
          reason: 'user edits must not be clobbered by default');

      final forced = await installer.install(resolved, overwrite: true);
      expect(forced.single.wrote, isTrue);
      expect(target.readAsStringSync(), isNot('// my edits'));
    });

    test('nested component paths are written into subdirectories', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/form/field.dart': comp([]),
      });
      final installer = installerFor(fetcher);
      await installer.install(await installer.resolve('form/field.dart'));

      expect(
        File('${temp.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
                'shadcn${Platform.pathSeparator}form${Platform.pathSeparator}'
                'field.dart')
            .existsSync(),
        isTrue,
      );
    });

    test('output is sorted for a deterministic diff', () async {
      final fetcher = FakeFetcher({
        'lib/src/components/zebra.dart': comp(['alpha.dart', 'middle.dart']),
        'lib/src/components/alpha.dart': comp([]),
        'lib/src/components/middle.dart': comp([]),
      });
      final installer = installerFor(fetcher);
      final files =
          await installer.install(await installer.resolve('zebra.dart'));

      expect(files.map((f) => f.subPath),
          ['alpha.dart', 'middle.dart', 'zebra.dart']);
    });
  });

  group('keptPackageImports', () {
    test('aggregates and dedupes infrastructure imports with reasons',
        () async {
      final fetcher = FakeFetcher({
        'lib/src/components/a.dart':
            comp(['b.dart'], infra: ['theme/theme.dart', 'utils/border.dart']),
        'lib/src/components/b.dart':
            comp([], infra: ['theme/theme.dart', 'raw_components/portal.dart']),
      });
      final installer = installerFor(fetcher);
      final files = await installer.install(
        await installer.resolve('a.dart'),
        dryRun: true,
      );

      final kept = Installer.keptPackageImports(files);
      expect(kept, {
        'src/raw_components/portal.dart': 'primitive',
        'src/theme/theme.dart': 'theme runtime (provided by ShadApp)',
        'src/utils/border.dart': 'shared utility',
      });
    });
  });
}
