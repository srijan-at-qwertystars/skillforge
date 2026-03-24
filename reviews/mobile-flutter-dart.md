# QA Review: mobile/flutter-dart

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17
**Skill path:** `mobile/flutter-dart/SKILL.md`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description`, `triggers.positive`, `triggers.negative` all present |
| Line count | ✅ Pass | 500 lines (exactly at limit) |
| Imperative voice | ✅ Pass | Consistent imperative throughout ("Use", "Prefer", "Enforce", "Never") |
| Code examples | ✅ Pass | 15+ Dart/Flutter examples covering widgets, state, routing, networking, testing |
| References linked | ✅ Pass | 3 reference docs verified present: state-management-guide.md (716L), testing-guide.md (1334L), troubleshooting.md (873L) |
| Scripts linked | ✅ Pass | 3 scripts verified: setup-flutter-project.sh, flutter-ci-setup.sh, generate-icons.sh — all executable with shebangs |
| Assets linked | ✅ Pass | 5 assets verified: analysis_options.yaml, pubspec-template.yaml, github-actions-flutter.yml, app-architecture-template.dart, theme-template.dart |

## b. Content Check

### Verified Accurate
- **Dart 3.x syntax**: Records, pattern matching (`switch` expressions, `if-case`), sealed classes, class modifiers — all correct per current Dart spec
- **Riverpod codegen**: Uses `Ref ref` parameter (correct for Riverpod ≥2.6.x where typed refs like `FooRef` are deprecated)
- **Riverpod guidance**: Correctly recommends Notifier/AsyncNotifier over deprecated StateNotifier
- **GoRouter**: ShellRoute, redirect, path parameters — matches current API
- **Bloc/Cubit**: Sealed events, `on<Event>` handler pattern — current best practice
- **MediaQuery**: Uses `MediaQuery.sizeOf(context)` — correct modern API (avoids unnecessary rebuilds vs `MediaQuery.of(context).size`)
- **Testing pyramid**: Correct patterns for unit (mocktail), widget (pump/find), golden, and integration tests
- **Platform channels**: MethodChannel/EventChannel patterns accurate; FFIgen/JNIgen recommendation is current

### Issues Found

1. **`useMaterial3: true` is redundant** (minor): Since Flutter 3.16 (Nov 2023), `useMaterial3` defaults to `true`. The theme template explicitly sets it, which is harmless but misleading — suggests it's still opt-in. Should add a comment noting it's default, or remove the flag.

2. **Isar database status needs caveat** (minor): Isar's official development has slowed significantly; the community fork "Isar Plus" is now the actively maintained version. The skill lists Isar without noting this. Should add ObjectBox as an alternative and note Isar's maintenance status.

3. **Missing Dart 3.4+ features** (minor): No mention of extension types (`extension type Dollars(int value) implements int {}`) introduced in Dart 3.3, which are important for zero-cost wrapper types in production code.

4. **No mention of `flutter_hooks`** (minor): HookWidget/`useEffect`/`useState` is a popular alternative widget pattern, especially paired with Riverpod (`hooks_riverpod`). Worth at least a mention.

5. **analysis_options.yaml uses `flutter_lints`**: The include references `package:flutter_lints/flutter.yaml` which is correct for the Flutter ecosystem.

### Missing Gotchas (not covered)
- Wasm compilation target for Flutter web (emerging in 2024+)
- Impeller renderer limitations on web (still in beta)
- `dart fix --apply` for automated migration of deprecated APIs
- State restoration across process death on Android (`RestorationMixin`)

## c. Trigger Check

### Positive Triggers (32 entries)
- ✅ Highly specific to Flutter/Dart ecosystem
- ✅ Covers framework terms (`StatelessWidget`, `Riverpod`, `GoRouter`), tooling (`pubspec.yaml`, `build_runner`, `flutter_lints`), and CI (`Codemagic`, `Fastlane Flutter`)
- ✅ No ambiguous terms that would match non-Flutter contexts

### Negative Triggers (12 entries)
- ✅ Correctly excludes: React Native, KMM, SwiftUI, Jetpack Compose, Xamarin, MAUI, Ionic, Cordova, NativeScript
- ✅ Includes catch-all: "general mobile without Flutter context"
- ⚠️ Could add: `Capacitor`, `Expo` to strengthen mobile-framework exclusion

### False Trigger Risk
- **Low risk of false positive**: Triggers like "Flutter", "Riverpod", "pubspec.yaml" are unambiguous
- **Low risk of false negative**: Good coverage of Flutter-specific terms including niche ones like "Impeller", "golden test", "InheritedWidget"
- **Edge case**: "Dart" alone could match server-side Dart (shelf, dart_frog) — acceptable since the skill covers Dart language features broadly

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Core APIs, syntax, and patterns are correct. Minor issues: redundant `useMaterial3`, Isar maintenance status |
| **Completeness** | 4 | Excellent breadth (widgets, state, nav, networking, storage, testing, CI/CD, perf, multi-platform). Gaps: extension types, hooks, Wasm target |
| **Actionability** | 5 | Outstanding — 15+ code examples, 3 automation scripts, 5 template assets, 3 deep-dive references. Developer can scaffold a full project immediately |
| **Trigger Quality** | 4 | Strong positive/negative separation. 32 specific positive triggers, 12 negatives. Minor gap in negative coverage |
| **Overall** | **4.25** | Well above threshold. Production-ready with minor improvements possible |

## e. Verdict

**PASS** ✅

Overall score 4.25/5.0 — no dimension ≤ 2. This is a high-quality, actionable skill with comprehensive coverage of the Flutter/Dart ecosystem. The minor issues identified are enhancement opportunities, not blockers.

## f. Recommended Improvements (non-blocking)

1. Add comment to `useMaterial3: true` noting it's default since Flutter 3.16, or remove the explicit flag
2. Add Isar maintenance caveat and mention ObjectBox as alternative
3. Add brief section on extension types (Dart 3.3+)
4. Add `Capacitor`, `Expo` to negative triggers
5. Mention `dart fix --apply` in anti-patterns or CI section
