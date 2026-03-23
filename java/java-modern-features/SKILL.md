---
name: java-modern-features
description:
  positive: "Use when user writes modern Java (17+), asks about records, sealed classes, pattern matching (switch/instanceof), virtual threads, structured concurrency, text blocks, or Java 21+ features."
  negative: "Do NOT use for Spring Boot specifics (use spring-boot-patterns skill), Kotlin, Scala, or legacy Java 8 migration guides."
---

# Modern Java Features (17–24)

## Records (Java 16+, finalized)

Use records for immutable data carriers. They auto-generate `equals`, `hashCode`, `toString`, canonical constructor, and accessors.

```java
// Basic record
record Point(int x, int y) {}

// Compact constructor — validate without repeating field assignments
record Range(int lo, int hi) {
    Range {
        if (lo > hi) throw new IllegalArgumentException("lo > hi");
    }
}

// Custom canonical constructor
record Email(String value) {
    Email(String value) {
        this.value = value.toLowerCase().strip();
    }
}

// Local records — use inside methods for intermediate transformations
List<String> topNames(List<Employee> employees) {
    record NameSalary(String name, int salary) {}
    return employees.stream()
        .map(e -> new NameSalary(e.name(), e.salary()))
        .sorted(Comparator.comparingInt(NameSalary::salary).reversed())
        .map(NameSalary::name)
        .toList();
}
```

**Limitations:** Records cannot extend classes (they implicitly extend `Record`). Fields are final — no setters. Cannot declare instance fields beyond components. Use records for data, not behavior-heavy objects.

## Sealed Classes and Interfaces (Java 17+)

Restrict which classes can extend or implement a type. Enable exhaustive `switch`.

```java
// Sealed interface with permitted subtypes
sealed interface Shape permits Circle, Rectangle, Triangle {}
record Circle(double radius) implements Shape {}
record Rectangle(double w, double h) implements Shape {}
final class Triangle implements Shape {
    double base, height;
    Triangle(double base, double height) {
        this.base = base;
        this.height = height;
    }
}

// Exhaustive switch — compiler verifies all subtypes handled
double area(Shape s) {
    return switch (s) {
        case Circle c    -> Math.PI * c.radius() * c.radius();
        case Rectangle r -> r.w() * r.h();
        case Triangle t  -> 0.5 * t.base * t.height;
    };
}
```

**Design rules:** Permitted subtypes must be `final`, `sealed`, or `non-sealed`. Place subtypes in the same package (or same module). Combine sealed types with records for algebraic data types.

## Pattern Matching

### instanceof Patterns (Java 16+)

```java
// Eliminate manual casts
if (obj instanceof String s && s.length() > 5) {
    System.out.println(s.toUpperCase());
}
```

### Switch Patterns (Java 21+, finalized)

```java
String describe(Object obj) {
    return switch (obj) {
        case Integer i when i > 0 -> "positive int: " + i;
        case Integer i            -> "non-positive int: " + i;
        case String s             -> "string: " + s;
        case null                 -> "null";
        default                   -> "other: " + obj;
    };
}
```

### Record Patterns (Java 21+, finalized)

Deconstruct records directly in patterns:

```java
record Pair<A, B>(A first, B second) {}

String format(Object obj) {
    return switch (obj) {
        case Pair(String a, String b) -> a + " & " + b;
        case Pair(Integer a, Integer b) -> "sum=" + (a + b);
        default -> obj.toString();
    };
}
```

### Unnamed Patterns and Variables (Java 22+)

Use `_` when you intentionally discard a value:

```java
// Unnamed variable in enhanced for
for (var _ : collection) { count++; }
// Unnamed pattern in switch
case Pair(String name, _) -> "name=" + name;
// Unnamed in catch
try { /* ... */ } catch (Exception _) { handleDefault(); }
```

### Primitive Patterns (Java 23+ preview, Java 24 preview)

Use primitives in `instanceof` and `switch` patterns:

```java
String classify(Object obj) {
    return switch (obj) {
        case int i when i > 0 -> "positive";
        case int i            -> "non-positive";
        default               -> "not an int";
    };
}
```

## Text Blocks (Java 17+)

Triple-quoted strings for multi-line content. The compiler strips common leading whitespace.

