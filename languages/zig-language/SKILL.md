---
name: zig-language
description: >
  Use when writing, reviewing, debugging, or explaining Zig code (.zig files). Triggers on: Zig
  source files, build.zig, build.zig.zon, zig build, zig test, zig run, allocators (GeneralPurposeAllocator,
  ArenaAllocator, FixedBufferAllocator, page_allocator), comptime, error unions, tagged unions, slices,
  @cImport, @cInclude, translate-c, cross-compilation, zig fetch, std.mem, std.fs, std.net, std.json,
  optionals, errdefer, @typeInfo, @Type, @branchHint, labeled switch. Also triggers when comparing Zig
  with C, Rust, or Go. DO NOT trigger for: generic "zig-zag" references, Apache ZIG project, Zigbee
  protocol, non-programming uses of the word "zig", or files that merely mention Zig in comments
  without containing Zig code.
---

# Zig Language Skill

## Philosophy

- **No hidden control flow.** No operator overloading, no implicit function calls. `for` and `while` only.
- **No hidden allocators.** Memory allocation is explicit via allocator parameters passed to every function that needs them.
- **Comptime over runtime.** Generics and metaprogramming use compile-time execution, not macros or templates.
- **Interop-first.** Direct C ABI compatibility. Import C headers with `@cImport`. Use Zig as a drop-in C compiler.
- **Simple to read.** No exceptions, no inheritance, no method overloading. One obvious way to do things.

## Setup and Commands

```sh
zig version              # e.g. 0.14.0
zig init                 # Creates build.zig, build.zig.zon, src/main.zig, src/root.zig
zig build                # Build project
zig build run            # Build and run
zig build test           # Run all tests
zig run src/main.zig     # Compile+run single file
zig test src/main.zig    # Test single file
zig fmt src/             # Auto-format
zig build -Doptimize=ReleaseFast  # Optimized build
```

Project layout: `build.zig` (build config as Zig code), `build.zig.zon` (package manifest), `src/main.zig` (entry), `src/root.zig` (library root).

## Types and Variables

```zig
const x: i32 = 42;          // immutable (preferred)
var y: u64 = 0;              // mutable
y += 1;
const z = @as(f64, 3.14);   // type inference with cast
// Integers: i8..i128, u8..u128, usize, isize
// Floats: f16, f32, f64, f128
// Pointers: *T (single), [*]T (many), ?*T (optional)
// Slices: []T, []const T
```

## Optionals

```zig
var maybe: ?i32 = null;
maybe = 42;
const val = maybe orelse 0;               // unwrap with default
if (maybe) |value| { use(value); }        // payload capture
const ptr: ?*i32 = &some_var;
if (ptr) |p| { p.* = 10; }               // optional pointer unwrap
```

## Error Handling

```zig
const FileError = error{ NotFound, PermissionDenied };

fn readFile(path: []const u8) FileError![]u8 {
    if (path.len == 0) return error.NotFound;
    // ...
}
const data = try readFile("config.txt");   // unwrap or propagate
const data2 = readFile("x") catch |err| {  // handle inline
    std.log.err("failed: {}", .{err});
    return;
};

// errdefer: cleanup ONLY on error return path
fn init(allocator: std.mem.Allocator) !*Resource {
    const buf = try allocator.alloc(u8, 1024);
    errdefer allocator.free(buf);
    const res = try allocator.create(Resource);
    res.* = .{ .buf = buf };
    return res;
}

// Error sets: named, inferred (!T), merged (A || B)
// Avoid anyerror in APIs — use specific error sets for exhaustive switch.
```

## Structs, Enums, Tagged Unions

```zig
const Point = struct {
    x: f64, y: f64, z: f64 = 0.0,
    pub fn distance(self: Point, other: Point) f64 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};
const p = Point{ .x = 1.0, .y = 2.0 }; // p.z == 0.0

const Color = enum(u8) { red = 0, green = 1, blue = 2 };
const c: Color = .green;

const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    none,
};
// Exhaustive switch required on tagged unions:
switch (v) {
    .int => |i| use(i),
    .float => |f| use(f),
    .string => |s| use(s),
    .none => {},
}
```

## Slices and Arrays

```zig
const arr: [5]u8 = .{ 1, 2, 3, 4, 5 };
const slice: []const u8 = arr[1..4];     // elements [2, 3, 4]
const greeting: []const u8 = "hello";    // string literals are []const u8
const c_str: [:0]const u8 = "hello";     // null-terminated for C interop

for (slice) |byte| { ... }               // iterate values
for (slice, 0..) |byte, idx| { ... }     // with index
```

## Comptime

