# Tauri v2 Troubleshooting Guide

## Table of Contents

- [Common Build Errors](#common-build-errors)
  - [Rust Compilation Errors](#rust-compilation-errors)
  - [WebView2 Issues (Windows)](#webview2-issues-windows)
  - [WebKitGTK Issues (Linux)](#webkitgtk-issues-linux)
  - [macOS Build Issues](#macos-build-issues)
- [Cross-Compilation Gotchas](#cross-compilation-gotchas)
- [Debugging](#debugging)
  - [Frontend DevTools](#frontend-devtools)
  - [Rust Logging](#rust-logging)
  - [IPC Debugging](#ipc-debugging)
- [Performance Optimization](#performance-optimization)
- [Bundle Size Reduction](#bundle-size-reduction)
- [Platform-Specific Quirks](#platform-specific-quirks)
  - [macOS Signing and Notarization](#macos-signing-and-notarization)
  - [Windows Installer](#windows-installer)
  - [Linux Packaging](#linux-packaging)
- [Webview Compatibility](#webview-compatibility)
- [Plugin Issues](#plugin-issues)
- [Security and Capabilities](#security-and-capabilities)

---

## Common Build Errors

### Rust Compilation Errors

#### `cargo` not found

```
error: cargo not found
```

**Fix:** Install Rust via rustup:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
```

#### Missing Rust target

```
error[E0463]: can't find crate for `std`
```

**Fix:** Add the target:
```bash
rustup target add x86_64-apple-darwin
rustup target add aarch64-apple-darwin
rustup target add x86_64-pc-windows-msvc
```

#### Version conflicts in Cargo.toml

```
error: failed to select a version for `serde`
```

**Fix:**
```bash
# Check dependency tree for conflicts
cargo tree -d
# Update all dependencies
cargo update
# Or pin specific version
cargo update -p serde --precise 1.0.193
```

#### `tauri::generate_context!()` fails

```
error: proc macro panicked: Failed to read tauri.conf.json
```

**Fix:** Ensure `tauri.conf.json` exists in `src-tauri/` and is valid JSON:
```bash
cd src-tauri
cat tauri.conf.json | python3 -m json.tool  # Validate JSON
```

#### Linker errors on Windows

```
LINK : fatal error LNK1181: cannot open input file 'WebView2LoaderStatic.lib'
```

**Fix:** Ensure Visual Studio Build Tools are installed with the "Desktop development with C++" workload.

### WebView2 Issues (Windows)

#### WebView2 not installed

```
Error: WebView2 Runtime is not installed
```

**Fix:**
1. Download WebView2 Runtime from Microsoft: https://developer.microsoft.com/en-us/microsoft-edge/webview2/
2. Or bundle the bootstrapper:
```json
{
  "bundle": {
    "windows": {
      "webviewInstallMode": {
        "type": "embedBootstrapper"
      }
    }
  }
}
```

Other install mode options:
```json
// Skip (user must have it)
{ "type": "skip" }

// Download bootstrapper at install time
{ "type": "downloadBootstrapper" }

// Embed offline installer (large but reliable)
{ "type": "offlineInstaller", "path": "./WebView2RuntimeInstaller.exe" }
```

#### WebView2 blank screen on Windows

**Possible causes:**
1. GPU acceleration issues — try disabling:
```json
{
  "app": {
    "windows": [{ "label": "main", "useHttpsScheme": true }]
  }
}
```
2. Antivirus blocking WebView2 process.
3. Corrupted WebView2 cache — delete `%LOCALAPPDATA%\<app-identifier>/EBWebView/`.

### WebKitGTK Issues (Linux)

#### Missing WebKitGTK libraries

```
Package webkit2gtk-4.1 was not found in the pkg-config search path
```

**Fix by distro:**
```bash
# Ubuntu / Debian
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev

# Fedora
sudo dnf install webkit2gtk4.1-devel gtk3-devel libappindicator-gtk3-devel librsvg2-devel

# Arch
sudo pacman -S webkit2gtk-4.1 gtk3 libappindicator-gtk3 librsvg
```

#### Blank window on Wayland

Tauri uses X11 by default. For Wayland:
```bash
# Set environment variable
GDK_BACKEND=x11 ./my-app  # Force X11
# Or for Wayland native (experimental)
WEBKIT_DISABLE_COMPOSITING_MODE=1 ./my-app
```

### macOS Build Issues

#### Command Line Tools missing

```
xcrun: error: unable to find utility "clang"
```

**Fix:**
```bash
xcode-select --install
```

#### Universal binary build fails

```
error: failed to build for target aarch64-apple-darwin
```

**Fix:**
```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
npm run tauri build -- --target universal-apple-darwin
```

---

## Cross-Compilation Gotchas

### General Rules

1. **Native compilation is always preferred.** Use CI with platform-specific runners.
2. Cross-compiling Tauri is difficult due to system webview dependencies.
3. For CI, use GitHub Actions with `macos-latest`, `ubuntu-latest`, `windows-latest`.

### Linux → Windows

Not supported directly. Use:
- GitHub Actions with `windows-latest`
- Windows VM
- Docker with Wine (fragile, not recommended)

### Linux → macOS

Not supported. Use:
- GitHub Actions with `macos-latest`
- macOS VM (Parallels, etc.)

### macOS Intel → ARM (Apple Silicon)

```bash
rustup target add aarch64-apple-darwin
npm run tauri build -- --target aarch64-apple-darwin
```

For universal binary:
```bash
npm run tauri build -- --target universal-apple-darwin
```

### Docker Builds for Linux

```dockerfile
FROM rust:1.77-slim-bookworm

RUN apt-get update && apt-get install -y \
    libwebkit2gtk-4.1-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    patchelf \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

WORKDIR /app
COPY . .
RUN npm install
RUN npm run tauri build
```

---

## Debugging

### Frontend DevTools

In development mode, DevTools are automatically available. In production, enable them:

```json
{
  "app": {
    "windows": [
      {
        "label": "main",
        "devtools": true
      }
    ]
  }
}
```

Or open programmatically:
```rust
#[cfg(debug_assertions)]
{
    if let Some(window) = app.get_webview_window("main") {
        window.open_devtools();
    }
}
```

**Keyboard shortcuts:**
- macOS: `Cmd+Option+I`
- Windows/Linux: `Ctrl+Shift+I` or `F12`

### Rust Logging

Use `tauri-plugin-log` for structured logging:

```bash
cargo add tauri-plugin-log
npm install @tauri-apps/plugin-log
```

```rust
use tauri_plugin_log::{Target, TargetKind};

fn main() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::new()
                .targets([
                    Target::new(TargetKind::Stdout),
                    Target::new(TargetKind::LogDir { file_name: None }),
                    Target::new(TargetKind::Webview),
                ])
                .level(log::LevelFilter::Debug)
                .build(),
        )
        .run(tauri::generate_context!())
        .unwrap();
}
```

Use standard Rust logging macros:
```rust
use log::{info, warn, error, debug, trace};

#[tauri::command]
fn process_data(data: String) -> Result<String, String> {
    info!("Processing data: {} bytes", data.len());
    debug!("Data content: {:?}", &data[..50.min(data.len())]);

    match do_processing(&data) {
        Ok(result) => {
            info!("Processing complete");
            Ok(result)
        }
        Err(e) => {
            error!("Processing failed: {}", e);
            Err(e.to_string())
        }
    }
}
```

**View logs from frontend:**
```typescript
import { attachConsole, info, error } from '@tauri-apps/plugin-log';

// Forward frontend console to Rust logger
const detach = await attachConsole();

info('Frontend initialized');
error('Something went wrong');
```

### IPC Debugging

Debug command invocations and events:

```rust
// Wrap commands with timing/logging
#[tauri::command]
async fn debug_invoke(name: String, payload: serde_json::Value) -> Result<serde_json::Value, String> {
    let start = std::time::Instant::now();
    log::debug!("Command '{}' called with: {:?}", name, payload);

    // ... actual logic ...

    log::debug!("Command '{}' completed in {:?}", name, start.elapsed());
    Ok(serde_json::json!({"status": "ok"}))
}
```

**Environment variables for verbose output:**
```bash
RUST_LOG=debug npm run tauri dev          # All debug logs
RUST_LOG=tauri=trace npm run tauri dev    # Tauri framework trace logs
RUST_BACKTRACE=1 npm run tauri dev        # Full backtraces on panic
```

---

## Performance Optimization

### Startup Time

1. **Lazy-load plugins** — only initialize what you need at startup:
```rust
.setup(|app| {
    // Defer heavy initialization
    let handle = app.handle().clone();
    tauri::async_runtime::spawn(async move {
        // Heavy init here (DB connections, indexing, etc.)
        init_database(&handle).await;
    });
    Ok(())
})
```

2. **Minimize frontend bundle** — use code splitting and lazy routes.

3. **Use splash screen** while loading:
```json
{
  "app": {
    "windows": [
      { "label": "splashscreen", "url": "splashscreen.html", "width": 400, "height": 300, "decorations": false, "resizable": false },
      { "label": "main", "url": "index.html", "visible": false }
    ]
  }
}
```

```rust
#[tauri::command]
async fn close_splashscreen(app: tauri::AppHandle) {
    if let Some(splash) = app.get_webview_window("splashscreen") {
        splash.close().unwrap();
    }
    if let Some(main) = app.get_webview_window("main") {
        main.show().unwrap();
    }
}
```

### Memory Usage

1. **Drop large objects** after use — don't hold file contents in state.
2. **Stream large files** instead of loading fully into memory.
3. **Use `Arc` wisely** — avoid cloning large data structures.

### IPC Performance

1. **Batch operations** — combine multiple related commands into one.
2. **Use events for one-way data** — events are lighter than commands.
3. **Avoid large payloads** — serialize/compress large data:
```rust
#[tauri::command]
fn get_large_data() -> Result<Vec<u8>, String> {
    let data = load_data()?;
    // Compress before sending over IPC
    let compressed = zstd::encode_all(&data[..], 3).map_err(|e| e.to_string())?;
    Ok(compressed)
}
```

### Rendering Performance

- Avoid heavy CSS animations in the webview.
- Use `will-change` CSS property sparingly.
- Prefer `requestAnimationFrame` over `setInterval` for animations.
- Use virtual scrolling for long lists (react-window, tanstack-virtual).

---

## Bundle Size Reduction

### Rust Optimizations

**Cargo.toml — profile settings:**
```toml
[profile.release]
strip = true        # Strip debug symbols
lto = true          # Link-time optimization
codegen-units = 1   # Better optimization, slower compile
opt-level = "s"     # Optimize for size ("z" for even smaller)
panic = "abort"     # Smaller binary, no unwinding
```

### Frontend Optimizations

1. **Tree-shaking** — ensure your bundler eliminates unused code.
2. **Compress assets** — use WebP/AVIF for images, WOFF2 for fonts.
3. **Audit dependencies:**
```bash
# Check bundle size
npx vite-bundle-visualizer
# Or for webpack
npx webpack-bundle-analyzer
```

### Exclude Unnecessary Targets

```json
{
  "bundle": {
    "targets": ["deb", "appimage"]
  }
}
```

Only build the installers you need — skip `.dmg`, `.msi`, etc. for testing.

### Expected Sizes

| Component | Approximate Size |
|-----------|-----------------|
| Tauri Rust core (release, stripped) | ~2–5 MB |
| React frontend (typical) | ~200–500 KB |
| Total app bundle (minimal) | ~3–8 MB |
| Electron equivalent | ~80–150 MB |

---

## Platform-Specific Quirks

### macOS Signing and Notarization

**Required for distribution** outside the Mac App Store.

1. **Get certificates:** Apple Developer Program ($99/year).
2. **Environment variables:**
```bash
export APPLE_CERTIFICATE="base64-encoded-.p12"
export APPLE_CERTIFICATE_PASSWORD="password"
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"
export APPLE_ID="your@email.com"
export APPLE_PASSWORD="app-specific-password"
export APPLE_TEAM_ID="ABCDE12345"
```

3. **tauri.conf.json:**
```json
{
  "bundle": {
    "macOS": {
      "signingIdentity": "Developer ID Application: Your Name (TEAM_ID)",
      "entitlements": "./Entitlements.plist"
    }
  }
}
```

4. **Entitlements.plist:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
</dict>
</plist>
```

**Common errors:**
- `"YourApp" is damaged and can't be opened` → App not signed/notarized, or quarantine flag set. Fix: `xattr -cr /path/to/YourApp.app`.
- `errSecInternalComponent` → Keychain access issue. Unlock keychain: `security unlock-keychain -p password login.keychain`.
- Notarization timeout → Apple's servers are slow; retry after a few minutes.

### Windows Installer

**NSIS vs MSI vs WiX:**

| Format | Pros | Cons |
|--------|------|------|
| NSIS | Small, customizable, fast | Less "enterprise" |
| MSI/WiX | Enterprise standard, Group Policy | Larger, complex |

**tauri.conf.json:**
```json
{
  "bundle": {
    "targets": ["nsis"],
    "windows": {
      "certificateThumbprint": "CERT_HASH",
      "digestAlgorithm": "sha256",
      "timestampUrl": "http://timestamp.digicert.com",
      "nsis": {
        "installerIcon": "icons/icon.ico",
        "displayLanguageSelector": true,
        "languages": ["English", "German", "French"],
        "installMode": "both"
      }
    }
  }
}
```

**Common issues:**
- SmartScreen warning → Sign with an EV code signing certificate.
- Missing MSVC runtime → Bundle `vcruntime140.dll` or install Visual C++ Redistributable.
- PATH too long → Use short install paths; default to `%LOCALAPPDATA%\Programs`.

### Linux Packaging

**AppImage vs .deb vs .rpm:**

| Format | Distro | Notes |
|--------|--------|-------|
| AppImage | Universal | Single file, no install needed |
| .deb | Debian/Ubuntu | Proper package manager integration |
| .rpm | Fedora/RHEL | Use `alien` to convert from .deb if needed |
| Flatpak | Universal | Sandboxed; use `tauri-plugin-flatpak` considerations |

**AppImage issues:**
- Not executable after download → `chmod +x ./MyApp.AppImage`
- FUSE not available → `./MyApp.AppImage --appimage-extract-and-run`
- No desktop integration → Use `AppImageLauncher` or manual `.desktop` file.

**.deb configuration:**
```json
{
  "bundle": {
    "targets": ["deb"],
    "linux": {
      "deb": {
        "depends": ["libwebkit2gtk-4.1-0", "libgtk-3-0"],
        "section": "utils",
        "priority": "optional"
      }
    }
  }
}
```

---

## Webview Compatibility

### Engine Versions

| Platform | Engine | Based On | Auto-Updated? |
|----------|--------|----------|---------------|
| Windows | WebView2 | Chromium Edge | Yes (Evergreen) |
| macOS | WKWebView | Safari/WebKit | With OS updates |
| Linux | WebKitGTK | WebKit | With system packages |
| iOS | WKWebView | Safari/WebKit | With OS updates |
| Android | Android WebView | Chromium | Via Play Store |

### CSS/JS Compatibility Concerns

1. **WebKitGTK on Linux** is often outdated — avoid bleeding-edge CSS/JS features.
2. Check https://caniuse.com/ for WebKit support.
3. Use polyfills or transpilation targets:

```typescript
// vite.config.ts
export default {
    build: {
        target: ['es2021', 'chrome100', 'safari15'],
    },
};
```

### Known Quirks

- **`position: sticky`** — may not work in some WebKitGTK versions.
- **`backdrop-filter`** — not supported on older Linux WebKitGTK.
- **Web Animations API** — partial support in older WebKit; use CSS transitions as fallback.
- **`<dialog>` element** — use polyfill for Linux.
- **`fetch` with streaming** — ReadableStream may not be available; use `XMLHttpRequest` as fallback.

---

## Plugin Issues

### Plugin Version Mismatch

```
error: tauri-plugin-fs v2.1.0 requires tauri ^2.1.0, but tauri 2.0.5 is installed
```

**Fix:** Align plugin versions with your Tauri version:
```bash
cargo update
# Or pin specific versions in Cargo.toml
```

### Plugin Not Found at Runtime

```
Error: plugin `fs` not found
```

**Fix:** Ensure the plugin is:
1. Added to `Cargo.toml`: `tauri-plugin-fs = "2"`
2. Registered in Rust: `.plugin(tauri_plugin_fs::init())`
3. Frontend package installed: `npm install @tauri-apps/plugin-fs`
4. Capability granted: `"fs:default"` in capabilities file

### Plugin Permission Denied

```
Error: Permission fs:allow-read-text-file not granted
```

**Fix:** Add the permission to your capability file:
```json
{
  "identifier": "main",
  "windows": ["main"],
  "permissions": ["fs:default", "fs:allow-read-text-file"]
}
```

---

## Security and Capabilities

### "Permission Not Allowed" Errors

When a command or plugin feature fails with permission errors:

1. Check `src-tauri/capabilities/` for the correct permissions.
2. Run `npm run tauri dev` and check console for the exact permission identifier needed.
3. Use the generated schema for autocomplete:
```json
{ "$schema": "../gen/schemas/desktop-schema.json" }
```

### CSP Violations

```
Refused to load the script 'https://cdn.example.com/lib.js' because it violates the Content Security Policy
```

**Fix:** Update CSP in `tauri.conf.json`:
```json
{
  "app": {
    "security": {
      "csp": "default-src 'self'; script-src 'self' https://cdn.example.com; style-src 'self' 'unsafe-inline'; connect-src ipc: http://ipc.localhost https://api.example.com"
    }
  }
}
```

**Tip:** Never use `"csp": null` in production. Start restrictive and add only what's needed.

### Debugging Capability Resolution

```bash
# Generate the full resolved capability schema
npm run tauri build -- --verbose 2>&1 | grep -i capability
```

Check `src-tauri/gen/schemas/` for the generated capability schemas — they show all available permissions for your installed plugins.
