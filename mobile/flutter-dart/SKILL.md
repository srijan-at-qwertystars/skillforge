---
name: flutter-dart
description: >
  Expert Flutter and Dart development skill. Covers widget architecture, state management
  (Riverpod, Bloc, Provider), GoRouter navigation, Dart 3 language features (records, patterns,
  sealed classes, class modifiers), Material 3 theming, Impeller renderer, platform channels,
  networking (dio, http, Retrofit), local storage (Hive, Isar, drift), testing (widget, integration,
  golden tests), CI/CD pipelines, performance profiling with DevTools, responsive design, clean
  architecture, and multi-platform deployment (mobile, web, desktop). Guides production-grade
  Flutter app development with modern idioms and best practices.
triggers:
  positive:
    - Flutter
    - Dart
    - Flutter widget
    - StatelessWidget
    - StatefulWidget
    - Riverpod
    - Bloc
    - Cubit
    - Provider state management
    - GoRouter
    - Flutter navigation
    - Flutter testing
    - widget test
    - golden test
    - platform channel
    - MethodChannel
    - Flutter web
    - Flutter desktop
    - Material 3
    - Impeller
    - flutter build
    - pubspec.yaml
    - dart pub
    - flutter_lints
    - freezed
    - build_runner
    - flutter_bloc
    - go_router
    - dio Flutter
    - Hive Flutter
    - Isar database
    - drift database
    - Flutter DevTools
    - Flutter performance
    - Flutter CI CD
    - Codemagic
    - Fastlane Flutter
    - InheritedWidget
    - Flutter responsive
    - Flutter theming
    - Flutter clean architecture
  negative:
    - React Native
    - Kotlin Multiplatform
    - KMM
    - Swift
    - SwiftUI
    - Jetpack Compose
    - Xamarin
    - MAUI
    - Ionic
    - Cordova
    - NativeScript
    - general mobile without Flutter context
---

# Flutter & Dart Development Skill

## Dart 3.x Language Essentials

Use Dart 3.x features throughout all code. Never write pre-Dart-3 patterns.

### Records
Return multiple values without wrapper classes. Records have value equality.
```dart
(int, String) fetchUser() => (1, 'Alice');
({int id, String name}) fetchNamed() => (id: 1, name: 'Alice');
// Destructure:
final (id, name) = fetchUser();
final (:id, :name) = fetchNamed();
```

### Patterns and Pattern Matching
Use `switch` expressions and `if-case` for exhaustive matching. Prefer expressions over statements.
```dart
String describe(Shape shape) => switch (shape) {
  Circle(:final radius) => 'Circle r=$radius',
  Rectangle(:final w, :final h) => 'Rect ${w}x$h',
};
if (response case Ok(:final data)) { use(data); }
```

### Sealed Classes
Model finite state hierarchies. The compiler enforces exhaustive switch coverage.
```dart
sealed class AuthState {}
class Authenticated extends AuthState { final User user; Authenticated(this.user); }
class Unauthenticated extends AuthState {}
class Loading extends AuthState {}
```

### Class Modifiers
- `base` — subclass only, no implements outside library
- `interface` — implement only, no extends outside library
- `final` — no subclass or implement outside library
- `sealed` — exhaustive subtypes, same library only
- `mixin class` — usable as both class and mixin

Always apply the most restrictive modifier that satisfies requirements.

## Project Structure — Clean Architecture

Enforce feature-first organization with strict layer separation:
```
lib/
  core/             # shared utilities, constants, extensions, theme
    theme/
    utils/
    extensions/
  features/
    auth/
      data/          # repositories impl, data sources, DTOs
      domain/        # entities, repository interfaces, use cases
      presentation/  # screens, widgets, controllers/blocs/providers
    home/
      data/
      domain/
      presentation/
  routing/           # GoRouter config
  app.dart           # MaterialApp.router root
  main.dart          # bootstrap, DI setup
test/
  features/
    auth/
      data/
      domain/
      presentation/
  widget/            # shared widget tests
  golden/            # golden test files and references
integration_test/
```

