import 'package:shadcn_add/src/import_analyzer.dart';
import 'package:test/test.dart';

void main() {
  final analyzer = ImportAnalyzer();

  group('directives', () {
    test('finds every package:shadcn_ui import and ignores framework imports', () {
      const source = '''
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/src/components/button.dart';
import 'package:shadcn_ui/src/theme/theme.dart';
import 'package:some_other_pkg/thing.dart';
''';
      final found = analyzer.directives(source);
      expect(found, hasLength(2));
      expect(found.map((d) => d.libPath), [
        'src/components/button.dart',
        'src/theme/theme.dart',
      ]);
    });

    test('handles export directives', () {
      const source = "export 'package:shadcn_ui/src/components/card.dart';";
      final found = analyzer.directives(source);
      expect(found.single.keyword, 'export');
      expect(found.single.libPath, 'src/components/card.dart');
    });

    test('preserves show/hide clauses as trailing text', () {
      const source =
          "import 'package:shadcn_ui/src/components/button.dart' show ShadButton;";
      expect(analyzer.directives(source).single.trailing, ' show ShadButton;');
    });

    test('handles double-quoted URIs', () {
      const source = 'import "package:shadcn_ui/src/components/button.dart";';
      expect(analyzer.directives(source).single.libPath,
          'src/components/button.dart');
    });

    test('does NOT match a commented-out import', () {
      const source =
          "// import 'package:shadcn_ui/src/components/button.dart';";
      expect(analyzer.directives(source), isEmpty);
    });

    test('matches indented directives and preserves the indent', () {
      const source =
          "  import 'package:shadcn_ui/src/components/button.dart';";
      expect(analyzer.directives(source).single.indent, '  ');
    });
  });

  group('classification', () {
    test('components are copyable, everything else is not', () {
      const source = '''
import 'package:shadcn_ui/src/components/button.dart';
import 'package:shadcn_ui/src/components/form/fields/input.dart';
import 'package:shadcn_ui/src/theme/data.dart';
import 'package:shadcn_ui/src/utils/debug_check.dart';
import 'package:shadcn_ui/src/raw_components/portal.dart';
import 'package:shadcn_ui/src/i18n/strings.g.dart';
''';
      final found = analyzer.directives(source);
      expect(found.map((d) => d.isComponent),
          [true, true, false, false, false, false]);
    });

    test('keepReason explains each non-component category', () {
      const source = '''
import 'package:shadcn_ui/src/theme/data.dart';
import 'package:shadcn_ui/src/utils/debug_check.dart';
import 'package:shadcn_ui/src/raw_components/portal.dart';
import 'package:shadcn_ui/src/i18n/strings.g.dart';
''';
      final reasons = analyzer.directives(source).map((d) => d.keepReason);
      expect(reasons, [
        'theme runtime (provided by ShadApp)',
        'shared utility',
        'primitive',
        'localization',
      ]);
    });

    test('a component directive has no keepReason', () {
      const source = "import 'package:shadcn_ui/src/components/button.dart';";
      expect(analyzer.directives(source).single.keepReason, isNull);
    });

    test('componentDeps returns only component sub-paths, deduped', () {
      const source = '''
import 'package:shadcn_ui/src/components/button.dart';
import 'package:shadcn_ui/src/components/button.dart';
import 'package:shadcn_ui/src/theme/data.dart';
''';
      expect(analyzer.componentDeps(source), {'button.dart'});
    });
  });

  group('rewrite — flat components (the real upstream layout)', () {
    test('rewrites a sibling component to an explicit ./ path', () {
      const source = "import 'package:shadcn_ui/src/components/button.dart';";
      final result = analyzer.rewrite(source, 'calendar.dart');

      expect(result.source, "import './button.dart';");
      expect(result.rewritten,
          ['src/components/button.dart -> ./button.dart']);
      expect(result.kept, isEmpty);
    });

    test('leaves infrastructure imports byte-identical', () {
      const source = '''
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/src/theme/theme.dart';
import 'package:shadcn_ui/src/utils/border.dart';
''';
      final result = analyzer.rewrite(source, 'popover.dart');

      expect(result.source, source);
      expect(result.rewritten, isEmpty);
      expect(result.kept, hasLength(2));
    });

    test('preserves a show clause while rewriting the URI', () {
      const source =
          "import 'package:shadcn_ui/src/components/button.dart' show ShadButton;";
      final result = analyzer.rewrite(source, 'calendar.dart');
      expect(result.source, "import './button.dart' show ShadButton;");
    });

    test('preserves indentation and the original quote style', () {
      const source =
          '  import "package:shadcn_ui/src/components/button.dart";';
      final result = analyzer.rewrite(source, 'calendar.dart');
      expect(result.source, '  import "./button.dart";');
    });

    test('rewrites multiple component imports in one file', () {
      const source = '''
import 'package:shadcn_ui/src/components/button.dart';
import 'package:shadcn_ui/src/components/popover.dart';
import 'package:shadcn_ui/src/theme/theme.dart';
''';
      final result = analyzer.rewrite(source, 'date_picker.dart');
      expect(result.rewritten, hasLength(2));
      expect(result.kept, hasLength(1));
      expect(result.source, contains("import './button.dart';"));
      expect(result.source, contains("import './popover.dart';"));
      expect(result.source,
          contains("import 'package:shadcn_ui/src/theme/theme.dart';"));
    });
  });

  // These exercise the multi-level branch of the relative-path logic, which the
  // flat upstream layout never reaches. `components/form/` exists upstream, so
  // this is a real code path, not a hypothetical.
  group('rewrite — nested components', () {
    test('nested file importing a root sibling walks up', () {
      const source = "import 'package:shadcn_ui/src/components/button.dart';";
      final result = analyzer.rewrite(source, 'form/field.dart');
      expect(result.source, "import '../button.dart';");
    });

    test('two levels deep walks up twice', () {
      const source = "import 'package:shadcn_ui/src/components/button.dart';";
      final result = analyzer.rewrite(source, 'form/fields/input.dart');
      expect(result.source, "import '../../button.dart';");
    });

    test('root file importing a nested component descends', () {
      const source =
          "import 'package:shadcn_ui/src/components/form/field.dart';";
      final result = analyzer.rewrite(source, 'button.dart');
      expect(result.source, "import './form/field.dart';");
    });

    test('siblings inside the same nested directory use ./', () {
      const source =
          "import 'package:shadcn_ui/src/components/form/field.dart';";
      final result = analyzer.rewrite(source, 'form/other.dart');
      expect(result.source, "import './field.dart';");
    });

    test('cousins in sibling directories walk up then down', () {
      const source =
          "import 'package:shadcn_ui/src/components/form/fields/input.dart';";
      final result = analyzer.rewrite(source, 'overlay/sheet.dart');
      expect(result.source, "import '../form/fields/input.dart';");
    });

    test('deep-to-deep across a shared prefix only walks the difference', () {
      const source =
          "import 'package:shadcn_ui/src/components/form/fields/input.dart';";
      final result = analyzer.rewrite(source, 'form/layout/row.dart');
      expect(result.source, "import '../fields/input.dart';");
    });
  });
}