### Compile-Time Evaluation
```zig
const len = comptime blk: {
    var x: usize = 0;
    for ("hello") |_| x += 1;
    break :blk x;
}; // len == 5 at compile time

fn fibonacci(n: u32) u32 {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}
const fib10 = comptime fibonacci(10); // evaluated at compile time
```

### Generics via Comptime
```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}
const r = max(i32, 10, 20); // 20

// Generic data structure — returns a new type
fn Stack(comptime T: type) type {
    return struct {
        items: []T,
        count: usize,
        allocator: std.mem.Allocator,
        const Self = @This();
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            self.count -= 1;
            return self.items[self.count];
        }
    };
}
```

### Type Reflection
```zig
fn printFields(comptime T: type) void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            for (s.fields) |field| {
                std.debug.print("{s}: {}\n", .{ field.name, field.type });
            }
        },
        else => @compileError("expected struct"),
    }
}

// Create types dynamically
fn Bigger(comptime T: type) type {
    return @Type(.{ .int = .{
        .bits = @typeInfo(T).int.bits + 1,
        .signedness = @typeInfo(T).int.signedness,
    } });
}
// Bigger(u8) == u9
```

## Memory Management

No GC. No implicit allocation. Pass allocators explicitly to every function that allocates.

### GeneralPurposeAllocator — default choice, leak detection in debug
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();
const buf = try allocator.alloc(u8, 256);
defer allocator.free(buf);
```

### ArenaAllocator — many allocs, single bulk free
```zig
var arena = std.heap.ArenaAllocator.init(parent_alloc);
defer arena.deinit();  // frees everything
const alloc = arena.allocator();
_ = try alloc.alloc(u8, 4096); // no individual free needed
```

### FixedBufferAllocator — stack/embedded, no heap
```zig
var buf: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);
const alloc = fba.allocator();
```

### page_allocator — direct OS pages
```zig
const mem = try std.heap.page_allocator.alloc(u8, 4096);
defer std.heap.page_allocator.free(mem);
```

**Rule:** Accept `std.mem.Allocator` as parameter. Never hide allocations.
```zig
// GOOD: pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Doc
// BAD:  pub fn parse(input: []const u8) !Doc  // hidden allocator
```

## Testing

```zig
const std = @import("std");
const expect = std.testing.expect;

fn add(a: i32, b: i32) i32 { return a + b; }

test "addition" {
    try expect(add(2, 3) == 5);
}
test "string equality" {
    try expect(std.mem.eql(u8, "hello", "hello"));
}
test "no leaks" {
    const alloc = std.testing.allocator; // fails test on leak
    const buf = try alloc.alloc(u8, 100);
    defer alloc.free(buf);
}
// Run: zig test src/main.zig → "All 3 tests passed."
```

## C Interop

```zig
// Import C headers directly
const c = @cImport({ @cInclude("stdio.h"); @cInclude("mylib.h"); });
_ = c.printf("Hello from C\n");

// In build.zig — link C libs and sources
exe.linkLibC();
exe.linkSystemLibrary("sqlite3");
exe.addIncludePath(b.path("include/"));
exe.addCSourceFiles(.{ .files = &.{"src/helper.c"}, .flags = &.{"-std=c11"} });
```

```sh
# One-shot header translation
zig translate-c myheader.h > myheader.zig
```

C type mappings: `c_int`, `c_uint`, `c_long`, `c_char`. C pointer type: `[*c]T`.

## Build System (build.zig)

`build.zig` is executable Zig code, not a config file.

```zig
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target, .optimize = optimize,
    });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