```java
String json = """
        {
            "name": "%s",
            "age": %d
        }
        """.formatted(name, age);

// Escape sequences
String html = """
        <p>Line one\
         continues here</p>
        <p>Trailing spaces preserved:\s\s</p>
        """;
```

**Rules:** Opening `"""` must be followed by a newline. Use `\` at line end to suppress the newline. Use `\s` to preserve trailing whitespace. Prefer `.formatted()` over `String.format()` with text blocks.

## Switch Expressions (Java 17+)

```java
// Arrow syntax — no fall-through
int numLetters = switch (day) {
    case MONDAY, FRIDAY, SUNDAY -> 6;
    case TUESDAY                -> 7;
    case WEDNESDAY, THURSDAY    -> 8;
    case SATURDAY               -> 9;
};

// yield for block expressions
String description = switch (status) {
    case ACTIVE -> "active";
    case INACTIVE -> {
        log("inactive case hit");
        yield "inactive";
    }
    default -> "unknown";
};
```

Switch expressions require exhaustiveness — cover all cases or include `default`. With sealed types, the compiler checks completeness without `default`.

## Virtual Threads (Java 21+, finalized)

Lightweight JVM-managed threads. Use for blocking I/O workloads. Do not pool them.

```java
// Start a virtual thread
Thread.ofVirtual().name("worker").start(() -> {
    var result = fetchFromDatabase(); // blocking is fine
    process(result);
});

// Executor — one virtual thread per task
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    List<Future<String>> futures = urls.stream()
        .map(url -> executor.submit(() -> fetch(url)))
        .toList();
    for (var f : futures) {
        System.out.println(f.get());
    }
}

// Thread.ofVirtual().factory() for custom thread factories
ThreadFactory factory = Thread.ofVirtual().name("vt-", 0).factory();
```

**Guidelines:** Never pool virtual threads — create them freely. Avoid `synchronized` on hot paths with virtual threads (causes pinning; use `ReentrantLock` instead). Java 24 fixes most pinning issues (JEP 491). Virtual threads are ideal for servers, HTTP clients, and database calls.

## Structured Concurrency (Java 21+ preview, Java 24 4th preview)

Group concurrent tasks with well-defined lifecycles. Tasks are forked, joined, and cancelled together.

```java
// ShutdownOnFailure — cancel siblings if one fails
record UserProfile(String name, int balance) {}

UserProfile fetchProfile(long userId) throws Exception {
    try (var scope = StructuredTaskScope.open(
            StructuredTaskScope.Joiner.awaitAllSuccessfulOrThrow())) {
        var nameTask = scope.fork(() -> fetchName(userId));
        var balanceTask = scope.fork(() -> fetchBalance(userId));
        scope.join();
        return new UserProfile(nameTask.get(), balanceTask.get());
    }
}

// ShutdownOnSuccess — return first successful result
String fetchFastest(String query) throws Exception {
    try (var scope = StructuredTaskScope.open(
            StructuredTaskScope.Joiner.anySuccessfulResultOrThrow())) {
        scope.fork(() -> searchServiceA(query));
        scope.fork(() -> searchServiceB(query));
        return scope.join();
    }
}
```

**Benefits:** Automatic cancellation of incomplete subtasks on failure. Thread dumps show parent-child relationships. Prevents thread leaks by design.

## Scoped Values (Java 21+ preview, Java 24 4th preview)

Immutable context values bound to a scope. Safer and faster than `ThreadLocal`.

```java
private static final ScopedValue<String> REQUEST_ID = ScopedValue.newInstance();

void handleRequest(String id) {
    ScopedValue.where(REQUEST_ID, id).run(() -> {
        processRequest();  // REQUEST_ID.get() returns id
    });
}

void processRequest() {
    String id = REQUEST_ID.get();  // reads the bound value
    log("Processing request: " + id);
}

