# Review: cmake-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: none

## Detailed Notes

### Structure check
- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive triggers (TRIGGER when: CMakeLists.txt, find_package, FetchContent, etc.) AND negative triggers (DO NOT trigger for: Makefile, Autotools, Meson, Bazel)
- ⚠️ Body is exactly 500 lines (borderline on "under 500" requirement — not a blocker)
- ✅ Imperative voice throughout, no filler
- ✅ Extensive code examples with correct CMake syntax in every section
- ✅ `references/` and `scripts/` properly linked in Resources section (lines 485–494)

### Content check — Accuracy verification
- ✅ CMake presets version 6 → requires CMake 3.25 (preset file correctly sets `cmakeMinimumRequired: 3.25`)
- ✅ `FIND_PACKAGE_ARGS` in FetchContent → introduced in CMake 3.24
- ✅ `target_precompile_headers` → introduced in CMake 3.16
- ✅ `UNITY_BUILD` target property → introduced in CMake 3.16
- ✅ `SameMinorVersion` compatibility mode → introduced in CMake 3.11
- ✅ `find_package` Config vs Module mode explanation is accurate
- ✅ Generator expression usage context table (troubleshooting.md) is correct
- ✅ All CMake command syntax verified correct

### Content check — Completeness
- ✅ Full lifecycle: project structure, targets, visibility, find_package, FetchContent, presets, genex, custom commands, install/export, testing, cross-compilation, CPack, IDE integration, performance
- ✅ References cover advanced patterns (superbuild, ExternalProject, sanitizers, coverage, object/interface libs)
- ✅ Troubleshooting covers real-world pain points (RPATH, Windows DLL, cache pitfalls, policy migration)
- ✅ Dependency management covers all major approaches (FetchContent, vcpkg, Conan, system, vendoring) with decision framework
- ✅ Scripts are functional and well-structured (cmake-init.sh, cmake-lint.sh, cmake-analyze.sh)
- ✅ Assets provide production-ready templates

### Minor observations (not issues)
- CMakeLists-root.txt uses `add_compile_options()` for sanitizers, which the lint script flags as a warning. This is pragmatic for root-level sanitizer toggles but slightly contradicts the anti-pattern guidance. Acceptable trade-off.
- Presets JSON uses version 6 (CMake 3.25) while SKILL.md title says "3.20+". Not a conflict since presets version is independent of project cmake_minimum_required, but could briefly confuse newcomers.

### Trigger check
- ✅ "set up CMake for my C++ project" → triggers via "configures C++ build systems", "creates CMakeLists.txt"
- ✅ "build with Make" → does NOT trigger due to "DO NOT trigger for: Makefile"
- ✅ Description lists specific CMake commands/files as triggers, providing high precision