```

## Package Management (build.zig.zon)

```zig
.{
    .name = .myproject,
    .version = "0.1.0",
    .fingerprint = 0xABCD1234,
    .dependencies = .{
        .zap = .{
            .url = "https://github.com/zigzap/zap/archive/refs/tags/v0.2.0.tar.gz",
            .hash = "1220abc123...",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

```sh
zig fetch --save git+https://github.com/author/lib#v1.0.0  # auto-adds to .zon
```

Use in build.zig:
```zig
const dep = b.dependency("zap", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zap", dep.module("zap"));
```

## Cross-Compilation

Zero-setup cross-compilation. No external toolchains required.

```sh
zig build -Dtarget=aarch64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=x86_64-macos
zig build -Dtarget=wasm32-wasi
```

Use `b.standardTargetOptions(.{})` in build.zig to accept `-Dtarget`.

## Standard Library

```zig
// std.mem
std.mem.eql(u8, a, b);                    // slice equality
std.mem.indexOf(u8, haystack, needle);     // find substring
// std.fs
const file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();
const contents = try file.readToEndAlloc(allocator, 1 << 20);
// std.json
const parsed = try std.json.parseFromSlice(MyStruct, allocator, json_str, .{});
defer parsed.deinit();
// std.ArrayList
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.appendSlice("hello");
// std.HashMap
var map = std.StringHashMap(i32).init(allocator);
defer map.deinit();
try map.put("key", 42);
// std.log
std.log.info("port {}", .{port});
// std.fmt
var buf: [256]u8 = undefined;
const s = try std.fmt.bufPrint(&buf, "x={d:.2}", .{3.14});
```

## Concurrency

Async/await was removed (experimental, unfinished). Use `std.Thread`:

```zig
fn worker(id: usize) void {
    std.debug.print("worker {}\n", .{id});
}
pub fn main() !void {
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, worker, .{i});
    }
    for (&threads) |t| t.join();
}
```

Synchronization: `std.Thread.Mutex`, `std.Thread.Condition`, `std.atomic`.

## Labeled Switch (0.14+)

```zig
// State machine pattern
const result = sw: switch (state) {
    .start => continue :sw .parsing,
    .parsing => continue :sw .done,
    .done => break :sw 42,
};
```

## Zig vs C vs Rust vs Go

| Aspect | Zig | C | Rust | Go |
|---|---|---|---|---|
| Memory | Explicit allocators | Manual | Borrow checker | GC |
| Generics | comptime | Macros | Traits | Type params |
| Errors | Error unions | errno | Result<T,E> | Multi-return |
| Build | Built-in | Make/CMake | Cargo | go build |
| C interop | Native | N/A | FFI unsafe | cgo |
| Cross-compile | Built-in | Toolchains | Cross crate | GOOS/GOARCH |

## Common Pitfalls

1. **Forgetting `defer` for cleanup.** Always pair `alloc`/`create` with `defer free`/`destroy`.
2. **Using `anyerror` in APIs.** Use specific error sets for exhaustive switch.
3. **Dangling slices.** Slices don't own memory. Document lifetimes or return caller-freed `[]u8`.
4. **Ignoring return values.** Discard explicitly: `_ = expr;`.
5. **`@intCast` overflow.** UB in ReleaseFast. Use `std.math.cast` for safe narrowing.
6. **Mixing allocators.** Free with the same allocator that allocated.
7. **Missing `.{}` in print.** `std.debug.print("hi\n", .{});` — tuple arg always required.
8. **`==` on slices.** Compares pointers. Use `std.mem.eql(u8, a, b)` for content.
9. **Comptime vs runtime.** Cannot pass runtime values to `comptime` parameters.

## References

Deep-dive guides in `references/`:

- **[Advanced Patterns](references/advanced-patterns.md)** — Comptime metaprogramming (`@typeInfo`, `@Type`, type functions), generic data structures, custom allocator implementation, SIMD with `@Vector`, inline assembly, packed structs, sentinel-terminated types, error traces, and safety checks.
- **[Troubleshooting](references/troubleshooting.md)** — Common compiler errors decoded, undefined behavior in release modes, C interop failures, build system errors, dependency management issues, memory leak detection with GPA, OOM debugging, GDB/LLDB/Valgrind integration.
- **[C Interop Guide](references/c-interop-guide.md)** — Comprehensive C interop: `@cImport`, `translate-c`, calling C from Zig, calling Zig from C, linking system libraries, pkg-config, wrapping C APIs idiomatically, C strings, void pointers, function pointers, variadic functions, type mappings.

## Scripts

Helper scripts in `scripts/` (run with `bash` or `./`):

- **[init-project.sh](scripts/init-project.sh)** — Initialize a new Zig project with `build.zig`, source structure, tests, and `.gitignore`. Supports `--exe` (default) and `--lib` modes.
- **[cross-compile.sh](scripts/cross-compile.sh)** — Cross-compile for multiple targets (Linux x86_64/aarch64, macOS, Windows). Configurable optimization and output directory.
- **[benchmark.sh](scripts/benchmark.sh)** — Run Zig benchmarks with `std.time`, reporting min/mean/max. Supports text/CSV/JSON output and comparison against previous runs.

## Assets

Templates and configs in `assets/`:

- **[build.zig](assets/build.zig)** — Complete build template with executable, static/shared library, tests, benchmarks, cross-compilation, C interop, and documentation steps.
- **[build.zig.zon](assets/build.zig.zon)** — Package manifest template with dependency examples (URL, git, local path).
- **[main.zig](assets/main.zig)** — Starter main with arg parsing, file I/O, directory listing, logging, allocator setup with leak detection.
- **[Dockerfile](assets/Dockerfile)** — Multi-stage Dockerfile for Zig development and CI (Alpine-based, multi-arch).
<!-- tested: pass -->
