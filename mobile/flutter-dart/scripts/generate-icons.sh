#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# generate-icons.sh
# Generates app icons and splash screens using flutter_launcher_icons and
# flutter_native_splash packages.
#
# Usage: ./generate-icons.sh [--icon <path>] [--splash-color <hex>] [--splash-image <path>]
# ============================================================================

# --- Defaults ---------------------------------------------------------------
ICON_PATH=""
SPLASH_COLOR="#ffffff"
SPLASH_DARK_COLOR="#1a1a2e"
SPLASH_IMAGE=""
ADAPTIVE_BG_COLOR="#ffffff"
FLUTTER_CMD="flutter"

# --- Helpers ----------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --icon <path>            Path to app icon (1024x1024 PNG recommended)
  --splash-image <path>    Path to splash screen center image
  --splash-color <hex>     Splash screen background color (default: #ffffff)
  --splash-dark <hex>      Dark mode splash background (default: #1a1a2e)
  --adaptive-bg <hex>      Android adaptive icon background color (default: #ffffff)
  --help                   Show this help message

Examples:
  $(basename "$0") --icon assets/icon.png
  $(basename "$0") --icon assets/icon.png --splash-image assets/splash_logo.png --splash-color "#4F46E5"
  $(basename "$0")  # Generates config files only, for manual editing
EOF
  exit 0
}

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# --- Parse Args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --icon)          ICON_PATH="$2"; shift 2 ;;
    --splash-image)  SPLASH_IMAGE="$2"; shift 2 ;;
    --splash-color)  SPLASH_COLOR="$2"; shift 2 ;;
    --splash-dark)   SPLASH_DARK_COLOR="$2"; shift 2 ;;
    --adaptive-bg)   ADAPTIVE_BG_COLOR="$2"; shift 2 ;;
    --help)          usage ;;
    *)               error "Unknown option: $1" ;;
  esac
done

# --- Validate ----------------------------------------------------------------
if [[ ! -f "pubspec.yaml" ]]; then
  error "pubspec.yaml not found. Run this script from your Flutter project root."
fi

if [[ -n "$ICON_PATH" && ! -f "$ICON_PATH" ]]; then
  error "Icon file not found: $ICON_PATH"
fi

if [[ -n "$SPLASH_IMAGE" && ! -f "$SPLASH_IMAGE" ]]; then
  error "Splash image not found: $SPLASH_IMAGE"
fi

# --- Add Dependencies -------------------------------------------------------
info "Adding icon and splash dependencies..."

$FLUTTER_CMD pub add --dev flutter_launcher_icons
$FLUTTER_CMD pub add --dev flutter_native_splash

ok "Dependencies added"

# --- Generate Launcher Icons Config ------------------------------------------
info "Generating flutter_launcher_icons config..."

ICONS_CONFIG="flutter_launcher_icons.yaml"

if [[ -n "$ICON_PATH" ]]; then
  cat > "$ICONS_CONFIG" << YAML
flutter_launcher_icons:
  android: true
  ios: true
  image_path: "${ICON_PATH}"
  min_sdk_android: 21

  # Android adaptive icon
  adaptive_icon_background: "${ADAPTIVE_BG_COLOR}"
  adaptive_icon_foreground: "${ICON_PATH}"
  adaptive_icon_round: "${ICON_PATH}"

  # Web favicon
  web:
    generate: true
    image_path: "${ICON_PATH}"
    background_color: "${ADAPTIVE_BG_COLOR}"
    theme_color: "${ADAPTIVE_BG_COLOR}"

  # Windows
  windows:
    generate: true
    image_path: "${ICON_PATH}"
    icon_size: 48

  # macOS
  macos:
    generate: true
    image_path: "${ICON_PATH}"
YAML
else
  cat > "$ICONS_CONFIG" << 'YAML'
# flutter_launcher_icons configuration
# Docs: https://pub.dev/packages/flutter_launcher_icons
#
# 1. Place your 1024x1024 app icon at assets/icon/app_icon.png
# 2. Update image_path below
# 3. Run: dart run flutter_launcher_icons

