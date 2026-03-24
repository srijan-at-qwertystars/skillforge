# QA Review: devops/nix-packages

**Reviewer**: Copilot CLI QA  
**Date**: 2025-07-15  
**Skill path**: `devops/nix-packages/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ Pass | `name: nix-packages` |
| YAML frontmatter has `description` | ✅ Pass | Multi-line description present |
| Positive triggers | ✅ Pass | Comprehensive: nix build, nix develop, flake.nix, shell.nix, mkDerivation, overlays, Home Manager, etc. |
| Negative triggers | ✅ Pass | Explicit: Nginx, Unix general, npm, Nix cryptocurrency, Docker (unless dockerTools) |
| Body under 500 lines | ✅ Pass | 487 lines (just under limit) |
| Imperative voice, no filler | ✅ Pass | Direct, technical, no fluff |
| Examples with input/output | ✅ Pass | Extensive code examples throughout, CLI commands with comments |
| References/scripts properly linked | ✅ Pass | All 3 references, 3 scripts, 4 assets described at bottom |

**Structure score**: Excellent. Clean organization with logical section flow.

---

## b. Content Check — Technical Accuracy

### Nix Commands
- `nix develop`, `nix build`, `nix run`, `nix shell`, `nix flake init`, `nix flake show`, `nix flake metadata`, `nix fmt`, `nix store gc`, `nix store optimise` — all **correct** ✅
- `nix search nixpkgs python3` — **correct** ✅
- `nix profile install/remove` — **correct** ✅

### ⚠️ Issue: Deprecated `--update-input` flag
- **SKILL.md line 156**: `nix flake lock --update-input nixpkgs` — **DEPRECATED** since Nix 2.19+. The correct command is `nix flake update nixpkgs`.
- **references/troubleshooting.md line 305**: Same deprecated command appears again.
- Source: [Nix 2.28.6 Reference Manual](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake-update.html)

### ⚠️ Issue: Operator precedence bug in overlay example
- **SKILL.md line 109**: `patches = old.patches or [] ++ [ ./custom.patch ];`
- In Nix, `++` binds tighter than `or`, so this parses as `old.patches or ([] ++ [ ./custom.patch ])` — meaning: use `old.patches` if it exists (without appending), otherwise use `[ ./custom.patch ]`. The append never happens when patches exist.
- **Correct**: `patches = (old.patches or []) ++ [ ./custom.patch ];`
- Note: `references/advanced-patterns.md` line 193 correctly uses parentheses: `(prev.patches or []) ++ [ ./fix.patch ]` — so this is inconsistent.

### flake.nix Structure
- `flake-utils.lib.eachDefaultSystem` pattern — **correct** ✅
- `devShells.default = pkgs.mkShell { ... }` — **correct** ✅
- `packages.default`, `apps.default` structure — **correct** ✅
- `inputs.nixpkgs.follows` pattern — **correct** ✅

### Nixpkgs Overlay Patterns
- `final: prev:` naming convention — **correct** (modern standard) ✅
- `override` vs `overrideAttrs` distinction — **correct** ✅
- `lib.composeManyExtensions` — **correct** ✅
- Fixed-point explanation and `fix` combinator — **correct** ✅
- Infinite recursion warning for `final.hello.overrideAttrs` — **correct** ✅

### Home Manager Integration
- `home-manager.lib.homeManagerConfiguration` — **correct** ✅
- `inputs.nixpkgs.follows = "nixpkgs"` — **correct** ✅
- `home-manager switch --flake .#alice` — **correct** ✅
- `home.stateVersion`, `home.packages`, `programs.*` — **correct** ✅

### Other Content
- Build phases order (unpack → patch → configure → build → check → install → fixup) — **correct** ✅
- `nativeBuildInputs` vs `buildInputs` vs `propagatedBuildInputs` — **correct** ✅
- Fetcher patterns (`fetchurl`, `fetchFromGitHub`, `fetchgit`) — **correct** ✅
- SRI hash format guidance — **correct** ✅
- `dockerTools.buildImage` and `streamLayeredImage` — **correct** ✅
- Cross-compilation via `pkgsCross` — **correct** ✅
- NixOS module system (`lib.mkEnableOption`, `lib.mkOption`, `lib.types.*`) — **correct** ✅
- Cachix usage — **correct** ✅
- GitHub Actions with `cachix/install-nix-action@v27` — **correct** ✅

### Missing Gotchas (Minor)
- `nix develop` defaults to bash (not user's shell), which can be surprising for zsh/fish users. Not mentioned.
- `nix flake lock --update-input` deprecation is not called out in the pitfalls section.

---

## c. Trigger Check

| Aspect | Assessment |
|--------|------------|
| Positive triggers cover core Nix workflows | ✅ Comprehensive — covers commands, config files, language constructs, concepts |
| Negative triggers prevent false positives | ✅ Well-specified — Nginx, npm, Nix crypto, generic Docker |
| Risk of false negatives | Low — triggers on both command names and conceptual terms |
| Risk of false positives | Low — explicit exclusions for common confusions |
| Keyword coverage | Excellent — includes `mkDerivation`, `buildInputs`, `fetchurl`, `cachix`, `flake.lock`, Nix language syntax terms |

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Two correctness issues: deprecated `--update-input` (×2 occurrences) and operator precedence bug in overlay example. All other content verified accurate against official docs. |
| **Completeness** | 5 | Exceptionally thorough. Covers installation, language, flakes, devShells, packaging, NixOS, Home Manager, overlays, CI/CD, Docker, cross-compilation, caching. Three deep-dive references, three utility scripts, four ready-to-use templates. |
| **Actionability** | 5 | Outstanding. Copy-paste examples for every major workflow. Scripts automate common tasks. Templates have clear `TODO` markers. Comparison table for nix-shell vs nix develop. Quick reference card. |
| **Trigger quality** | 5 | Precise positive triggers with broad keyword coverage. Explicit negative triggers prevent the most common confusion points (Nginx, npm, cryptocurrency). |

### **Overall: 4.75 / 5.0**

---

## e. Issue Filing Assessment

- Overall score (4.75) ≥ 4.0 ✅
- No dimension ≤ 2 ✅
- **No GitHub issues required.**

### Recommended Fixes (non-blocking)

1. **SKILL.md line 156**: Replace `nix flake lock --update-input nixpkgs` with `nix flake update nixpkgs`
2. **SKILL.md line 109**: Add parentheses: `(old.patches or []) ++ [ ./custom.patch ]`
3. **references/troubleshooting.md line 305**: Replace deprecated `--update-input` command
4. **Minor enhancement**: Add note that `nix develop` defaults to bash, suggest `--command zsh` workaround

---

## f. Test Status

**PASS** — High-quality skill with minor accuracy issues that don't impede usability.
