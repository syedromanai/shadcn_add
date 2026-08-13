/// Classifies and rewrites `package:shadcn_ui/...` directives.
///
/// The central design decision of this spike:
///
///   * `lib/src/components/**` is COMPONENT source. The user should own it, so
///     it gets copied into their project and its imports rewritten to local
///     relative paths.
///   * `lib/src/theme/**`, `lib/src/utils/**`, `lib/src/raw_components/**` and
///     `lib/src/i18n/**` are SHARED INFRASTRUCTURE. They stay as ordinary
///     `package:shadcn_ui/...` imports.
///
/// This mirrors how shadcn/ui actually behaves in React: `shadcn add button`
/// copies `button.tsx` into your repo, but your project still depends on
/// `@radix-ui/*`, `class-variance-authority`, `clsx` and `tailwind-merge` from
/// npm. shadcn/ui was never dependency-free — it gives you ownership of the
/// component's own source, not of the whole design-system runtime.
library;

/// A single `package:shadcn_ui/...` directive found in a source file.
class ShadcnDirective {
  ShadcnDirective({
    required this.fullLine,
    required this.keyword,
    required this.libPath,
    required this.trailing,
    required this.indent,
    required this.quote,
  });

  /// The entire matched line, verbatim.
  final String fullLine;

  /// Either `import` or `export`.
  final String keyword;

  /// Path relative to the package's `lib/`, e.g. `src/components/button.dart`.
  final String libPath;

  /// Anything after the closing quote, e.g. ` show ShadButton;`.
  final String trailing;

  final String indent;
  final String quote;

  /// True when this points at component source the user should own.
  bool get isComponent => libPath.startsWith('src/components/');

  /// Path relative to `src/components/`, e.g. `button.dart` or
  /// `form/fields/input.dart`. Only meaningful when [isComponent] is true.
  String get componentSubPath =>
      isComponent ? libPath.substring('src/components/'.length) : libPath;

  /// Why this directive was left as a package import. Null when it was rewritten.
  String? get keepReason {
    if (isComponent) return null;
    if (libPath.startsWith('src/theme/')) {
      return 'theme runtime (provided by ShadApp)';
    }
    if (libPath.startsWith('src/utils/')) return 'shared utility';
    if (libPath.startsWith('src/raw_components/')) return 'primitive';
    if (libPath.startsWith('src/i18n/')) return 'localization';
    return 'package internal';
  }
}

class ImportAnalyzer {
  /// Matches `import`/`export` directives pointing into `package:shadcn_ui/`.
  ///
  /// Deliberately not a full Dart parser — directives are the first thing in a
  /// Dart file and this shape is stable. A real implementation would use
  /// `package:analyzer`, which is a point worth raising on the PR.
  static final RegExp _directive = RegExp(
    r'''^([ \t]*)(import|export)[ \t]+(['"])package:shadcn_ui/([^'"]+)\3(.*)$''',
    multiLine: true,
  );

  /// Every `package:shadcn_ui/...` directive in [source], in file order.
  List<ShadcnDirective> directives(String source) {
    return _directive.allMatches(source).map((m) {
      return ShadcnDirective(
        fullLine: m.group(0)!,
        indent: m.group(1)!,
        keyword: m.group(2)!,
        quote: m.group(3)!,
        libPath: m.group(4)!,
        trailing: m.group(5)!,
      );
    }).toList();
  }

  /// The component sub-paths that [source] depends on, e.g. `{button.dart}`.
  Set<String> componentDeps(String source) => directives(source)
      .where((d) => d.isComponent)
      .map((d) => d.componentSubPath)
      .toSet();

  /// Rewrites component imports to paths relative to [fromSubPath].
  ///
  /// [fromSubPath] is the rewritten file's own location under the destination
  /// directory, so nested components (`form/fields/x.dart`) resolve correctly.
  /// Non-component directives are returned untouched.
  RewriteResult rewrite(String source, String fromSubPath) {
    final rewritten = <String>[];
    final kept = <ShadcnDirective>[];

    final out = source.replaceAllMapped(_directive, (match) {
      final directive = ShadcnDirective(
        fullLine: match.group(0)!,
        indent: match.group(1)!,
        keyword: match.group(2)!,
        quote: match.group(3)!,
        libPath: match.group(4)!,
        trailing: match.group(5)!,
      );

      if (!directive.isComponent) {
        kept.add(directive);
        return directive.fullLine;
      }

      final relative =
          _relativePath(from: fromSubPath, to: directive.componentSubPath);
      rewritten.add('${directive.libPath} -> $relative');
      return '${directive.indent}${directive.keyword} '
          '${directive.quote}$relative${directive.quote}${directive.trailing}';
    });

    return RewriteResult(source: out, rewritten: rewritten, kept: kept);
  }

  /// Relative import path from one component file to another, both expressed as
  /// sub-paths under the destination directory.
  static String _relativePath({required String from, required String to}) {
    final fromDirs = from.split('/')..removeLast();
    final toParts = to.split('/');

    var common = 0;
    while (common < fromDirs.length &&
        common < toParts.length - 1 &&
        fromDirs[common] == toParts[common]) {
      common++;
    }

    final ups = List.filled(fromDirs.length - common, '..');
    final down = toParts.sublist(common);
    final segments = [...ups, ...down];

    // A sibling file must be written as './x.dart' — a bare 'x.dart' is a
    // package-relative import in Dart, not a file-relative one.
    if (ups.isEmpty) return './${segments.join('/')}';
    return segments.join('/');
  }
}

class RewriteResult {
  RewriteResult({
    required this.source,
    required this.rewritten,
    required this.kept,
  });

  final String source;

  /// Human-readable `old -> new` pairs for imports that were rewritten.
  final List<String> rewritten;

  /// Directives deliberately left pointing at the package.
  final List<ShadcnDirective> kept;
}