Dependency rule: presentation → domain ← data. Domain never imports Flutter.

## Widget Architecture

### StatelessWidget
Use for pure UI with no mutable state. Prefer `const` constructors.
```dart
class PriceTag extends StatelessWidget {
  const PriceTag({super.key, required this.amount});
  final double amount;
  @override
  Widget build(BuildContext context) => Text('\$${amount.toStringAsFixed(2)}');
}
```

### StatefulWidget
Use only when local mutable state is required (animations, text controllers, focus nodes).
Dispose controllers in `dispose()`. Use `late final` for controllers initialized in `initState`.
```dart
class SearchBar extends StatefulWidget {
  const SearchBar({super.key});
  @override
  State<SearchBar> createState() => _SearchBarState();
}
class _SearchBarState extends State<SearchBar> {
  late final TextEditingController _controller;
  @override
  void initState() { super.initState(); _controller = TextEditingController(); }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => TextField(controller: _controller);
}
```

### InheritedWidget
Use for propagating data down the tree without rebuilding. Prefer Riverpod/Provider for most cases.
Only use InheritedWidget directly for extremely performance-sensitive subtree data.

### Key Widget Best Practices
- Prefer `const` constructors everywhere possible — reduces rebuilds.
- Extract widget subtrees into separate classes rather than methods — enables framework optimization.
- Use `Key` (ValueKey, ObjectKey) in lists to preserve state during reordering.
- Prefer `SliverList.builder`/`ListView.builder` for long lists — lazy construction.
- Avoid deep nesting: extract widgets at 3-4 levels of indentation.

## State Management

### Riverpod (Recommended Default)
Use Riverpod for new projects. Prefer code-generation style with `@riverpod` annotations.
```dart
@riverpod
Future<List<Product>> products(Ref ref) async {
  final repo = ref.watch(productRepositoryProvider);
  return repo.fetchAll();
}

@riverpod
class CartNotifier extends _$CartNotifier {
  @override
  Cart build() => const Cart.empty();
  void addItem(Product p) => state = state.add(p);
}
```
- Use `ref.watch` in build methods, `ref.read` in callbacks.
- Use `AsyncValue` pattern for loading/error/data states.
- Scope providers with `ProviderScope(overrides: [...])` for testing.
- Use `ref.invalidate()` to refresh stale data.
- Use Notifier/AsyncNotifier over StateNotifier (deprecated).

### Bloc/Cubit (Enterprise Alternative)
Use Cubit for simple state, Bloc for event-driven flows.
```dart
// Cubit — simpler
class CounterCubit extends Cubit<int> {
  CounterCubit() : super(0);
  void increment() => emit(state + 1);
}

// Bloc — full event/state separation
sealed class AuthEvent {}
class LoginRequested extends AuthEvent { final String email, password; ... }

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._repo) : super(Unauthenticated()) {
    on<LoginRequested>(_onLogin);
  }
  Future<void> _onLogin(LoginRequested e, Emitter<AuthState> emit) async {
    emit(Loading());
    try {
      final user = await _repo.login(e.email, e.password);
      emit(Authenticated(user));
    } catch (e) { emit(AuthError(e.toString())); }
  }
}
```
- Use `BlocBuilder` for UI, `BlocListener` for side effects, `BlocConsumer` for both.
- Use `buildWhen`/`listenWhen` to filter unnecessary rebuilds.
- Keep Blocs focused: one Bloc per feature domain.

### Provider
Use only for simple apps or legacy codebases. Prefer Riverpod for new work.
Use `ChangeNotifierProvider` for mutable state, `FutureProvider`/`StreamProvider` for async.

## Navigation — GoRouter

