# Flutter State Management — Comprehensive Guide

## Table of Contents

- [Overview](#overview)
- [Choosing a State Management Solution](#choosing-a-state-management-solution)
- [Riverpod 2.x](#riverpod-2x)
  - [Core Concepts](#core-concepts)
  - [Provider Types](#provider-types)
  - [Code Generation (@riverpod)](#code-generation-riverpod)
  - [Notifiers and AsyncNotifiers](#notifiers-and-asyncnotifiers)
  - [AsyncValue Pattern](#asyncvalue-pattern)
  - [Provider Modifiers](#provider-modifiers)
  - [Dependency Injection with Riverpod](#dependency-injection-with-riverpod)
  - [Testing Riverpod](#testing-riverpod)
- [Bloc / Cubit Pattern](#bloc--cubit-pattern)
  - [Cubit — Simple State](#cubit--simple-state)
  - [Bloc — Event-Driven](#bloc--event-driven)
  - [Bloc Widgets](#bloc-widgets)
  - [Bloc-to-Bloc Communication](#bloc-to-bloc-communication)
  - [Testing Blocs](#testing-blocs)
- [Provider (Legacy)](#provider-legacy)
  - [ChangeNotifierProvider](#changenotifierprovider)
  - [FutureProvider / StreamProvider](#futureprovider--streamprovider)
  - [ProxyProvider](#proxyprovider)
  - [Migrating from Provider to Riverpod](#migrating-from-provider-to-riverpod)
- [Comparison Matrix](#comparison-matrix)
- [State Restoration](#state-restoration)
- [Common Mistakes](#common-mistakes)
- [Decision Flowchart](#decision-flowchart)

---

## Overview

State management is the backbone of any non-trivial Flutter app. Flutter's reactive framework
rebuilds widgets when state changes, so managing *what* state exists, *where* it lives, and *when*
it changes directly impacts app correctness, performance, and testability.

**Categories of state:**

| Category | Scope | Examples | Typical Solution |
|----------|-------|----------|-----------------|
| Ephemeral / Local | Single widget | Animation progress, form field focus | `setState`, hooks |
| Shared / App | Multiple widgets / screens | Auth status, cart, theme | Riverpod, Bloc, Provider |
| Server / Remote | Backend synced | API data, real-time streams | Riverpod AsyncNotifier, Bloc |
| Navigation | Routing | Current route, deep link state | GoRouter, Navigator 2.0 |
| Persistent | Survives restarts | User preferences, offline cache | Hive, Isar, drift + state mgmt |

**Guiding principles:**

1. State should be as local as possible, as global as necessary.
2. UI code should never contain business logic.
3. State mutations should be explicit and traceable.
4. State management should make testing easier, not harder.
5. Prefer immutable state objects — use `freezed` or records for state classes.

---

## Choosing a State Management Solution

| Factor | Riverpod | Bloc/Cubit | Provider |
|--------|----------|------------|----------|
| Learning curve | Medium | Medium-High | Low |
| Boilerplate | Low (with codegen) | Medium-High | Low |
| Testability | Excellent | Excellent | Good |
| DevTools support | riverpod_lint | bloc_devtools | Limited |
| Scalability | Excellent | Excellent | Fair |
| Compile-safe | Yes (codegen) | Yes (sealed events) | No |
| Community size | Growing fast | Large, enterprise | Large but declining |
| Recommended for | New projects, all sizes | Enterprise, event-heavy | Legacy, simple apps |

**Quick decision:**
- **New project, any size → Riverpod** (with code generation)
- **Enterprise, strict event audit trail → Bloc**
- **Existing Provider codebase, no budget to migrate → keep Provider**
- **Simple prototype → Riverpod (simpler providers) or even `setState`**

---

## Riverpod 2.x

### Core Concepts

Riverpod is a reactive caching and dependency injection framework. Unlike Provider, it is
**compile-safe**, does not depend on `BuildContext` for provider access, and supports
**auto-dispose**, **family modifiers**, and **code generation**.

**Setup:**
```yaml
dependencies:
  flutter_riverpod: ^2.5.0
  riverpod_annotation: ^2.3.0

dev_dependencies:
  riverpod_generator: ^2.4.0
  build_runner: ^2.4.0
  riverpod_lint: ^2.3.0
```

**App bootstrap:**
```dart
void main() {
  runApp(const ProviderScope(child: MyApp()));
}
```

Every Riverpod app needs a root `ProviderScope`. All providers are lazily initialized and globally
accessible without `BuildContext`.

### Provider Types

| Type | Use Case | Creates |
|------|----------|---------|
| `Provider` | Computed / derived values, DI | Synchronous value |
| `FutureProvider` | One-shot async data | `AsyncValue<T>` |
| `StreamProvider` | Reactive stream data | `AsyncValue<T>` |
| `NotifierProvider` | Mutable sync state with logic | `Notifier<T>` |
| `AsyncNotifierProvider` | Mutable async state with logic | `AsyncNotifier<T>` |
| `StateProvider` | Simple mutable value (deprecated) | `T` |
| `StateNotifierProvider` | Complex mutable state (deprecated) | `StateNotifier<T>` |

**Prefer Notifier/AsyncNotifier over deprecated StateNotifier.**

### Code Generation (@riverpod)

Code generation eliminates manual provider type selection and reduces boilerplate.

**Functional provider (read-only):**
```dart
@riverpod
Future<List<Product>> products(Ref ref) async {
  final repo = ref.watch(productRepositoryProvider);
  return repo.fetchAll();
}
// Generated: productsProvider (AutoDisposeFutureProvider<List<Product>>)
```

**Class-based provider (mutable state):**
```dart
@riverpod
class CartNotifier extends _$CartNotifier {
  @override
  Cart build() => const Cart.empty();

  void addItem(Product p) => state = state.copyWith(
    items: [...state.items, p],
  );

  void removeItem(String id) => state = state.copyWith(
    items: state.items.where((i) => i.id != id).toList(),
  );

  double get total => state.items.fold(0, (sum, i) => sum + i.price);
}
// Generated: cartNotifierProvider (AutoDisposeNotifierProvider<CartNotifier, Cart>)
```

**Family provider (parameterized):**
```dart
@riverpod
Future<Product> product(Ref ref, String id) async {
  final repo = ref.watch(productRepositoryProvider);
  return repo.fetchById(id);
}
// Usage: ref.watch(productProvider('abc-123'))
```

**Keep alive (disable auto-dispose):**
```dart
@Riverpod(keepAlive: true)
Future<AuthState> authState(Ref ref) async {
  // This provider persists even when no longer listened to
  return ref.watch(authRepositoryProvider).currentState();
}
```

Run generation: `dart run build_runner build --delete-conflicting-outputs`

### Notifiers and AsyncNotifiers

**Notifier** — synchronous mutable state:
```dart
@riverpod
class ThemeMode extends _$ThemeMode {
  @override
  ThemeMode build() => ThemeMode.system;

  void toggle() => state = state == ThemeMode.light
      ? ThemeMode.dark
      : ThemeMode.light;
}
```

**AsyncNotifier** — async mutable state:
```dart
@riverpod
class UserProfile extends _$UserProfile {
  @override
  Future<User> build() async {
    final repo = ref.watch(userRepositoryProvider);
    return repo.getCurrentUser();
  }

  Future<void> updateName(String name) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final repo = ref.read(userRepositoryProvider);
      return repo.updateUser(name: name);
    });
  }
}
```

**Key patterns:**
- `build()` defines the initial state and is re-run when dependencies change.
- Use `ref.watch()` inside `build()` — auto-rebuilds when dependency changes.
- Use `ref.read()` inside methods — reads current value without subscribing.
- Use `ref.invalidateSelf()` to force rebuild from `build()`.
- Use `AsyncValue.guard()` for error handling in async mutations.

### AsyncValue Pattern

`AsyncValue<T>` is a sealed union of `AsyncData`, `AsyncLoading`, and `AsyncError`.

**In widgets:**
```dart
class ProductListPage extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productsAsync = ref.watch(productsProvider);

    return productsAsync.when(
      data: (products) => ListView.builder(
        itemCount: products.length,
        itemBuilder: (_, i) => ProductTile(products[i]),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => ErrorWidget.withDetails(message: err.toString()),
    );
  }
}
```

**Useful AsyncValue methods:**
- `.when()` — exhaustive pattern match
- `.whenOrNull()` — partial match, returns null for unhandled
- `.value` — data or null
- `.valueOrNull` — safe access without throwing
- `.hasValue` — true if data is available (even during refresh)
- `.isLoading` — true during initial load or refresh
- `.isRefreshing` — true if reloading while showing previous data

**Show previous data during refresh:**
```dart
productsAsync.when(
  skipLoadingOnRefresh: true, // keep showing old data
  data: (products) => ProductList(products),
  loading: () => const LoadingShimmer(),
  error: (e, _) => ErrorBanner(e),
);
```

### Provider Modifiers

**`.autoDispose`** — dispose when no longer listened to (default with codegen):
```dart
final myProvider = Provider.autoDispose<MyService>((ref) {
  final service = MyService();
  ref.onDispose(() => service.close());
  return service;
});
```

**`.family`** — parameterized providers:
```dart
final userProvider = FutureProvider.family<User, String>((ref, userId) async {
  return ref.watch(apiProvider).fetchUser(userId);
});
// Usage: ref.watch(userProvider('user-42'))
```

**Combining modifiers:**
```dart
final searchProvider = FutureProvider.autoDispose.family<List<Product>, String>(
  (ref, query) async {
    // Debounce
    await Future.delayed(const Duration(milliseconds: 300));
    if (ref.state.isRefreshing) return [];
    return ref.watch(apiProvider).search(query);
  },
);
```

### Dependency Injection with Riverpod

Use Riverpod as a DI container:
```dart
// Abstract repository
@riverpod
ProductRepository productRepository(Ref ref) {
  final dio = ref.watch(dioProvider);
  return ProductRepositoryImpl(dio);
}

// In tests, override:
final container = ProviderContainer(
  overrides: [
    productRepositoryProvider.overrideWithValue(MockProductRepository()),
  ],
);
```

### Testing Riverpod

**Unit testing providers:**
```dart
test('products provider returns data', () async {
  final container = ProviderContainer(
    overrides: [
      productRepositoryProvider.overrideWithValue(MockProductRepo()),
    ],
  );
  addTearDown(container.dispose);

  final products = await container.read(productsProvider.future);
  expect(products, hasLength(3));
});
```

**Widget testing with overrides:**
```dart
testWidgets('product list renders', (tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productsProvider.overrideWith((_) => [testProduct]),
      ],
      child: const MaterialApp(home: ProductListPage()),
    ),
  );

  expect(find.text(testProduct.name), findsOneWidget);
});
```

**Testing notifiers:**
```dart
test('CartNotifier adds items', () {
  final container = ProviderContainer();
  addTearDown(container.dispose);

  final notifier = container.read(cartNotifierProvider.notifier);
  notifier.addItem(testProduct);

  final cart = container.read(cartNotifierProvider);
  expect(cart.items, contains(testProduct));
});
```

---

## Bloc / Cubit Pattern

### Cubit — Simple State

Use Cubit when state transitions are simple and don't need event tracing.

```dart
class CounterCubit extends Cubit<int> {
  CounterCubit() : super(0);

  void increment() => emit(state + 1);
  void decrement() => emit(state - 1);
  void reset() => emit(0);
}
```

### Bloc — Event-Driven

Use Bloc when you need event logging, complex transitions, or event transformers.

```dart
// Events
sealed class AuthEvent {}
class LoginRequested extends AuthEvent {
  final String email;
  final String password;
  LoginRequested({required this.email, required this.password});
}
class LogoutRequested extends AuthEvent {}
class AuthCheckRequested extends AuthEvent {}

// States
sealed class AuthState {}
class AuthInitial extends AuthState {}
class AuthLoading extends AuthState {}
class Authenticated extends AuthState {
  final User user;
  Authenticated(this.user);
}
class Unauthenticated extends AuthState {}
class AuthFailure extends AuthState {
  final String message;
  AuthFailure(this.message);
}

// Bloc
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthRepository _repo;

  AuthBloc(this._repo) : super(AuthInitial()) {
    on<LoginRequested>(_onLogin);
    on<LogoutRequested>(_onLogout);
    on<AuthCheckRequested>(_onAuthCheck);
  }

  Future<void> _onLogin(LoginRequested event, Emitter<AuthState> emit) async {
    emit(AuthLoading());
    try {
      final user = await _repo.login(event.email, event.password);
      emit(Authenticated(user));
    } on AuthException catch (e) {
      emit(AuthFailure(e.message));
    }
  }

  Future<void> _onLogout(LogoutRequested event, Emitter<AuthState> emit) async {
    await _repo.logout();
    emit(Unauthenticated());
  }

  Future<void> _onAuthCheck(AuthCheckRequested event, Emitter<AuthState> emit) async {
    final user = await _repo.getCurrentUser();
    emit(user != null ? Authenticated(user) : Unauthenticated());
  }
}
```

**Event transformers:**
```dart
on<SearchQueryChanged>(
  _onSearchChanged,
  transformer: debounce(const Duration(milliseconds: 300)),
);

EventTransformer<T> debounce<T>(Duration duration) {
  return (events, mapper) => events.debounceTime(duration).switchMap(mapper);
}
```

### Bloc Widgets

```dart
// BlocBuilder — rebuilds UI on state change
BlocBuilder<AuthBloc, AuthState>(
  buildWhen: (prev, curr) => prev.runtimeType != curr.runtimeType,
  builder: (context, state) => switch (state) {
    AuthLoading() => const CircularProgressIndicator(),
    Authenticated(:final user) => Text('Hello ${user.name}'),
    AuthFailure(:final message) => Text('Error: $message'),
    _ => const LoginForm(),
  },
);

// BlocListener — side effects (navigation, snackbar)
BlocListener<AuthBloc, AuthState>(
  listenWhen: (prev, curr) => curr is Authenticated,
  listener: (context, state) {
    if (state is Authenticated) context.go('/home');
  },
  child: const LoginForm(),
);

// BlocConsumer — both build + listen
BlocConsumer<CartBloc, CartState>(
  listener: (context, state) {
    if (state.justAdded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item added')),
      );
    }
  },
  builder: (context, state) => CartView(items: state.items),
);
```

### Bloc-to-Bloc Communication

Use `BlocListener` or stream subscriptions — never reference one Bloc inside another.

```dart
// In a parent widget:
BlocListener<AuthBloc, AuthState>(
  listener: (context, state) {
    if (state is Unauthenticated) {
      context.read<CartBloc>().add(CartCleared());
    }
  },
  child: const AppView(),
);
```

### Testing Blocs

Use `bloc_test` package:
```dart
blocTest<AuthBloc, AuthState>(
  'emits [AuthLoading, Authenticated] on successful login',
  build: () {
    when(() => mockRepo.login(any(), any()))
        .thenAnswer((_) async => testUser);
    return AuthBloc(mockRepo);
  },
  act: (bloc) => bloc.add(LoginRequested(email: 'a@b.com', password: '123')),
  expect: () => [
    isA<AuthLoading>(),
    isA<Authenticated>().having((s) => s.user, 'user', testUser),
  ],
  verify: (_) {
    verify(() => mockRepo.login('a@b.com', '123')).called(1);
  },
);
```

---

## Provider (Legacy)

### ChangeNotifierProvider

```dart
class CartModel extends ChangeNotifier {
  final List<Product> _items = [];
  List<Product> get items => List.unmodifiable(_items);

  void add(Product p) {
    _items.add(p);
    notifyListeners();
  }

  void remove(String id) {
    _items.removeWhere((p) => p.id == id);
    notifyListeners();
  }
}

// In widget tree:
ChangeNotifierProvider(
  create: (_) => CartModel(),
  child: const ShopPage(),
);

// Consuming:
final cart = context.watch<CartModel>(); // rebuilds on change
context.read<CartModel>().add(product);   // no rebuild
final itemCount = context.select<CartModel, int>((c) => c.items.length); // selective
```

### FutureProvider / StreamProvider

```dart
FutureProvider<User>(
  create: (_) => ApiService().fetchCurrentUser(),
  child: Consumer<User>(
    builder: (_, user, __) => Text(user.name),
  ),
);
```

### ProxyProvider

Derive one provider from another:
```dart
ProxyProvider<AuthService, ApiClient>(
  update: (_, auth, __) => ApiClient(token: auth.token),
);
```

### Migrating from Provider to Riverpod

| Provider | Riverpod Equivalent |
|----------|-------------------|
| `ChangeNotifierProvider` | `NotifierProvider` |
| `FutureProvider` | `FutureProvider` / `AsyncNotifierProvider` |
| `StreamProvider` | `StreamProvider` |
| `ProxyProvider` | Use `ref.watch()` inside provider |
| `context.watch<T>()` | `ref.watch(provider)` |
| `context.read<T>()` | `ref.read(provider)` |
| `context.select<T, R>()` | `ref.watch(provider.select((s) => s.field))` |
| `Consumer<T>` | `Consumer` (Riverpod's) |
| `MultiProvider` | `ProviderScope` (no listing needed) |

**Migration steps:**
1. Add `flutter_riverpod` dependency.
2. Wrap root with `ProviderScope` (can coexist with `MultiProvider`).
3. Convert one provider at a time, starting with leaf providers.
4. Replace `context.watch/read` with `ref.watch/read` in converted widgets.
5. Convert widget classes to `ConsumerWidget` / `ConsumerStatefulWidget`.
6. Remove Provider dependency after full migration.

---

## Comparison Matrix

| Feature | Riverpod | Bloc | Provider |
|---------|----------|------|----------|
| No BuildContext needed | ✅ | ❌ | ❌ |
| Compile-safe | ✅ (codegen) | ✅ (sealed) | ❌ |
| Auto-dispose | ✅ | ❌ (manual) | ❌ |
| Family/parameterized | ✅ | ❌ (manual) | ❌ |
| DevTools | ✅ (riverpod_lint) | ✅ (bloc inspector) | ❌ |
| Event traceability | ❌ | ✅ (events) | ❌ |
| Code generation | ✅ | ❌ | ❌ |
| Built-in async support | ✅ (AsyncValue) | ✅ (emit.forEach) | Partial |
| Undo/redo | ❌ | ✅ (replay_bloc) | ❌ |
| Global state | ✅ | ✅ (via DI) | ✅ |
| Nested/scoped state | ✅ (overrides) | ✅ (nested BlocProviders) | ✅ |
| Hot reload safe | ✅ | ✅ | ✅ |
| Test isolation | ✅ (ProviderContainer) | ✅ (constructor DI) | Fair |

---

## State Restoration

Preserve state across app kills (Android process death, iOS eviction).

**RestorationMixin approach:**
```dart
class CounterPage extends StatefulWidget {
  const CounterPage({super.key});
  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> with RestorationMixin {
  final RestorableInt _counter = RestorableInt(0);

  @override
  String? get restorationId => 'counter_page';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_counter, 'counter');
  }

  @override
  void dispose() {
    _counter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text('Count: ${_counter.value}');
  }
}
```

**For complex state**, persist to local storage (Hive/SharedPreferences) and rehydrate
on app start. Bloc supports `HydratedBloc` for automatic state persistence.

```dart
class SettingsBloc extends HydratedBloc<SettingsEvent, SettingsState> {
  SettingsBloc() : super(const SettingsState.defaults());

  @override
  SettingsState fromJson(Map<String, dynamic> json) =>
      SettingsState.fromJson(json);

  @override
  Map<String, dynamic> toJson(SettingsState state) => state.toJson();
}
```

---

## Common Mistakes

1. **Using `ref.watch` in callbacks** — causes unnecessary rebuilds. Use `ref.read` in
   `onPressed`, `onTap`, etc.
2. **Not disposing controllers** — leads to memory leaks. Always `dispose()` stream
   subscriptions, animation controllers, text controllers.
3. **Overusing global state** — not everything needs a provider. Form field values, animation
   state, and scroll position are local state.
4. **Mutating state directly** — always create new state objects. Never modify a list/map in
   place and call `notifyListeners()`.
5. **Not using `select`** — watching an entire provider when only one field is needed causes
   unnecessary widget rebuilds.
6. **Putting Blocs in widgets** — Blocs belong in `BlocProvider`, created above the widget
   that uses them.
7. **Ignoring `buildWhen`/`listenWhen`** — filtering state changes prevents unnecessary
   rebuilds and side effects.
8. **Creating providers inside build()** — providers must be top-level or in `ProviderScope`.

---

## Decision Flowchart

```
Need state management?
├── State used by single widget only?
│   └── YES → setState or hooks
├── Simple value toggle (bool, enum, int)?
│   └── YES → Riverpod StateProvider or NotifierProvider
├── Async data from API/DB?
│   ├── Read-only → Riverpod FutureProvider/StreamProvider
│   └── Read-write → Riverpod AsyncNotifierProvider
├── Complex business logic with event audit trail?
│   └── YES → Bloc
├── Need undo/redo?
│   └── YES → Bloc with replay_bloc
├── Enterprise team with strict architecture requirements?
│   └── YES → Bloc
└── Default → Riverpod with code generation
```
