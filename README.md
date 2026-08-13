# shadcn_add — spike for flutter-shadcn-ui issue #286

A working proof-of-concept CLI for [flutter-shadcn-ui#286 "Feature: CLI"](https://github.com/nank1ro/flutter-shadcn-ui/issues/286):
copy component source into a consuming project, shadcn-style, instead of taking
the whole package as an opaque dependency.

**Status:** spike. It runs, resolves the real dependency graph, rewrites imports,
and the copied components compile and render. It also surfaced the specific
structural reason the feature could not be implemented as originally specced —
see [Finding 3](#finding-3-the-real-blocker-is-a-componenttheme-type-cycle-not-shadapp).

```bash
dart run bin/shadcn_add.dart button --target ../my_app
dart run bin/shadcn_add.dart date_picker --target ../my_app --dry-run
```

Zero package dependencies (uses `dart:io` only), so `dart pub get` cannot fail.

---

## The design decision

Issue #286 asks whether `ShadApp` can be avoided. This spike takes the position
that **it should not be** — and that this is not a compromise.

Files are split into two categories:

| Path | Treatment | Why |
|---|---|---|
| `lib/src/components/**` | **copied** into `lib/shadcn/`, imports rewritten to local relative paths | This is component source. The user should own and edit it. |
| `lib/src/theme/**`, `lib/src/utils/**`, `lib/src/raw_components/**`, `lib/src/i18n/**` | **left as `package:shadcn_ui/...` imports** | Shared runtime. Not the thing the user wants to fork. |

This mirrors what shadcn/ui actually does in React. `shadcn add button` copies
`button.tsx` into your repo, but your `package.json` still depends on
`@radix-ui/react-slot`, `class-variance-authority`, `clsx` and `tailwind-merge`.
**shadcn/ui was never dependency-free.** It gives you ownership of the
component's own source, not of the entire design-system runtime.

So keeping `ShadApp` and the theme layer as a package dependency is the faithful
port of the shadcn model, not a degraded version of it.

---

## What was verified

Environment: Dart 3.12.2, Flutter stable, Windows. Target was a throwaway
`flutter create` app with `shadcn_ui` added from pub.

### Finding 1 — the mechanic works

`date_picker` correctly resolves to **10 components** via breadth-first walk with
a visited set (safe against the diamonds and cycles that are genuinely present):

```
date_picker.dart -> button.dart, calendar.dart, popover.dart
calendar.dart    -> button.dart, icon_button.dart, select.dart
select.dart      -> disabled.dart, input.dart, popover.dart, separator.dart
input.dart       -> context_menu.dart, disabled.dart
context_menu.dart-> button.dart, popover.dart
icon_button.dart -> button.dart
```

Component-to-component imports are rewritten to local relative paths
(`package:shadcn_ui/src/components/button.dart` → `./button.dart`). The remaining
**26 infrastructure files** are reported and left as package imports.

### Finding 2 — ownership is real, not nominal

A widget test measured the rendered height of the copied `ShadButton`, then the
copied source was edited to force a different height:

| State | Rendered height |
|---|---|
| As copied | `40.0` |
| After editing `height()` in the local copy | `77.0` |

Editing copied source changes real rendered output. This was worth proving rather
than assuming, because the theme layer stays in the package and could plausibly
have overridden local changes. It does not.

### Finding 3 — the real blocker is a component↔theme type cycle, not `ShadApp`

Copying `components/button.dart` unmodified produces **three compile errors**:

```
error - The argument type 'Enum' can't be assigned to the parameter type 'ShadButtonSize'.
        lib/shadcn/button.dart:841
```

Root cause, confirmed by reading both files:

- `lib/src/components/button.dart` declares `enum ShadButtonVariant` and
  `enum ShadButtonSize`, and imports the theme layer for `ShadButtonTheme`.
- `lib/src/theme/components/button.dart` **imports `lib/src/components/button.dart`
  back** (line 2) and uses `ShadButtonSize` for its `size` field (line 54).

That is a circular dependency between the component layer and the theme layer,
running straight through the seam a copy-paste CLI has to cut. It is harmless
inside one package. But once the component is copied out, the local file declares
its own `ShadButtonSize` while the package's theme layer still refers to *its*
`ShadButtonSize`. Two distinct types, same name. Dart widens the `??` expression
to `Enum` and the assignment fails.

**Blast radius.** 10 files under `lib/src/theme/` import from
`lib/src/components/`, covering 5 distinct components:

| Theme file | imports component |
|---|---|
| `theme/components/button.dart` | `button.dart` |
| `theme/components/calendar.dart` | `button.dart`, `calendar.dart` |
| `theme/components/context_menu.dart` | `button.dart` |
| `theme/components/date_picker.dart` | `button.dart`, `calendar.dart` |
| `theme/components/menubar.dart` | `button.dart` |
| `theme/components/sheet.dart` | `sheet.dart` |
| `theme/components/tabs.dart` | `button.dart` |
| `theme/components/time_picker.dart` | `time_picker.dart` |
| `theme/themes/default_theme_variant.dart` | `button.dart` |
| `theme/themes/default_theme_no_secondary_border_variant.dart` | `button.dart` |

`components/button.dart` is imported by **8 of those 10**, which makes Button both
the highest-value component to make copyable and the one at the centre of the
cycle.

**Measured impact.** Installing `date_picker` (10 components) into a clean app
produces **16 compile errors, and every single one is this same root cause** —
a locally-declared type colliding with the package's version of the same type:

| Count | Error |
|---|---|
| 9 | `ShadButtonVariant` — `argument type 'Enum'/'Enum?' can't be assigned` |
| 3 | `ShadButtonSize` — same shape |
| 2 | `ShadDateTimeRange` — `can't be assigned to parameter type 'Never'/'ShadDateTimeRange'` |
| 1 | `ShadCalendarCaptionLayout` — same shape |
| 1 | switch not exhaustive (a knock-on of `Enum` widening) |

**It is not only enums.** `ShadDateTimeRange` is a *class* and
`ShadCalendarCaptionLayout` an *enum*, both declared in `components/calendar.dart`
and both referenced by the theme layer. So the precise rule is:

> Any public type — class or enum — declared in a component file and also
> referenced by the theme layer will collide when that component is copied out.

### Finding 4 — the fix works, but it needs a re-export, not just an import

Move the shared types out of the component files into neutral leaf files that both
layers import — e.g. `lib/src/theme/components/button_variants.dart` alongside the
existing `button_sizes.dart`. The theme layer then no longer imports the component
layer, and the cycle across the seam disappears.

**Measured across the full 10-component `date_picker` install, in three stages —
and the naive version of this fix makes things worse:**

| State | Errors |
|---|---|
| Pristine CLI output | **16** |
| Fix attempt 1: strip local declarations, add `import … show` | **49** |
| Fix attempt 2: strip local declarations, add `import … show` **and** `export … show` | **0** |

Attempt 1 was tested first because it is the obvious approach, and it is wrong.
Removing the declaration from `button.dart` and replacing it with a `show` import
makes the type usable *inside* `button.dart` but invisible to every other copied
component, because **a `show` import does not re-export**. `calendar.dart` imports
`./button.dart` and had been getting `ShadButtonVariant` transitively from its
declaration there, so it broke — turning 16 errors into 49.

The working form needs both directives in the copied file:

```dart
import 'package:shadcn_ui/src/components/button.dart'
    show ShadButtonVariant, ShadButtonSize;   // so this file can use them
export 'package:shadcn_ui/src/components/button.dart'
    show ShadButtonVariant, ShadButtonSize;   // so sibling copies still see them
```

With that, all 10 components compile with **zero errors** and the widget test still
passes and renders.

**Implication for the upstream refactor.** Extracting the types is necessary but not
sufficient on its own — whichever file previously *declared* a shared type must
continue to make it visible to the files that relied on transitive access, either by
re-exporting it or by having every consumer import the new neutral leaf file
directly. Worth stating explicitly in the refactor, since the obvious implementation
silently breaks downstream consumers.

**A CLI-side workaround exists** if upstream would rather not refactor: the CLI can
strip a copied file's declarations of any type the theme layer references and inject
the import/export pair above. That is exactly what the measurement did. It works, but
the generated file is then no longer a faithful copy of upstream source, which
undercuts the ownership story — so the upstream refactor remains the better fix.

### Finding 5 — the upstream refactor was implemented and verified against a real checkout

The concern that mattered before proposing this publicly: the theme classes are
**generated** (`with _$ShadButtonTheme`, `part 'button.g.theme.dart'`) by
`theme_extensions_builder`, so relocating the types could break codegen. It does not.

Verified on a fresh `git clone` of `nank1ro/flutter-shadcn-ui` @ `1576865`, with
Flutter stable / Dart 3.12.2:

1. **Baseline established.** `dart run build_runner build` succeeded — 36 outputs.
   (Noted in passing: the committed `.g.theme.dart` files already drift from what the
   current generator emits, independent of any change here.)
2. **Refactor applied.** Two new leaf libraries under `lib/src/theme/components/`:
   - `button_variants.dart` — `ShadButtonVariant`, `ShadButtonSize`
   - `calendar_models.dart` — `ShadDateTimeRange`, `ShadCalendarCaptionLayout`

   The component files re-export them so existing consumers are unaffected, and
   **9 theme files were repointed** off the component layer onto the leaves.
3. **Results:**

| Check | Result |
|---|---|
| `build_runner build` | succeeds, 59 inputs, 21 outputs, no errors |
| `button.g.theme.dart` vs pre-refactor baseline | **byte-identical** |
| `dart analyze lib` | **No issues found** (their `very_good_analysis` bar) |
| Public barrel still exports all four types | yes — **not a breaking change** |
| `flutter test` | 321 pass, 6 fail — **all 6 proven pre-existing** by re-running them on stashed-clean code; they are `sheet` golden-image tests, and nothing in `sheet` was touched |

**The end-to-end payoff.** With the refactored package as a path dependency and the
CLI run with `--from-path` (so copies come from the installed version, not `main`):

| Package state | CLI output | Compile errors |
|---|---|---|
| Unrefactored | 10 components | **16** |
| Refactored | 10 components, **zero manual fixes** | **0** |

The copies are faithful — `button.dart` 1160 lines in both, `calendar.dart` 1901 in
both, `date_picker.dart` 1369 in both, with only component-to-component imports
rewritten (3 each in calendar and date_picker, 0 in button since it has no component
dependencies). The widget test still passes and renders.

**Two components remain unconverted:** `theme/components/sheet.dart` and
`theme/components/time_picker.dart` still import their own component files. Same
pattern, same fix, and neither is in the `date_picker` graph so neither affected this
measurement.

**Remaining caveat:** the 4 leaf-file names above are a proposal, not a considered API
decision. Where these types should live is the maintainer's call — the finding is that
they must live *outside* the component files, not specifically in these two.

### Finding 5 — `implementation_imports` lint noise

The copied file imports `package:shadcn_ui/src/...`, which trips Dart's
`implementation_imports` lint in the consumer's project — 10 info-level warnings
for Button alone:

```
info - Import of a library in the 'lib/src' directory of another package
       - lib/shadcn/button.dart:4:8 - implementation_imports
```

Not fatal, but every user of the CLI would see it. Fixable upstream by publicly
exporting the infrastructure the copied components need, e.g. a
`package:shadcn_ui/internals.dart` barrel, so copied files import a public path.

---

## Tests

34 unit tests, `dart test`, no network required (the resolver is tested against a
fake fetcher):

```bash
dart pub get && dart analyze && dart test
```

Coverage worth noting: directive parsing (quote styles, `show`/`hide` clauses,
`export`, indentation, commented-out imports correctly ignored); the
component-vs-infrastructure classification; relative-path rewriting **including the
nested `components/form/` cases that the flat upstream layout never exercises**; and
resolver behaviour on transitive chains, diamonds (fetched once), genuine cycles,
self-imports, and missing files. Installer tests cover dry-run, overwrite protection
of user-edited files, nested output directories, and deterministic ordering.

## Honest limitations of this spike

- **Directive parsing is a regular expression**, not `package:analyzer`. Fine for
  a spike because directives are stable and appear at the top of the file; a real
  implementation should use the analyzer.
- **Error paths are untested.** Network failure, a 404 component, a missing
  `pubspec.yaml` and a non-default `--ref` are all handled in code but have no test
  coverage.
- **`flutter run` was never executed.** Rendering was verified with a widget test
  measuring real laid-out geometry, which is repeatable but is not the same as seeing
  it on a device.
- **Name collisions are the user's problem right now.** The copied `ShadButton`
  and the barrel's `ShadButton` are different types, so consumers must
  `hide ShadButton, ShadButtonVariant, ShadButtonSize` when importing
  `shadcn_ui.dart`. A real implementation should generate a local barrel and
  document this.
- **No version pinning.** Pulls from a git ref (`--ref`, default `main`). Should
  resolve against the installed `shadcn_ui` version so copied source matches the
  package the project depends on.
- **Not tested against the `components/form/` subtree.** Path handling supports
  nesting, but only flat components were exercised.
- **Mason not evaluated.** Felix Angelov suggested Mason on the issue; this spike
  deliberately used plain Dart to keep it dependency-free and fast to throw away.
  Which approach the real implementation should use is a maintainer decision.

## Repro

```bash
dart pub get
dart analyze                       # clean

# In a throwaway Flutter app with shadcn_ui added:
dart run bin/shadcn_add.dart button --target /path/to/app
cd /path/to/app && flutter analyze  # 3 errors -> see Finding 3
```