Centralize routing in a single file. Use typed routes for compile-time safety.
```dart
final router = GoRouter(
  initialLocation: '/',
  redirect: (context, state) {
    final isAuth = /* check auth */;
    if (!isAuth && !state.matchedLocation.startsWith('/login')) return '/login';
    return null;
  },
  routes: [
    ShellRoute(
      builder: (context, state, child) => ScaffoldWithNav(child: child),
      routes: [
        GoRoute(path: '/', builder: (_, __) => const HomePage()),
        GoRoute(
          path: '/products/:id',
          builder: (_, state) => ProductPage(id: state.pathParameters['id']!),
        ),
      ],
    ),
    GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
  ],
);
```
- Use `ShellRoute` for persistent bottom nav / side nav layouts.
- Define path constants: `abstract class AppRoutes { static const home = '/'; ... }`
- Use `context.go()` for replacement navigation, `context.push()` for stack push.
- Configure deep links: Android intent-filters, iOS associated domains.
- Always define `errorBuilder` for 404/unknown routes.

## Networking

### Dio (Recommended)
```dart
final dio = Dio(BaseOptions(
  baseUrl: 'https://api.example.com',
  connectTimeout: const Duration(seconds: 10),
));
dio.interceptors.addAll([
  LogInterceptor(requestBody: true, responseBody: true),
  InterceptorsWrapper(
    onRequest: (opts, handler) { /* inject auth token */ handler.next(opts); },
    onError: (e, handler) { /* handle 401 refresh */ handler.next(e); },
  ),
]);
```
Use interceptors for auth, logging, retry. Use `CancelToken` for cancellable requests.
Wrap API calls in repository classes — never call Dio from UI.

### Retrofit (Type-safe API layer)
```dart
@RestApi(baseUrl: 'https://api.example.com')
abstract class ApiClient {
  factory ApiClient(Dio dio) = _ApiClient;
  @GET('/products')
  Future<List<Product>> getProducts();
  @POST('/orders')
  Future<Order> createOrder(@Body() CreateOrderDto dto);
}
```
Generate with `dart run build_runner build`. Pair with Dio for interceptors.

## Local Storage

| Solution | Use Case |
|----------|----------|
| `shared_preferences` | Simple key-value (settings, flags) |
| `Hive` | Fast NoSQL, offline-first, binary storage |
| `Isar` | Full-featured embedded DB, complex queries, indexes |
| `drift` | Type-safe SQLite with Dart code generation |

- Use `shared_preferences` for primitive settings only.
- Use Hive for offline caches, user preferences objects.
- Use Isar or drift for relational data, full-text search, complex queries.
- Always encrypt sensitive stored data. Use `flutter_secure_storage` for credentials/tokens.

## Platform Channels

### MethodChannel
```dart
const channel = MethodChannel('com.app/battery');
Future<int> getBatteryLevel() async {
  try { return await channel.invokeMethod<int>('getBatteryLevel') ?? -1; }
  on PlatformException { return -1; }
}
```

### EventChannel — for continuous streams (sensors, location, connectivity).
```dart
const eventChannel = EventChannel('com.app/sensors');
eventChannel.receiveBroadcastStream().listen((data) { /* process */ });
```

### FFIgen / JNIgen
Prefer FFIgen/JNIgen over manual platform channels for C/Java/Kotlin/Swift interop.
Generates type-safe bindings. Reduces boilerplate and runtime errors.

## Material 3 Theming

```dart
MaterialApp.router(
  theme: ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: Brightness.light,
    ),
    textTheme: GoogleFonts.interTextTheme(),
  ),
  darkTheme: ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: Brightness.dark,
    ),
  ),
  themeMode: ThemeMode.system,
  routerConfig: router,
);
```
- Use `ColorScheme.fromSeed()` for dynamic color theming.
- Access colors via `Theme.of(context).colorScheme.primary` — never hardcode colors.
- Use `TextTheme` tokens: `titleLarge`, `bodyMedium`, etc.
- Support dark mode from day one — use `themeMode: ThemeMode.system`.

## Responsive Design

```dart
Widget build(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return switch (width) { < 600 => MobileLayout(), < 900 => TabletLayout(), _ => DesktopLayout() };
}
```
- Use `LayoutBuilder` for parent-relative, `MediaQuery.sizeOf` for screen-relative sizing.
- Define breakpoints as constants. Use `SafeArea` for notches/status bars.

## Testing