// Rebinding in nested scope
ScopedValue.where(REQUEST_ID, "outer").run(() -> {
    System.out.println(REQUEST_ID.get()); // "outer"
    ScopedValue.where(REQUEST_ID, "inner").run(() -> {
        System.out.println(REQUEST_ID.get()); // "inner"
    });
    System.out.println(REQUEST_ID.get()); // "outer" again
});
```

**Prefer over `ThreadLocal`:** Scoped values are immutable within a scope, automatically cleaned up, cheaper to create, and work correctly with virtual threads and structured concurrency.

## String Templates (Withdrawn in Java 23, not available in Java 24)

String templates (`STR`, `FMT`, `RAW`) were previewed in Java 21–22 (JEP 430, JEP 459) but **withdrawn** in Java 23 due to design concerns around composability and processor semantics. They are **not available** in Java 23 or 24.

**Current alternatives:**

```java
// Use String.formatted() or String.format()
String msg = "Hello, %s! You have %d items.".formatted(name, count);

// Use text blocks with .formatted()
String json = """
        {"user": "%s", "score": %d}
        """.formatted(user, score);

// Use MessageFormat for locale-aware formatting
String localized = MessageFormat.format("Price: {0,number,currency}", price);
```

Do not write code using `STR."..."` syntax — it will not compile on Java 23+. The feature may return in a redesigned form in Java 25+.

## Collections

### Immutable Factory Methods (Java 9+)

```java
var list = List.of(1, 2, 3);           // immutable list
var set = Set.of("a", "b", "c");       // immutable set
var map = Map.of("k1", 1, "k2", 2);   // immutable map (up to 10 entries)
var map2 = Map.ofEntries(              // immutable map (any size)
    Map.entry("k1", 1),
    Map.entry("k2", 2)
);
```

### SequencedCollections (Java 21+)

New interfaces: `SequencedCollection`, `SequencedSet`, `SequencedMap`. Provide `getFirst()`, `getLast()`, `reversed()`.

```java
SequencedCollection<String> names = new ArrayList<>(List.of("a", "b", "c"));
names.getFirst();   // "a"
names.getLast();     // "c"
names.reversed();   // view: ["c", "b", "a"]

SequencedMap<String, Integer> map = new LinkedHashMap<>();
map.firstEntry();
map.lastEntry();
map.reversed();
```

### Collectors

```java
var result = stream.collect(Collectors.toUnmodifiableList());
```

## Stream API Enhancements

### Stream.toList() and mapMulti (Java 16+)

```java
// Preferred over .collect(Collectors.toList()) — returns unmodifiable list
List<String> names = employees.stream().map(Employee::name).toList();

// mapMulti — inline flatMap replacement
List<Integer> evens = Stream.of(1, 2, 3, 4, 5)
    .<Integer>mapMulti((n, c) -> { if (n % 2 == 0) c.accept(n); })
    .toList(); // [2, 4]
```

### Gatherers (Java 24, finalized — JEP 485)

Custom intermediate stream operations. Built-in gatherers: `fold`, `scan`, `windowFixed`, `windowSliding`, `mapConcurrent`.

```java
import java.util.stream.Gatherers;

// Fixed-size windows
List<List<Integer>> windows = Stream.of(1, 2, 3, 4, 5)
    .gather(Gatherers.windowFixed(2))
    .toList(); // [[1,2], [3,4], [5]]

// Sliding windows
List<List<Integer>> sliding = Stream.of(1, 2, 3, 4)
    .gather(Gatherers.windowSliding(3))
    .toList(); // [[1,2,3], [2,3,4]]

// Scan — running accumulation
List<Integer> sums = Stream.of(1, 2, 3, 4)
    .gather(Gatherers.scan(() -> 0, Integer::sum))
    .toList(); // [1, 3, 6, 10]

// Fold — reduce to single value as stream
Stream.of(1, 2, 3)
    .gather(Gatherers.fold(() -> 0, Integer::sum))
    .toList(); // [6]

// mapConcurrent — parallel map with bounded concurrency
List<String> results = urls.stream()
    .gather(Gatherers.mapConcurrent(10, url -> fetch(url)))
    .toList();
```

## Foreign Function & Memory API (Java 22 finalized — JEP 454)

Replace JNI with a safe, modern API for native interop.

```java
import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;

// Allocate and use native memory
try (Arena arena = Arena.ofConfined()) {
    MemorySegment segment = arena.allocate(ValueLayout.JAVA_INT, 42);
    int value = segment.get(ValueLayout.JAVA_INT, 0); // 42
}