flutter_launcher_icons:
  android: true
  ios: true
  image_path: "assets/icon/app_icon.png"
  min_sdk_android: 21

  # Android adaptive icon (Android 8.0+)
  adaptive_icon_background: "#ffffff"
  adaptive_icon_foreground: "assets/icon/app_icon.png"

  # Web favicon
  web:
    generate: true
    image_path: "assets/icon/app_icon.png"
    background_color: "#ffffff"
    theme_color: "#4F46E5"

  # Windows
  windows:
    generate: true
    image_path: "assets/icon/app_icon.png"
    icon_size: 48

  # macOS
  macos:
    generate: true
    image_path: "assets/icon/app_icon.png"
YAML
  warn "No icon path provided. Edit $ICONS_CONFIG with your icon path."
fi

ok "Created $ICONS_CONFIG"

# --- Generate Splash Screen Config -------------------------------------------
info "Generating flutter_native_splash config..."

SPLASH_CONFIG="flutter_native_splash.yaml"

if [[ -n "$SPLASH_IMAGE" ]]; then
  cat > "$SPLASH_CONFIG" << YAML
flutter_native_splash:
  color: "${SPLASH_COLOR}"
  image: "${SPLASH_IMAGE}"

  # Dark mode
  color_dark: "${SPLASH_DARK_COLOR}"
  image_dark: "${SPLASH_IMAGE}"

  # Android 12+ splash screen
  android_12:
    color: "${SPLASH_COLOR}"
    image: "${SPLASH_IMAGE}"
    icon_background_color: "${SPLASH_COLOR}"
    color_dark: "${SPLASH_DARK_COLOR}"
    image_dark: "${SPLASH_IMAGE}"
    icon_background_color_dark: "${SPLASH_DARK_COLOR}"

  # iOS
  ios: true

  # Web
  web: true
  web_image_mode: center

  # Keep splash until app is ready (call FlutterNativeSplash.remove())
  android: true
  fullscreen: false
YAML
else
  cat > "$SPLASH_CONFIG" << YAML
# flutter_native_splash configuration
# Docs: https://pub.dev/packages/flutter_native_splash
#
# 1. Place your splash logo at assets/splash/splash_logo.png
# 2. Update image paths below
# 3. Run: dart run flutter_native_splash:create

flutter_native_splash:
  color: "${SPLASH_COLOR}"
  # image: "assets/splash/splash_logo.png"

  # Dark mode
  color_dark: "${SPLASH_DARK_COLOR}"
  # image_dark: "assets/splash/splash_logo.png"

  # Android 12+ splash screen
  android_12:
    color: "${SPLASH_COLOR}"
    # image: "assets/splash/splash_logo.png"
    # icon_background_color: "${SPLASH_COLOR}"
    color_dark: "${SPLASH_DARK_COLOR}"

  # Platforms
  android: true
  ios: true
  web: true
  web_image_mode: center
  fullscreen: false
YAML
  warn "No splash image provided. Edit $SPLASH_CONFIG with your splash image path."
fi

ok "Created $SPLASH_CONFIG"

# --- Create Asset Directories ------------------------------------------------
info "Creating asset directories..."
mkdir -p assets/icon assets/splash
ok "Asset directories created"

# --- Run Generators ----------------------------------------------------------
if [[ -n "$ICON_PATH" ]]; then
  info "Generating app icons..."
  dart run flutter_launcher_icons -f "$ICONS_CONFIG"
  ok "App icons generated"
else
  info "Skipping icon generation (no icon provided). Run manually:"
  echo "  dart run flutter_launcher_icons -f $ICONS_CONFIG"
fi

if [[ -n "$SPLASH_IMAGE" ]]; then
  info "Generating splash screens..."
  dart run flutter_native_splash:create --path="$SPLASH_CONFIG"
  ok "Splash screens generated"
else
  info "Skipping splash generation (no image provided). Run manually:"
  echo "  dart run flutter_native_splash:create --path=$SPLASH_CONFIG"
fi

# --- Splash Preservation Code ------------------------------------------------
info "Add this to your main.dart to control splash screen removal:"
echo ""
cat << 'DART'
  import 'package:flutter_native_splash/flutter_native_splash.dart';

  void main() {
    // Keep splash screen visible during initialization
    final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

    // ... initialize services ...

    // Remove splash when ready
    FlutterNativeSplash.remove();

    runApp(const MyApp());
  }
DART

echo ""
ok "Done! Review the generated configs and assets."