### Unit Tests
Test domain logic, use cases, repositories in isolation. Mock dependencies with `mocktail`.
```dart
class MockProductRepo extends Mock implements ProductRepository {}
test('fetchProducts returns list', () async {
  final mock = MockProductRepo();
  when(() => mock.fetchAll()).thenAnswer((_) async => [Product(id: '1', name: 'A')]);
  final result = await FetchProducts(mock).call();
  expect(result, hasLength(1));
});
```

### Widget Tests
Test UI rendering and interaction without a device.
```dart
testWidgets('counter increments', (tester) async {
  await tester.pumpWidget(const MaterialApp(home: CounterPage()));
  expect(find.text('0'), findsOneWidget);
  await tester.tap(find.byIcon(Icons.add));
  await tester.pump();
  expect(find.text('1'), findsOneWidget);
});
```
- Use `pumpAndSettle()` after animations. Use `pump()` for single frame advances.
- Mock providers: wrap with `ProviderScope(overrides: [...])` for Riverpod.
- Use `find.byKey()` for reliable widget location over `find.byType()`.

### Golden Tests
Compare widget rendering against reference images.
```dart
testWidgets('profile card golden', (tester) async {
  await tester.pumpWidget(const MaterialApp(home: ProfileCard(user: testUser)));
  await expectLater(find.byType(ProfileCard), matchesGoldenFile('goldens/profile_card.png'));
});
```
- Run `flutter test --update-goldens` to regenerate baseline images.
- Fix theme, locale, and screen size in golden tests to avoid environment variance.
- Store golden files in VCS. Review visual diffs in PRs.

### Integration Tests
```dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('full login flow', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email')), 'test@test.com');
    await tester.tap(find.byKey(const Key('loginBtn')));
    await tester.pumpAndSettle();
    expect(find.text('Welcome'), findsOneWidget);
  });
}
```
Run: `flutter test integration_test/`. Target 70% unit / 20% widget / 10% integration.

## Performance Profiling

- Profile with `flutter run --profile`. Use DevTools Timeline and Memory views.
- Target 16ms/frame (60fps). Use `PerformanceOverlay` during development.
- Avoid `saveLayer` (Opacity, ClipRRect) — use `AnimatedOpacity` instead.
- Use `const` constructors and `RepaintBoundary` to reduce rebuilds.
- Use `Isolate.run()` / `compute()` for heavy CPU work off main thread.
- Impeller is default renderer — eliminates shader jank on iOS/Android.
- Monitor size: `flutter build apk --analyze-size`.

## CI/CD

### GitHub Actions
```yaml
name: Flutter CI
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { flutter-version: '3.x', channel: stable }
      - run: flutter pub get
      - run: dart analyze --fatal-infos
      - run: flutter test --coverage
      - run: flutter build apk --release
```

### Key CI Steps
1. `flutter pub get` — resolve deps
2. `dart analyze --fatal-infos` — static analysis
3. `dart format --set-exit-if-changed .` — enforce formatting
4. `flutter test --coverage` — tests with coverage
5. `flutter build apk/ios/web` — platform builds
6. Use Fastlane for store deployment, Codemagic for managed CI/CD.

## Code Generation

Run `dart run build_runner build --delete-conflicting-outputs`. Key generators:
`freezed` (data classes/unions), `json_serializable` (JSON), `retrofit_generator` (APIs),
`riverpod_generator` (providers). Commit or gitignore generated files — enforce one convention.

## Multi-Platform

- **Web**: Use `kIsWeb` for checks. Use deferred loading for bundle size. Impeller web in beta.
- **Desktop**: Use `Platform.is*` for platform logic. Use `window_manager` for window control.
  Sign/notarize macOS. Use MSIX for Windows distribution.

## Anti-Patterns
- Never use `setState` for app-wide state. Never ignore `dispose()` for controllers/streams.
- Never hardcode colors — use `Theme.of(context).colorScheme`. Never use `print()` — use `debugPrint()`.
- Never put business logic in widgets. Never use `dynamic` when type is known.
- Never use string-based navigation. Never suppress analyzer warnings without justification.
