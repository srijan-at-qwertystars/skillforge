# Flutter Troubleshooting Guide

## Table of Contents

- [Build Failures](#build-failures)
  - [Gradle Issues (Android)](#gradle-issues-android)
  - [CocoaPods Issues (iOS)](#cocoapods-issues-ios)
  - [Xcode Build Failures](#xcode-build-failures)
- [Hot Reload / Hot Restart Problems](#hot-reload--hot-restart-problems)
- [Widget Overflow Errors](#widget-overflow-errors)
- [Platform Channel Crashes](#platform-channel-crashes)
- [iOS Signing Issues](#ios-signing-issues)
- [Android Manifest & Permissions](#android-manifest--permissions)
- [Pub Dependency Conflicts](#pub-dependency-conflicts)
- [Performance Jank](#performance-jank)
  - [Shader Compilation Jank](#shader-compilation-jank)
  - [Unnecessary Rebuilds](#unnecessary-rebuilds)
  - [Heavy Computations on Main Thread](#heavy-computations-on-main-thread)
- [Memory Leaks](#memory-leaks)
  - [Stream and Controller Leaks](#stream-and-controller-leaks)
  - [Image and Cache Leaks](#image-and-cache-leaks)
- [Common Runtime Errors](#common-runtime-errors)
- [Web-Specific Issues](#web-specific-issues)
- [Desktop-Specific Issues](#desktop-specific-issues)
- [Diagnostic Commands Cheat Sheet](#diagnostic-commands-cheat-sheet)

---

## Build Failures

### Gradle Issues (Android)

**Problem: `Could not determine the dependencies of task ':app:compileDebugJavaWithJavac'`**

Cause: Gradle/AGP version mismatch or corrupted cache.

```bash
# Fix 1: Clean and rebuild
cd android && ./gradlew clean && cd ..
flutter clean
flutter pub get
flutter build apk

# Fix 2: Update Gradle wrapper
# In android/gradle/wrapper/gradle-wrapper.properties:
distributionUrl=https\://services.gradle.org/distributions/gradle-8.4-all.zip

# In android/build.gradle or android/settings.gradle:
# classpath 'com.android.tools.build:gradle:8.2.0'
```

**Problem: `Minimum supported Gradle version is X.Y`**

```bash
# Update android/gradle/wrapper/gradle-wrapper.properties
distributionUrl=https\://services.gradle.org/distributions/gradle-8.4-all.zip
```

**Problem: `NDK not configured` or NDK version mismatch**

```bash
# In android/app/build.gradle:
android {
    ndkVersion = "25.2.9519653"  // Match your installed NDK
}

# Or install via SDK Manager:
sdkmanager --install "ndk;25.2.9519653"
```

**Problem: `Execution failed for task ':app:mergeDebugResources'`**

Cause: Invalid resource files (wrong naming, corrupt PNGs).

```bash
# Check for invalid resource filenames (must be lowercase, no special chars)
find android/app/src/main/res -name '*[A-Z]*' -o -name '*-*'

# Clean build cache
cd android && ./gradlew clean && cd ..
flutter clean && flutter pub get
```

**Problem: `java.lang.OutOfMemoryError` during build**

```groovy
// In android/gradle.properties:
org.gradle.jvmargs=-Xmx4096m -XX:+HeapDumpOnOutOfMemoryError
org.gradle.daemon=true
org.gradle.parallel=true
```

**Problem: `compileSdkVersion` too low for a dependency**

```groovy
// In android/app/build.gradle:
android {
    compileSdk = 34  // Match highest requirement
    defaultConfig {
        minSdk = 21
        targetSdk = 34
    }
}
```

**Problem: Kotlin version conflicts**

```groovy
// In android/settings.gradle or android/build.gradle:
plugins {
    id "org.jetbrains.kotlin.android" version "1.9.22" apply false
}
```

### CocoaPods Issues (iOS)

**Problem: `CocoaPods not installed` or version mismatch**

```bash
# Install/update CocoaPods
sudo gem install cocoapods
# Or with Homebrew:
brew install cocoapods

# Verify
pod --version
```

**Problem: `CDN: trunk URL couldn't be downloaded` or pod install fails**

```bash
cd ios
pod deintegrate
pod cache clean --all
rm -rf Pods Podfile.lock
cd ..
flutter clean
flutter pub get
cd ios && pod install --repo-update && cd ..
```

**Problem: `The sandbox is not in sync with the Podfile.lock`**

```bash
cd ios
pod install
# If that fails:
pod deintegrate && pod install
```

**Problem: Architecture issues (arm64 simulator on Apple Silicon)**

```ruby
# In ios/Podfile:
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
```

**Problem: `Multiple commands produce` error**

```bash
# In Xcode: File > Workspace Settings > Build System > New Build System
# Or clean derived data:
rm -rf ~/Library/Developer/Xcode/DerivedData/*
cd ios && pod deintegrate && pod install && cd ..
```

### Xcode Build Failures

**Problem: `No such module 'Flutter'`**

```bash
flutter clean
rm -rf ios/Pods ios/Podfile.lock ios/.symlinks
flutter pub get
cd ios && pod install && cd ..
```

**Problem: Xcode version too old**

```bash
flutter doctor  # Shows required Xcode version
xcode-select --install  # Install command line tools
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**Problem: `The linked framework 'Pods_Runner.framework' is missing`**

```bash
# Open ios/Runner.xcworkspace (not .xcodeproj)
# In Xcode: Product > Clean Build Folder (Cmd+Shift+K)
cd ios && pod install && cd ..
```

**Problem: Provisioning profile / certificate errors**

See [iOS Signing Issues](#ios-signing-issues) section below.

---

## Hot Reload / Hot Restart Problems

**Hot reload not working:**

1. **Changed `main()` or global variables** → requires hot restart (`Shift+R`)
2. **Changed `initState()` logic** → requires hot restart
3. **Changed enum values or generic types** → requires hot restart
4. **Changed native code** → requires full rebuild (`flutter run`)
5. **Using `const` constructors with changed values** → hot restart
6. **Build errors** → fix errors first, then hot reload works again

**Hot reload slow:**
```bash
# Check for large generated files being watched
# Exclude generated files from analysis:
# In analysis_options.yaml:
analyzer:
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"
    - "**/*.gr.dart"
```

**Hot restart loses state:**
That's expected — hot restart reinitializes the entire app. Use state persistence
(SharedPreferences, Hive) for development convenience, or use `RestorableProperty`.

---

## Widget Overflow Errors

**Problem: `A RenderFlex overflowed by X pixels on the bottom/right`**

The yellow-black striped overflow indicator.

```dart
// Fix 1: Wrap in SingleChildScrollView
SingleChildScrollView(
  child: Column(children: [...]),
)

// Fix 2: Use Flexible/Expanded
Column(
  children: [
    const Text('Header'),
    Expanded(  // Takes remaining space
      child: ListView(...),
    ),
  ],
)

// Fix 3: Use overflow-aware widgets
Text(
  'Long text...',
  overflow: TextOverflow.ellipsis,
  maxLines: 2,
)

// Fix 4: Constrain dimensions
ConstrainedBox(
  constraints: const BoxConstraints(maxHeight: 200),
  child: ListView(...),
)
```

**Problem: `Unbounded height/width` in Row/Column/ListView**

```dart
// BAD: ListView inside Column without constraints
Column(children: [ListView()])  // CRASH

// GOOD: Constrain the ListView
Column(children: [
  Expanded(child: ListView(...)),
])

// GOOD: Use shrinkWrap (for small lists only — performance cost)
Column(children: [
  ListView(shrinkWrap: true, physics: const NeverScrollableScrollPhysics()),
])
```

**Problem: `BoxConstraints forces an infinite height/width`**

Usually caused by nesting scrollable widgets:
```dart
// BAD: ListView inside another ListView
ListView(children: [ListView()])

// GOOD: Use ShrinkWrap or nested ScrollView with custom physics
ListView(
  children: [
    ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
    ),
  ],
)

// BETTER: Use CustomScrollView with slivers
CustomScrollView(
  slivers: [
    SliverList(...),
    SliverList(...),
  ],
)
```

---

## Platform Channel Crashes

**Problem: `MissingPluginException`**

```bash
# The native side hasn't registered the channel handler
# Fix: Ensure plugin is properly added
flutter clean
flutter pub get
# For iOS:
cd ios && pod install && cd ..
# Rebuild completely:
flutter run
```

**Problem: Platform channel called on wrong thread**

```dart
// Always call platform channels from the main (UI) thread
// If calling from an isolate, use ports to communicate back to main isolate
```

**Problem: Type mismatch between Dart and native**

```dart
// Dart types → Platform channel types:
// int → Int/Long (Android), NSNumber (iOS)
// double → Double (Android), NSNumber (iOS)
// String → String (Android), NSString (iOS)
// List → ArrayList (Android), NSArray (iOS)
// Map → HashMap (Android), NSDictionary (iOS)
// Uint8List → byte[] (Android), FlutterStandardTypedData (iOS)

// Always null-check return values:
final result = await channel.invokeMethod<int>('method');
if (result == null) { /* handle */ }
```

**Problem: Channel not found after hot restart**

Platform channels are registered during native app startup. Hot restart only restarts
the Dart side. If your channel registration is lazy, it may not be re-registered.
Solution: ensure channels are registered in `Application.onCreate` (Android) or
`AppDelegate` (iOS), not in response to Dart calls.

---

## iOS Signing Issues

**Problem: `No signing certificate "iOS Development" found`**

```bash
# 1. Open Xcode: Runner.xcworkspace
# 2. Select Runner target > Signing & Capabilities
# 3. Check "Automatically manage signing"
# 4. Select your team
# 5. If no team: Xcode > Settings > Accounts > Add Apple ID
```

**Problem: `Provisioning profile doesn't include signing certificate`**

```bash
# Reset signing:
# Xcode > Runner > Signing & Capabilities
# Uncheck then re-check "Automatically manage signing"
# Or manually:
security find-identity -v -p codesigning  # List certificates
```

**Problem: `The certificate chain did not verify` or expired certificate**

```bash
# 1. Keychain Access > My Certificates > Delete expired certificates
# 2. Xcode > Settings > Accounts > Manage Certificates > + (create new)
# 3. Download new profiles: Xcode > Product > Build
```

**Problem: Can't deploy to physical device**

1. Trust the developer on device: Settings > General > Device Management
2. Ensure device UDID is in provisioning profile
3. For free accounts: limited to 3 apps, 7-day re-signing cycle

**CI/CD signing:**
```bash
# Use match (Fastlane) or manual certificate management
# GitHub Actions:
# 1. Export .p12 certificate and provisioning profile
# 2. Store as GitHub secrets (base64 encoded)
# 3. Install in CI keychain before build
```

---

## Android Manifest & Permissions

**Problem: Permission denied at runtime**

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<!-- For Android 13+, add granular permissions -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

```dart
// Runtime permission request (using permission_handler package):
final status = await Permission.camera.request();
if (status.isGranted) {
  // Use camera
} else if (status.isPermanentlyDenied) {
  openAppSettings();
}
```

**Problem: `Cleartext HTTP traffic not permitted`**

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<application
    android:usesCleartextTraffic="true"  <!-- Development only! -->
    ...>
```

Better solution — use network security config:
```xml
<!-- android/app/src/main/res/xml/network_security_config.xml -->
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">10.0.2.2</domain>
    </domain-config>
</network-security-config>
```

**Problem: Missing `INTERNET` permission**

Flutter apps need internet permission explicitly:
```xml
<!-- In android/app/src/main/AndroidManifest.xml -->
<uses-permission android:name="android.permission.INTERNET"/>
```

Note: Debug builds include this by default, but release builds do not.

---

## Pub Dependency Conflicts

**Problem: `version solving failed`**

```bash
# See dependency tree:
flutter pub deps

# See why a package version was chosen:
flutter pub deps --style=compact

# Force resolution with latest compatible versions:
flutter pub upgrade --major-versions

# If still stuck, check overrides:
# In pubspec.yaml:
dependency_overrides:
  some_package: ^2.0.0  # Use cautiously, can cause runtime errors
```

**Problem: `The current Dart SDK version is X, requires Y`**

```bash
# Update Flutter (includes Dart):
flutter upgrade

# Or pin SDK constraint in pubspec.yaml:
environment:
  sdk: '>=3.2.0 <4.0.0'
```

**Problem: Transitive dependency conflicts**

```bash
# Identify conflicting packages:
flutter pub deps --style=list | grep conflicting_package

# Strategy 1: Update the parent packages
flutter pub upgrade parent_package_a parent_package_b

# Strategy 2: Use dependency_overrides (last resort)
dependency_overrides:
  conflicting_package: ^3.1.0
```

**Problem: `pub get` hangs or times out**

```bash
# Try with verbose logging:
flutter pub get --verbose

# Clear pub cache:
flutter pub cache clean
flutter pub get

# Check proxy/firewall settings:
export PUB_HOSTED_URL=https://pub.dev
export FLUTTER_STORAGE_BASE_URL=https://storage.googleapis.com
```

---

## Performance Jank

### Shader Compilation Jank

First-time shader compilation causes frame drops. Impeller (default on iOS/Android)
eliminates most shader jank, but some cases remain.

```bash
# Pre-warm shaders using SkSL warmup (Skia only, not needed for Impeller):
flutter run --profile --cache-sksl --purge-persistent-cache
# Perform all animations in the app, then press 'M' to export
flutter build apk --bundle-sksl-path=flutter_01.sksl.json

# Check if Impeller is active:
flutter run --verbose 2>&1 | grep -i impeller
```

**Diagnosing jank:**
```bash
# Run in profile mode (never benchmark debug mode):
flutter run --profile

# Open DevTools timeline:
# 1. Press 'v' in terminal to open DevTools
# 2. Go to Performance tab
# 3. Enable "Track Widget Builds" and "Track Paints"
# 4. Record, perform janky action, stop recording
# 5. Look for frames exceeding 16ms (60fps) / 8ms (120fps)
```

### Unnecessary Rebuilds

```dart
// BAD: Entire subtree rebuilds when any state changes
class MyWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeModel>(); // rebuilds everything
    return Column(
      children: [
        ExpensiveWidget(),       // rebuilds unnecessarily
        Text(theme.title),       // only this needs theme
        AnotherExpensiveWidget(), // rebuilds unnecessarily
      ],
    );
  }
}

// GOOD: Isolate rebuilds with Consumer/select
class MyWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const ExpensiveWidget(),  // const = never rebuilds
        Consumer<ThemeModel>(
          builder: (_, theme, __) => Text(theme.title),
        ),
        const AnotherExpensiveWidget(),
      ],
    );
  }
}
```

**Rebuild detection:**
```dart
// Add to widget for debugging:
@override
Widget build(BuildContext context) {
  debugPrint('Building ${widget.runtimeType}');
  // ...
}

// Use DevTools > Widget Inspector > Track Rebuilds
```

### Heavy Computations on Main Thread

```dart
// BAD: JSON parsing on main thread
final data = jsonDecode(hugeJsonString); // blocks UI

// GOOD: Use Isolate.run (Dart 2.19+)
final data = await Isolate.run(() => jsonDecode(hugeJsonString));

// GOOD: Use compute for older Dart
final data = await compute(jsonDecode, hugeJsonString);

// For ongoing heavy work, use a long-lived isolate:
final receivePort = ReceivePort();
await Isolate.spawn(heavyWorker, receivePort.sendPort);
```

---

## Memory Leaks

### Stream and Controller Leaks

```dart
// BAD: Stream subscription never cancelled
class _MyState extends State<MyWidget> {
  @override
  void initState() {
    super.initState();
    myStream.listen((data) { /* handle */ }); // LEAK!
  }
}

// GOOD: Cancel subscription in dispose
class _MyState extends State<MyWidget> {
  late final StreamSubscription _sub;

  @override
  void initState() {
    super.initState();
    _sub = myStream.listen((data) { /* handle */ });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

// BAD: StreamController never closed
class MyService {
  final _controller = StreamController<int>(); // LEAK if not closed!

  void dispose() {
    _controller.close(); // Always close controllers
  }
}
```

**Common leakers:**
- `StreamSubscription` — always cancel in `dispose()`
- `StreamController` — always close when done
- `AnimationController` — always dispose
- `TextEditingController` — always dispose
- `FocusNode` — always dispose
- `ScrollController` — always dispose
- `Timer` / `Timer.periodic` — always cancel

### Image and Cache Leaks

```dart
// Clear image cache if memory is tight:
imageCache.clear();
imageCache.clearLiveImages();

// Limit cache size:
imageCache.maximumSize = 50;       // max entries
imageCache.maximumSizeBytes = 50 << 20; // 50 MB

// Use ResizeImage to avoid decoding full-resolution images:
Image(
  image: ResizeImage(
    const AssetImage('assets/large_photo.jpg'),
    width: 300,
  ),
)
```

**Detecting leaks:**
```bash
# Use DevTools Memory tab:
# 1. Open DevTools > Memory
# 2. Take heap snapshot before action
# 3. Perform action (navigate away and back)
# 4. Take heap snapshot after
# 5. Compare — look for objects that should have been GC'd
# 6. Check retaining paths to find the leak source
```

---

## Common Runtime Errors

**`setState() called after dispose()`**

```dart
// Cause: Async operation completes after widget is unmounted
// Fix: Check mounted before setState
Future<void> loadData() async {
  final data = await api.fetch();
  if (mounted) {  // Safe guard
    setState(() => _data = data);
  }
}
```

**`Looking up a deactivated widget's ancestor`**

```dart
// Cause: Using BuildContext after the widget is removed from tree
// Fix: Capture context-dependent values before async gaps
void onTap() {
  final navigator = Navigator.of(context);  // Capture BEFORE async
  final messenger = ScaffoldMessenger.of(context);
  doSomethingAsync().then((_) {
    navigator.pop();  // Use captured reference
    messenger.showSnackBar(const SnackBar(content: Text('Done')));
  });
}
```

**`Null check operator used on a null value`**

```dart
// Cause: Using ! on a nullable value that is null
// Fix: Use null-aware operators or handle null cases
final name = user?.name ?? 'Unknown';  // Instead of user!.name
```

**`type 'Null' is not a subtype of type 'String'`**

```dart
// Cause: API returned null where non-null expected
// Fix: Make fields nullable in DTOs and handle
@JsonSerializable()
class UserDto {
  final String? name;  // Nullable — handle at domain layer
  final String email;  // Required — API contract guarantees non-null
}
```

---

## Web-Specific Issues

**Problem: CORS errors**

```dart
// This is a server-side issue — add CORS headers on your API
// For development, use a proxy:
// In web/index.html or use --web-browser-flag:
// flutter run -d chrome --web-browser-flag="--disable-web-security"
// NEVER use this in production

// Better: Configure a reverse proxy in your dev setup
```

**Problem: Large initial bundle size**

```bash
# Analyze bundle:
flutter build web --web-renderer canvaskit --source-maps
# Use deferred loading:
# import 'heavy_feature.dart' deferred as heavy;
# await heavy.loadLibrary();
```

**Problem: Fonts not loading**

```yaml
# Ensure fonts are in pubspec.yaml:
flutter:
  fonts:
    - family: CustomFont
      fonts:
        - asset: assets/fonts/CustomFont-Regular.ttf
```

---

## Desktop-Specific Issues

**Problem: Window size not configurable**

```dart
// Use window_manager package:
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(800, 600),
    center: true,
    title: 'My App',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const MyApp());
}
```

**Problem: macOS sandbox blocks network**

```xml
<!-- macos/Runner/DebugProfile.entitlements AND Release.entitlements -->
<key>com.apple.security.network.client</key>
<true/>
```

**Problem: Linux build fails — missing dependencies**

```bash
sudo apt-get install clang cmake git ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev
```

---

## Diagnostic Commands Cheat Sheet

```bash
# Environment check
flutter doctor -v                    # Full environment diagnostic
flutter --version                    # Flutter/Dart versions

# Dependency management
flutter pub get                      # Resolve dependencies
flutter pub upgrade                  # Upgrade to latest compatible
flutter pub outdated                 # Show outdatable packages
flutter pub deps                     # Dependency tree
flutter pub cache clean              # Clear pub cache

# Build & clean
flutter clean                        # Delete build artifacts
flutter build apk --analyze-size     # APK size analysis
flutter build ios --analyze-size     # IPA size analysis
flutter build web --source-maps      # Web with source maps

# Debugging
flutter run --verbose                # Verbose output
flutter logs                         # Stream device logs
flutter attach                       # Attach to running app
flutter screenshot                   # Capture device screenshot

# Testing
flutter test --coverage              # Run tests with coverage
flutter test --update-goldens        # Update golden files
flutter test --reporter=expanded     # Verbose test output

# Performance
flutter run --profile                # Profile mode
flutter run --release                # Release mode
flutter analyze                      # Static analysis
dart fix --apply                     # Auto-fix lint issues
```
