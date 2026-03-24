#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# flutter-ci-setup.sh
# Generates GitHub Actions CI/CD workflow for Flutter projects with caching,
# testing, coverage, and APK/IPA builds.
#
# Usage: ./flutter-ci-setup.sh [--output-dir <dir>] [--ios] [--web]
# ============================================================================

# --- Defaults ---------------------------------------------------------------
OUTPUT_DIR=".github/workflows"
INCLUDE_IOS=false
INCLUDE_WEB=false
FLUTTER_VERSION="3.x"
MIN_COVERAGE=80

# --- Helpers ----------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --output-dir <dir>   Output directory (default: .github/workflows)
  --ios                Include iOS build job
  --web                Include web build job
  --flutter <version>  Flutter version constraint (default: 3.x)
  --coverage <pct>     Minimum coverage threshold (default: 80)
  --help               Show this help message

Example:
  $(basename "$0") --ios --web --coverage 75
EOF
  exit 0
}

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# --- Parse Args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --ios)        INCLUDE_IOS=true; shift ;;
    --web)        INCLUDE_WEB=true; shift ;;
    --flutter)    FLUTTER_VERSION="$2"; shift 2 ;;
    --coverage)   MIN_COVERAGE="$2"; shift 2 ;;
    --help)       usage ;;
    *)            error "Unknown option: $1" ;;
  esac
done

# --- Generate ----------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"

WORKFLOW_FILE="$OUTPUT_DIR/flutter-ci.yml"
info "Generating CI workflow: $WORKFLOW_FILE"

cat > "$WORKFLOW_FILE" << YAML
name: Flutter CI/CD

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true

env:
  FLUTTER_VERSION: '${FLUTTER_VERSION}'

jobs:
  # ──────────────────────────────────────────────────────────────────────────
  # Quality checks: analyze, format, test
  # ──────────────────────────────────────────────────────────────────────────
  quality:
    name: Quality Checks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: \${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true

      - name: Cache pub dependencies
        uses: actions/cache@v4
        with:
          path: |
            ~/.pub-cache
            .dart_tool/
          key: \${{ runner.os }}-pub-\${{ hashFiles('**/pubspec.lock') }}
          restore-keys: |
            \${{ runner.os }}-pub-

      - name: Install dependencies
        run: flutter pub get

      - name: Check formatting
        run: dart format --set-exit-if-changed .

      - name: Run analyzer
        run: dart analyze --fatal-infos

      - name: Run tests with coverage
        run: flutter test --coverage --reporter=expanded

      - name: Check coverage threshold
        run: |
          sudo apt-get install -y lcov > /dev/null 2>&1
          # Remove generated files from coverage
          lcov --remove coverage/lcov.info \\
            '**/*.g.dart' \\
            '**/*.freezed.dart' \\
            '**/*.gr.dart' \\
            '**/generated/**' \\
            -o coverage/lcov_filtered.info \\
            --quiet
          # Check threshold
          COVERAGE=\$(lcov --summary coverage/lcov_filtered.info 2>&1 | \\
            grep -oP 'lines\.*: \K[0-9.]+' || echo "0")
          echo "Code coverage: \${COVERAGE}%"
          if (( \$(echo "\$COVERAGE < ${MIN_COVERAGE}" | bc -l) )); then
            echo "::error::Coverage \${COVERAGE}% is below ${MIN_COVERAGE}% threshold"
            exit 1
          fi

      - name: Upload coverage to Codecov
        if: github.event_name == 'push'
        uses: codecov/codecov-action@v4
        with:
          files: coverage/lcov_filtered.info
          fail_ci_if_error: false
        env:
          CODECOV_TOKEN: \${{ secrets.CODECOV_TOKEN }}

  # ──────────────────────────────────────────────────────────────────────────
  # Build Android APK
  # ──────────────────────────────────────────────────────────────────────────
  build-android:
    name: Build Android
    needs: quality
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: \${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true

      - name: Setup Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Cache Gradle
        uses: actions/cache@v4
        with:
          path: |
            ~/.gradle/caches
            ~/.gradle/wrapper
          key: \${{ runner.os }}-gradle-\${{ hashFiles('**/*.gradle*', '**/gradle-wrapper.properties') }}

      - name: Install dependencies
        run: flutter pub get

      - name: Build APK
        run: flutter build apk --release

      - name: Build App Bundle
        run: flutter build appbundle --release

      - name: Upload APK artifact
        uses: actions/upload-artifact@v4
        with:
          name: android-release
          path: |
            build/app/outputs/flutter-apk/app-release.apk
            build/app/outputs/bundle/release/app-release.aab
          retention-days: 14
YAML

# Append iOS job if requested
if [[ "$INCLUDE_IOS" == true ]]; then
  cat >> "$WORKFLOW_FILE" << 'YAML'

  # ──────────────────────────────────────────────────────────────────────────
  # Build iOS
  # ──────────────────────────────────────────────────────────────────────────
  build-ios:
    name: Build iOS
    needs: quality
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true

      - name: Cache CocoaPods
        uses: actions/cache@v4
        with:
          path: ios/Pods
          key: ${{ runner.os }}-pods-${{ hashFiles('ios/Podfile.lock') }}

      - name: Install dependencies
        run: flutter pub get

      - name: Build iOS (no codesign)
        run: flutter build ios --release --no-codesign

      - name: Upload iOS artifact
        uses: actions/upload-artifact@v4
        with:
          name: ios-release
          path: build/ios/iphoneos/Runner.app
          retention-days: 14
YAML
fi

# Append web job if requested
if [[ "$INCLUDE_WEB" == true ]]; then
  cat >> "$WORKFLOW_FILE" << 'YAML'

  # ──────────────────────────────────────────────────────────────────────────
  # Build Web
  # ──────────────────────────────────────────────────────────────────────────
  build-web:
    name: Build Web
    needs: quality
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true

      - name: Install dependencies
        run: flutter pub get

      - name: Build web
        run: flutter build web --release

      - name: Upload web artifact
        uses: actions/upload-artifact@v4
        with:
          name: web-release
          path: build/web
          retention-days: 14
YAML
fi

ok "Generated: $WORKFLOW_FILE"

# --- Summary -----------------------------------------------------------------
echo ""
echo "CI workflow generated at: $WORKFLOW_FILE"
echo ""
echo "Jobs included:"
echo "  ✓ quality    — format, analyze, test, coverage (≥${MIN_COVERAGE}%)"
echo "  ✓ build-android — APK + AAB"
[[ "$INCLUDE_IOS" == true ]] && echo "  ✓ build-ios   — iOS release (no codesign)"
[[ "$INCLUDE_WEB" == true ]] && echo "  ✓ build-web   — Web release"
echo ""
echo "Next steps:"
echo "  1. Review the generated workflow"
echo "  2. Add CODECOV_TOKEN to repository secrets (optional)"
echo "  3. Commit and push: git add .github/ && git commit -m 'Add Flutter CI'"
echo ""