// Call a native C function (strlen)
Linker linker = Linker.nativeLinker();
SymbolLookup stdlib = linker.defaultLookup();
MethodHandle strlen = linker.downcallHandle(
    stdlib.find("strlen").orElseThrow(),
    FunctionDescriptor.of(ValueLayout.JAVA_LONG, ValueLayout.ADDRESS)
);

try (Arena arena = Arena.ofConfined()) {
    MemorySegment cStr = arena.allocateFrom("Hello");
    long len = (long) strlen.invoke(cStr); // 5
}
```

**Key types:** `Arena` manages memory lifecycle. `MemorySegment` represents a contiguous memory region. `Linker` bridges Java to native functions. `ValueLayout` defines data types.

## Unnamed Classes and Instance Main Methods (Java 21+ preview, Java 24 preview)

Simplify entry points for simple programs and scripts:

```java
// No class declaration needed, no static, no String[] args
void main() {
    System.out.println("Hello, World!");
}

// With args
void main(String[] args) {
    System.out.println("Args: " + args.length);
}
```

Compile and run with `java --enable-preview HelloWorld.java`. Useful for scripting, prototyping, and teaching.

## Migration Guide

### Java 11 → 17

- **Removed:** Nashorn JS engine, RMI Activation, Applet API, Security Manager (deprecated for removal).
- **Action:** Replace `javax.xml.bind` (JAXB) with Maven dependency `jakarta.xml.bind`. Replace `javax.annotation` with `jakarta.annotation`.
- **Strong encapsulation:** Internal APIs locked by default. Use `--add-opens` only as a temporary workaround.

```
# Temporary workaround for reflection access
java --add-opens java.base/java.lang=ALL-UNNAMED -jar app.jar
```

### Java 17 → 21

- **Finalized:** Virtual threads, record patterns, pattern matching for switch, sequenced collections.
- **Removed:** Finalizers deprecated for removal — use `Cleaner` or try-with-resources.
- **UTF-8 default:** `Charset.defaultCharset()` now returns UTF-8 on all platforms.
- **Action:** Replace thread pools for I/O-bound work with virtual threads. Replace `LinkedHashMap` first/last workarounds with `SequencedMap`.

### Java 21 → 24

- **Finalized:** Gatherers (Stream API), Foreign Function & Memory API.
- **Preview progressing:** Structured concurrency, scoped values, unnamed classes.
- **Withdrawn:** String templates — remove any usage from code.
- **Action:** Adopt `Gatherers` for complex stream operations. Replace JNI with Foreign Function & Memory API. Test virtual thread pinning fixes (JEP 491).

## Anti-Patterns

**Overusing records:**
- Do not use records for mutable entities or classes with significant behavior. Records are data carriers, not domain objects with complex state.
- Do not add many non-component methods to records — extract a proper class instead.

**Ignoring virtual threads:**
- Do not wrap blocking I/O in `CompletableFuture` chains when virtual threads are available. Use straightforward blocking code on virtual threads.
- Do not pool virtual threads — they are cheap to create and must not be reused via fixed-size pools.

**Legacy idioms to replace:**
```java
// BAD: manual instanceof + cast
if (obj instanceof String) {
    String s = (String) obj;
}
// GOOD: pattern matching
if (obj instanceof String s) { }

// BAD: verbose switch statement
switch (day) {
    case MONDAY: result = 1; break;
    case TUESDAY: result = 2; break;
}
// GOOD: switch expression
int result = switch (day) {
    case MONDAY -> 1;
    case TUESDAY -> 2;
    default -> 0;
};

// BAD: .collect(Collectors.toList())
// GOOD: .toList()

// BAD: ThreadLocal for request context
// GOOD: ScopedValue (when on Java 21+ preview)

// BAD: JNI for native calls
// GOOD: Foreign Function & Memory API (Java 22+)

// BAD: new Thread(runnable).start() for I/O tasks
// GOOD: Thread.ofVirtual().start(runnable)
```

**Other mistakes:** Using `synchronized` with virtual threads on hot paths (use `ReentrantLock`). Writing non-exhaustive `switch` over sealed types (omit `default` — let the compiler enforce completeness). Using `String.format()` inside loops (prefer `.formatted()`).

<!-- tested: pass -->
