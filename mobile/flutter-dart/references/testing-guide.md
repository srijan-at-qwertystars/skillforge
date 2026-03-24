# Flutter Testing — Comprehensive Guide

## Table of Contents

- [Testing Philosophy](#testing-philosophy)
- [Test Pyramid](#test-pyramid)
- [Unit Testing](#unit-testing)
  - [Setup and Dependencies](#setup-and-dependencies)
  - [Mocking with Mocktail](#mocking-with-mocktail)
  - [Mocking with Mockito](#mocking-with-mockito)
  - [Testing Async Code](#testing-async-code)
  - [Testing Streams](#testing-streams)
  - [Testing Repositories](#testing-repositories)
  - [Testing Use Cases](#testing-use-cases)
- [Widget Testing](#widget-testing)
  - [pumpWidget Basics](#pumpwidget-basics)
  - [Finders](#finders)
  - [Matchers](#matchers)
  - [Interaction Simulation](#interaction-simulation)
  - [Pumping and Animations](#pumping-and-animations)
  - [Testing with Providers (Riverpod)](#testing-with-providers-riverpod)
  - [Testing with Bloc](#testing-with-bloc)
  - [Testing Navigation](#testing-navigation)
  - [Testing Forms](#testing-forms)
  - [Testing Dialogs and Bottom Sheets](#testing-dialogs-and-bottom-sheets)
- [Golden Tests](#golden-tests)
  - [Setup](#golden-test-setup)
  - [Writing Golden Tests](#writing-golden-tests)
  - [Updating Goldens](#updating-goldens)
  - [Multi-Platform Goldens](#multi-platform-goldens)
  - [Golden Test Best Practices](#golden-test-best-practices)
- [Integration Tests](#integration-tests)
  - [Setup with integration_test](#setup-with-integration_test)
  - [Writing Integration Tests](#writing-integration-tests)
  - [Patrol Package](#patrol-package)
  - [Running on Devices and CI](#running-on-devices-and-ci)
- [Testing Navigation](#testing-navigation-detailed)
- [Testing Async Operations](#testing-async-operations)
- [Code Coverage](#code-coverage)
- [CI Testing Setup](#ci-testing-setup)
- [Testing Patterns and Anti-Patterns](#testing-patterns-and-anti-patterns)

---

## Testing Philosophy

Flutter testing ensures correctness at every layer: pure logic, widget rendering,
user interaction, and end-to-end flows. A well-tested Flutter app catches regressions
early, documents behavior, and enables safe refactoring.

**Key principles:**
1. Test behavior, not implementation — don't test private methods.
2. One assertion per test when possible — tests should have a single reason to fail.
3. Use descriptive test names — `'shows error message when login fails'` not `'test 1'`.
4. Mock external dependencies — never hit real APIs in unit/widget tests.
5. Keep tests fast — a slow test suite won't be run.
6. Treat test code as production code — apply DRY, readability, and maintenance standards.

---

## Test Pyramid

```
         ╱╲
        ╱  ╲       Integration Tests (10%)
       ╱    ╲      End-to-end flows on real device/emulator
      ╱──────╲
     ╱        ╲    Widget Tests (20%)
    ╱          ╲   Component rendering, interaction, state
   ╱────────────╲
  ╱              ╲  Unit Tests (70%)
 ╱                ╲ Business logic, repositories, models, utils
╱──────────────────╲
```

| Type | Speed | Confidence | Scope | Dependencies |
|------|-------|------------|-------|-------------|
| Unit | Very fast | Logic correctness | Single class/function | Mocked |
| Widget | Fast | UI correctness | Widget tree | Mocked providers |
| Integration | Slow | Full app behavior | Complete app | Real or faked |

---

## Unit Testing

### Setup and Dependencies

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  mocktail: ^1.0.3          # Preferred: no codegen needed
  mockito: ^5.4.4           # Alternative: codegen-based
  build_runner: ^2.4.0      # For mockito codegen
  fake_async: ^1.3.1        # Control async timing
  clock: ^1.1.1             # Mockable clock
```

Test file structure mirrors `lib/`:
```
lib/
  features/auth/domain/use_cases/login_use_case.dart
test/
  features/auth/domain/use_cases/login_use_case_test.dart
```

### Mocking with Mocktail

Mocktail requires no code generation — preferred for most projects.

```dart
import 'package:mocktail/mocktail.dart';
import 'package:flutter_test/flutter_test.dart';

// Create mock class
class MockAuthRepository extends Mock implements AuthRepository {}
class MockAnalytics extends Mock implements AnalyticsService {}

// Register fallback values for custom types used in argument matchers
void main() {
  setUpAll(() {
    registerFallbackValue(LoginParams(email: '', password: ''));
  });

  late MockAuthRepository mockRepo;
  late LoginUseCase useCase;

  setUp(() {
    mockRepo = MockAuthRepository();
    useCase = LoginUseCase(mockRepo);
  });

  group('LoginUseCase', () {
    test('returns User on successful login', () async {
      // Arrange
      final expectedUser = User(id: '1', name: 'Alice');
      when(() => mockRepo.login(
        email: any(named: 'email'),
        password: any(named: 'password'),
      )).thenAnswer((_) async => expectedUser);

      // Act
      final result = await useCase(
        LoginParams(email: 'alice@test.com', password: 'secret'),
      );

      // Assert
      expect(result, equals(expectedUser));
      verify(() => mockRepo.login(
        email: 'alice@test.com',
        password: 'secret',
      )).called(1);
    });

    test('throws AuthException on invalid credentials', () async {
      when(() => mockRepo.login(
        email: any(named: 'email'),
        password: any(named: 'password'),
      )).thenThrow(AuthException('Invalid credentials'));

      expect(
        () => useCase(LoginParams(email: 'a@b.com', password: 'wrong')),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
```

**Mocktail verification patterns:**
```dart
// Verify called exactly N times
verify(() => mock.method()).called(1);

// Verify never called
verifyNever(() => mock.method());

// Verify call order
verifyInOrder([
  () => mock.methodA(),
  () => mock.methodB(),
]);

// Capture arguments
final captured = verify(() => mock.method(captureAny())).captured;
expect(captured.last, equals(expectedValue));

// Verify no more interactions
verifyNoMoreInteractions(mock);
```

### Mocking with Mockito

Mockito requires code generation but provides strong type safety.

```dart
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

@GenerateMocks([AuthRepository, AnalyticsService])
import 'login_test.mocks.dart';

void main() {
  late MockAuthRepository mockRepo;

  setUp(() {
    mockRepo = MockAuthRepository();
  });

  test('fetches user', () async {
    when(mockRepo.fetchUser(any)).thenAnswer(
      (_) async => User(id: '1', name: 'Alice'),
    );

    final user = await mockRepo.fetchUser('1');
    expect(user.name, 'Alice');
  });
}
```

Run `dart run build_runner build` after adding/changing `@GenerateMocks`.

### Testing Async Code

```dart
test('debounced search waits before calling API', () async {
  fakeAsync((async) {
    final controller = SearchController(mockApi);

    controller.onQueryChanged('flu');
    async.elapse(const Duration(milliseconds: 200)); // Before debounce
    verifyNever(() => mockApi.search(any()));

    async.elapse(const Duration(milliseconds: 200)); // After debounce
    verify(() => mockApi.search('flu')).called(1);
  });
});

test('retry logic attempts 3 times', () async {
  var attempts = 0;
  when(() => mockApi.fetch()).thenAnswer((_) async {
    attempts++;
    if (attempts < 3) throw NetworkException();
    return 'success';
  });

  final result = await retryFetch(mockApi);
  expect(result, 'success');
  expect(attempts, 3);
});
```

### Testing Streams

```dart
test('emits values in order', () {
  final controller = StreamController<int>();

  expectLater(
    controller.stream,
    emitsInOrder([1, 2, 3, emitsDone]),
  );

  controller.add(1);
  controller.add(2);
  controller.add(3);
  controller.close();
});

test('stream emits error', () {
  expectLater(
    errorStream,
    emitsError(isA<FormatException>()),
  );
});

test('BehaviorSubject replays last value', () {
  final subject = BehaviorSubject<int>.seeded(0);
  subject.add(1);
  subject.add(2);

  expectLater(subject.stream, emits(2));
});
```

### Testing Repositories

```dart
class MockDio extends Mock implements Dio {}
class MockLocalStorage extends Mock implements LocalStorage {}

void main() {
  late ProductRepositoryImpl repo;
  late MockDio mockDio;
  late MockLocalStorage mockStorage;

  setUp(() {
    mockDio = MockDio();
    mockStorage = MockLocalStorage();
    repo = ProductRepositoryImpl(dio: mockDio, storage: mockStorage);
  });

  group('fetchProducts', () {
    test('returns products from API on success', () async {
      when(() => mockDio.get('/products')).thenAnswer(
        (_) async => Response(
          data: [{'id': '1', 'name': 'Widget'}],
          statusCode: 200,
          requestOptions: RequestOptions(path: '/products'),
        ),
      );

      final products = await repo.fetchProducts();

      expect(products, hasLength(1));
      expect(products.first.name, 'Widget');
    });

    test('falls back to cache when API fails', () async {
      when(() => mockDio.get('/products')).thenThrow(
        DioException(
          type: DioExceptionType.connectionTimeout,
          requestOptions: RequestOptions(path: '/products'),
        ),
      );
      when(() => mockStorage.getProducts()).thenAnswer(
        (_) async => [Product(id: '1', name: 'Cached')],
      );

      final products = await repo.fetchProducts();

      expect(products.first.name, 'Cached');
      verify(() => mockStorage.getProducts()).called(1);
    });
  });
}
```

### Testing Use Cases

```dart
test('FetchProducts use case filters inactive products', () async {
  final allProducts = [
    Product(id: '1', name: 'Active', isActive: true),
    Product(id: '2', name: 'Inactive', isActive: false),
  ];

  when(() => mockRepo.fetchProducts())
      .thenAnswer((_) async => allProducts);

  final result = await fetchProductsUseCase();

  expect(result, hasLength(1));
  expect(result.first.name, 'Active');
});
```

---

## Widget Testing

### pumpWidget Basics

```dart
testWidgets('renders greeting', (tester) async {
  // Build widget tree
  await tester.pumpWidget(
    const MaterialApp(
      home: GreetingPage(name: 'Alice'),
    ),
  );

  // Verify rendering
  expect(find.text('Hello, Alice!'), findsOneWidget);
});
```

**Important:** Always wrap test widgets in `MaterialApp` (or `CupertinoApp`) to provide
`MediaQuery`, `Directionality`, theme, and other inherited widgets.

### Finders

```dart
// By text
find.text('Hello')                      // Exact text
find.textContaining('Hell')             // Partial match

// By widget type
find.byType(ElevatedButton)
find.byType(CircularProgressIndicator)

// By key
find.byKey(const Key('submit_button'))
find.byKey(const ValueKey('item_42'))

// By icon
find.byIcon(Icons.add)

// By widget predicate
find.byWidgetPredicate(
  (widget) => widget is Text && widget.data!.startsWith('Error'),
)

// By ancestor/descendant
find.descendant(
  of: find.byType(ListTile),
  matching: find.text('Alice'),
)

find.ancestor(
  of: find.text('Alice'),
  matching: find.byType(Card),
)

// Semantic label (accessibility)
find.bySemanticsLabel('Close dialog')
```

### Matchers

```dart
expect(find.text('Hello'), findsOneWidget);
expect(find.text('Hello'), findsNothing);
expect(find.byType(ListTile), findsNWidgets(3));
expect(find.byType(ListTile), findsAtLeast(1));
expect(find.text('Hello'), findsWidgets);  // At least one

// Widget property matchers
final textWidget = tester.widget<Text>(find.text('Hello'));
expect(textWidget.style?.fontSize, 24);

// Render object matchers
expect(
  tester.getSize(find.byType(Container)),
  equals(const Size(200, 100)),
);

expect(
  tester.getTopLeft(find.byType(Padding)),
  equals(const Offset(16, 16)),
);
```

### Interaction Simulation

```dart
testWidgets('counter increments on tap', (tester) async {
  await tester.pumpWidget(const MaterialApp(home: CounterPage()));

  // Tap
  await tester.tap(find.byIcon(Icons.add));
  await tester.pump(); // Rebuild

  expect(find.text('1'), findsOneWidget);

  // Long press
  await tester.longPress(find.byType(ListTile));
  await tester.pump();

  // Text input
  await tester.enterText(find.byType(TextField), 'hello@test.com');
  await tester.pump();

  // Drag / scroll
  await tester.drag(find.byType(ListView), const Offset(0, -300));
  await tester.pumpAndSettle();

  // Fling (fast scroll)
  await tester.fling(find.byType(ListView), const Offset(0, -500), 1000);
  await tester.pumpAndSettle();

  // Double tap
  await tester.tap(find.byType(InkWell));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.byType(InkWell));
  await tester.pump();
});
```

### Pumping and Animations

```dart
// pump() — advance one frame
await tester.pump();

// pump(duration) — advance by specific duration
await tester.pump(const Duration(milliseconds: 500));

// pumpAndSettle() — pump until no pending frames (animations complete)
await tester.pumpAndSettle();
// WARNING: Will timeout if animation loops forever (e.g., CircularProgressIndicator)

// pumpAndSettle with timeout
await tester.pumpAndSettle(
  const Duration(milliseconds: 100), // min duration between pumps
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 5),        // timeout
);

// For widgets with infinite animations, use pump() with specific duration instead
await tester.pumpWidget(
  const MaterialApp(home: LoadingPage()), // has CircularProgressIndicator
);
await tester.pump(const Duration(seconds: 1)); // advance 1 second
expect(find.byType(CircularProgressIndicator), findsOneWidget);
```

### Testing with Providers (Riverpod)

```dart
testWidgets('shows products from provider', (tester) async {
  final testProducts = [
    Product(id: '1', name: 'Test Product', price: 9.99),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productsProvider.overrideWith((_) => testProducts),
      ],
      child: const MaterialApp(home: ProductListPage()),
    ),
  );

  expect(find.text('Test Product'), findsOneWidget);
  expect(find.text('\$9.99'), findsOneWidget);
});

testWidgets('shows loading state', (tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productsProvider.overrideWith(
          (_) => Future.delayed(
            const Duration(seconds: 2),
            () => <Product>[],
          ),
        ),
      ],
      child: const MaterialApp(home: ProductListPage()),
    ),
  );

  // Initially shows loading
  expect(find.byType(CircularProgressIndicator), findsOneWidget);
});

testWidgets('shows error state', (tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productsProvider.overrideWith(
          (_) => throw Exception('Network error'),
        ),
      ],
      child: const MaterialApp(home: ProductListPage()),
    ),
  );

  await tester.pump();
  expect(find.textContaining('error'), findsOneWidget);
});
```

### Testing with Bloc

```dart
import 'package:bloc_test/bloc_test.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

testWidgets('shows user name when authenticated', (tester) async {
  final mockBloc = MockAuthBloc();
  when(() => mockBloc.state).thenReturn(
    Authenticated(User(name: 'Alice')),
  );

  await tester.pumpWidget(
    MaterialApp(
      home: BlocProvider<AuthBloc>.value(
        value: mockBloc,
        child: const ProfilePage(),
      ),
    ),
  );

  expect(find.text('Alice'), findsOneWidget);
});

testWidgets('navigates to login on logout', (tester) async {
  final mockBloc = MockAuthBloc();
  whenListen(
    mockBloc,
    Stream.fromIterable([Authenticated(testUser), Unauthenticated()]),
    initialState: Authenticated(testUser),
  );

  await tester.pumpWidget(
    MaterialApp(
      home: BlocProvider<AuthBloc>.value(
        value: mockBloc,
        child: const HomePage(),
      ),
    ),
  );

  await tester.pumpAndSettle();
  expect(find.byType(LoginPage), findsOneWidget);
});
```

### Testing Navigation

```dart
testWidgets('navigates to detail page on tap', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      routes: {
        '/': (_) => const ProductListPage(),
        '/detail': (_) => const ProductDetailPage(),
      },
    ),
  );

  await tester.tap(find.text('View Details'));
  await tester.pumpAndSettle();

  expect(find.byType(ProductDetailPage), findsOneWidget);
});

// Testing with GoRouter
testWidgets('GoRouter navigation', (tester) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomePage()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
    ],
  );

  await tester.pumpWidget(
    MaterialApp.router(routerConfig: router),
  );

  // Programmatic navigation
  router.go('/settings');
  await tester.pumpAndSettle();

  expect(find.byType(SettingsPage), findsOneWidget);
});
```

### Testing Forms

```dart
testWidgets('validates email field', (tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: LoginForm()),
  );

  // Enter invalid email
  await tester.enterText(
    find.byKey(const Key('email_field')),
    'not-an-email',
  );
  await tester.tap(find.byKey(const Key('submit_btn')));
  await tester.pump();

  expect(find.text('Invalid email'), findsOneWidget);

  // Enter valid email
  await tester.enterText(
    find.byKey(const Key('email_field')),
    'valid@email.com',
  );
  await tester.tap(find.byKey(const Key('submit_btn')));
  await tester.pump();

  expect(find.text('Invalid email'), findsNothing);
});
```

### Testing Dialogs and Bottom Sheets

```dart
testWidgets('shows confirmation dialog', (tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: DeleteButton()),
  );

  await tester.tap(find.byIcon(Icons.delete));
  await tester.pumpAndSettle();

  // Dialog is shown
  expect(find.text('Are you sure?'), findsOneWidget);

  // Tap confirm
  await tester.tap(find.text('Delete'));
  await tester.pumpAndSettle();

  // Dialog dismissed
  expect(find.text('Are you sure?'), findsNothing);
});

testWidgets('shows bottom sheet with options', (tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: OptionsPage()),
  );

  await tester.tap(find.text('More Options'));
  await tester.pumpAndSettle();

  expect(find.byType(BottomSheet), findsOneWidget);
  expect(find.text('Share'), findsOneWidget);
  expect(find.text('Copy Link'), findsOneWidget);
});
```

---

## Golden Tests

### Golden Test Setup

Golden tests compare widget rendering against reference PNG images.

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  alchemist: ^0.9.0  # Optional: better golden test tooling
```

**Font loading for consistent goldens:**
```dart
// test/helpers/golden_helpers.dart
Future<void> loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fontLoader = FontLoader('Roboto');
  fontLoader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
  await fontLoader.load();
}
```

### Writing Golden Tests

```dart
void main() {
  setUp(() async {
    await loadAppFonts();
  });

  testWidgets('ProfileCard renders correctly', (tester) async {
    // Fix screen size for consistency
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: ProfileCard(
            name: 'Alice',
            email: 'alice@example.com',
            avatarUrl: null, // Use placeholder for deterministic rendering
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(ProfileCard),
      matchesGoldenFile('goldens/profile_card.png'),
    );
  });

  testWidgets('ProfileCard dark mode', (tester) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: const Scaffold(
          body: ProfileCard(name: 'Alice', email: 'alice@example.com'),
        ),
      ),
    );

    await expectLater(
      find.byType(ProfileCard),
      matchesGoldenFile('goldens/profile_card_dark.png'),
    );
  });
}
```

### Updating Goldens

```bash
# Generate/update golden reference files:
flutter test --update-goldens

# Update specific test file:
flutter test --update-goldens test/golden/profile_card_test.dart

# Run golden tests (compare against references):
flutter test test/golden/
```

### Multi-Platform Goldens

Golden images can differ across platforms (font rendering, anti-aliasing).

**Strategy 1: Platform-specific goldens**
```dart
final platform = Platform.operatingSystem;
await expectLater(
  find.byType(MyWidget),
  matchesGoldenFile('goldens/$platform/my_widget.png'),
);
```

**Strategy 2: Use Alchemist for CI-safe goldens**
```dart
goldenTest(
  'ProfileCard renders correctly',
  fileName: 'profile_card',
  builder: () => GoldenTestGroup(
    children: [
      GoldenTestScenario(
        name: 'default',
        child: const ProfileCard(name: 'Alice'),
      ),
      GoldenTestScenario(
        name: 'long name',
        child: const ProfileCard(name: 'A Very Long Name That Wraps'),
      ),
    ],
  ),
);
```

### Golden Test Best Practices

1. **Fix screen size** — always set `physicalSize` and `devicePixelRatio`
2. **Fix theme** — use explicit theme, don't rely on defaults
3. **Fix locale** — set `Localizations.override` if your app is localized
4. **Avoid network images** — use placeholder assets or cached images
5. **Store in VCS** — commit golden files, review diffs in PRs
6. **CI consistency** — use same Flutter version and OS in CI as local dev
7. **Don't golden-test dynamic content** — mock dates, random values
8. **Group related goldens** — one test file per component with multiple scenarios

---

## Integration Tests

### Setup with integration_test

```yaml
# pubspec.yaml
dev_dependencies:
  integration_test:
    sdk: flutter
  flutter_test:
    sdk: flutter
```

```
integration_test/
  app_test.dart
  robots/             # Page object pattern
    login_robot.dart
    home_robot.dart
```

### Writing Integration Tests

```dart
// integration_test/app_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('end-to-end test', () {
    testWidgets('full login flow', (tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Login page
      expect(find.byType(LoginPage), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('email_field')),
        'test@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('password_field')),
        'password123',
      );
      await tester.tap(find.byKey(const Key('login_button')));
      await tester.pumpAndSettle();

      // Home page
      expect(find.text('Welcome'), findsOneWidget);
      expect(find.byType(HomePage), findsOneWidget);
    });
  });
}
```

**Page Object Pattern (Robots):**
```dart
// integration_test/robots/login_robot.dart
class LoginRobot {
  final WidgetTester tester;
  LoginRobot(this.tester);

  Future<void> enterEmail(String email) async {
    await tester.enterText(find.byKey(const Key('email_field')), email);
    await tester.pump();
  }

  Future<void> enterPassword(String password) async {
    await tester.enterText(find.byKey(const Key('password_field')), password);
    await tester.pump();
  }

  Future<void> tapLogin() async {
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();
  }

  Future<void> login({
    required String email,
    required String password,
  }) async {
    await enterEmail(email);
    await enterPassword(password);
    await tapLogin();
  }

  void expectLoginPage() {
    expect(find.byType(LoginPage), findsOneWidget);
  }

  void expectErrorMessage(String message) {
    expect(find.text(message), findsOneWidget);
  }
}

// Usage in test:
testWidgets('login flow', (tester) async {
  app.main();
  await tester.pumpAndSettle();

  final loginRobot = LoginRobot(tester);
  loginRobot.expectLoginPage();
  await loginRobot.login(email: 'test@test.com', password: '123');

  final homeRobot = HomeRobot(tester);
  homeRobot.expectHomePage();
});
```

### Patrol Package

Patrol provides native automation (permission dialogs, notifications, system UI).

```yaml
dev_dependencies:
  patrol: ^3.6.0
```

```dart
// integration_test/permission_test.dart
import 'package:patrol/patrol.dart';

void main() {
  patrolTest('grants camera permission', ($) async {
    await $.pumpWidgetAndSettle(const MyApp());

    await $.tap(find.text('Take Photo'));

    // Handle native permission dialog
    await $.native.grantPermissionWhenInUse();

    expect(find.byType(CameraPreview), findsOneWidget);
  });

  patrolTest('handles notification', ($) async {
    await $.pumpWidgetAndSettle(const MyApp());

    // Open notification shade
    await $.native.openNotifications();
    await $.native.tap(Selector(textContains: 'New message'));
    await $.native.pressBack();
  });
}
```

### Running on Devices and CI

```bash
# Run on connected device:
flutter test integration_test/app_test.dart

# Run on specific device:
flutter test integration_test/ -d <device_id>

# Run with Patrol:
patrol test --target integration_test/app_test.dart

# Run on Firebase Test Lab:
flutter build apk --debug -t integration_test/app_test.dart
gcloud firebase test android run \
  --type instrumentation \
  --app build/app/outputs/apk/debug/app-debug.apk \
  --test build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
```

---

## Testing Navigation (Detailed)

```dart
// Test GoRouter redirect
test('redirects unauthenticated users to login', () {
  final router = createRouter(isAuthenticated: false);

  router.go('/profile');

  expect(router.routerDelegate.currentConfiguration.uri.toString(),
      equals('/login'));
});

// Test deep links
testWidgets('handles deep link to product', (tester) async {
  final router = GoRouter(
    initialLocation: '/products/42',
    routes: [
      GoRoute(
        path: '/products/:id',
        builder: (_, state) => ProductPage(
          id: state.pathParameters['id']!,
        ),
      ),
    ],
  );

  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();

  expect(find.byType(ProductPage), findsOneWidget);
});

// Test back navigation
testWidgets('back button returns to previous page', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      ),
    ),
  );

  // Navigate forward
  await tester.tap(find.text('Go to Detail'));
  await tester.pumpAndSettle();
  expect(find.byType(DetailPage), findsOneWidget);

  // Navigate back
  final backButton = find.byTooltip('Back');
  await tester.tap(backButton);
  await tester.pumpAndSettle();
  expect(find.byType(HomePage), findsOneWidget);
});
```

---

## Testing Async Operations

```dart
testWidgets('shows loading then data', (tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productsProvider.overrideWith((_) async {
          await Future.delayed(const Duration(seconds: 1));
          return [Product(id: '1', name: 'Widget')];
        }),
      ],
      child: const MaterialApp(home: ProductsPage()),
    ),
  );

  // Initial state: loading
  await tester.pump();
  expect(find.byType(CircularProgressIndicator), findsOneWidget);

  // After async completes
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(); // One more frame for rebuild
  expect(find.text('Widget'), findsOneWidget);
  expect(find.byType(CircularProgressIndicator), findsNothing);
});

// Testing with fakeAsync for precise timing control
testWidgets('debounced search', (tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: SearchPage()),
  );

  await tester.enterText(find.byType(TextField), 'flut');
  await tester.pump(const Duration(milliseconds: 100)); // Before debounce
  expect(find.byType(SearchResults), findsNothing);

  await tester.pump(const Duration(milliseconds: 400)); // After debounce
  await tester.pump(); // Rebuild
  expect(find.byType(SearchResults), findsOneWidget);
});
```

---

## Code Coverage

```bash
# Generate coverage:
flutter test --coverage

# Output: coverage/lcov.info

# View HTML report (requires lcov):
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html

# On macOS, install lcov:
brew install lcov

# Filter out generated files:
lcov --remove coverage/lcov.info \
  '**/*.g.dart' \
  '**/*.freezed.dart' \
  '**/*.gr.dart' \
  '**/generated/**' \
  -o coverage/lcov_filtered.info

# Enforce minimum coverage in CI:
# Parse lcov.info and fail if below threshold
COVERAGE=$(lcov --summary coverage/lcov_filtered.info 2>&1 | \
  grep -oP 'lines\.*: \K[0-9.]+')
if (( $(echo "$COVERAGE < 80" | bc -l) )); then
  echo "Coverage $COVERAGE% is below 80% threshold"
  exit 1
fi
```

**Coverage targets:**
| Layer | Target |
|-------|--------|
| Domain (entities, use cases) | 90%+ |
| Data (repositories, DTOs) | 80%+ |
| Presentation (widgets) | 70%+ |
| Overall | 80%+ |

---

## CI Testing Setup

### GitHub Actions

```yaml
name: Flutter Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.x'
          channel: stable
          cache: true

      - name: Install dependencies
        run: flutter pub get

      - name: Analyze
        run: dart analyze --fatal-infos

      - name: Format check
        run: dart format --set-exit-if-changed .

      - name: Run tests
        run: flutter test --coverage --reporter=expanded

      - name: Check coverage
        run: |
          sudo apt-get install -y lcov
          lcov --remove coverage/lcov.info \
            '**/*.g.dart' '**/*.freezed.dart' \
            -o coverage/lcov_filtered.info
          genhtml coverage/lcov_filtered.info -o coverage/html

      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          files: coverage/lcov_filtered.info

  golden-test:
    runs-on: macos-latest  # Consistent font rendering
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.x'
          channel: stable
          cache: true
      - run: flutter pub get
      - run: flutter test test/golden/
```

### Test Organization Tips

```dart
// Group related tests
group('ProductRepository', () {
  group('fetchProducts', () {
    test('returns products on success', () { ... });
    test('throws on network error', () { ... });
    test('caches results', () { ... });
  });

  group('createProduct', () {
    test('returns created product', () { ... });
    test('validates input', () { ... });
  });
});

// Use setUp/tearDown for shared setup
late MockDio mockDio;

setUp(() {
  mockDio = MockDio();
});

tearDown(() {
  reset(mockDio); // Reset all stubs (mocktail)
});

// Use setUpAll/tearDownAll for expensive one-time setup
setUpAll(() async {
  await loadAppFonts();
});
```

---

## Testing Patterns and Anti-Patterns

### ✅ Good Patterns

```dart
// Test behavior, not implementation
test('adds product to cart', () {
  cart.add(product);
  expect(cart.items, contains(product));
  expect(cart.total, product.price);
});

// Descriptive test names
test('shows validation error when email is empty and submit is tapped', ...);

// AAA pattern: Arrange, Act, Assert
test('calculates discount', () {
  // Arrange
  final cart = Cart(items: [Product(price: 100)]);
  // Act
  final total = cart.totalWithDiscount(0.1);
  // Assert
  expect(total, 90.0);
});

// Test edge cases
test('handles empty list gracefully', () { ... });
test('handles null avatar URL', () { ... });
test('handles very long text', () { ... });
```

### ❌ Anti-Patterns

```dart
// DON'T: Test implementation details
test('calls notifyListeners', () {
  // This tests HOW, not WHAT. If refactored, test breaks for no reason.
});

// DON'T: Multiple unrelated assertions
test('everything works', () {
  expect(login, succeeds);
  expect(fetchProducts, returns3);
  expect(darkMode, isEnabled);
  // If one fails, which behavior is broken?
});

// DON'T: Tests that depend on order
test('test 1 sets up data', () { ... });
test('test 2 uses data from test 1', () { ... }); // Fragile!

// DON'T: Hardcoded delays
await Future.delayed(const Duration(seconds: 2)); // Flaky!
// DO: Use pump(), pumpAndSettle(), or fakeAsync

// DON'T: Test framework code
test('StatelessWidget builds', () {
  // Flutter already tests this. Test YOUR code.
});
```
