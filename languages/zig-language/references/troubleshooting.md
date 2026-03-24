# Zig Troubleshooting Guide

## Table of Contents
- [Common Compiler Errors](#common-compiler-errors)
- [Undefined Behavior in Release Modes](#undefined-behavior-in-release-modes)
- [C Interop Issues](#c-interop-issues)
- [Build System Errors](#build-system-errors)
- [Dependency Management](#dependency-management)
- [Memory Debugging](#memory-debugging)
- [Runtime Debugging Techniques](#runtime-debugging-techniques)

---

## Common Compiler Errors

### "expected type 'X', found 'Y'"
The most frequent error. Common causes:
```zig
// Problem: passing wrong integer type
fn take(x: u32) void { _ = x; }
const val: u64 = 42;
take(val);  // ERROR: expected u32, found u64

// Fix: explicit cast
take(@intCast(val));
// Or use std.math.cast for safe narrowing (returns null on overflow)
take(std.math.cast(u32, val) orelse return error.Overflow);
```

### "use of undefined value"
```zig
// Problem: reading `undefined` memory
var buf: [10]u8 = undefined;
std.debug.print("{}", .{buf[0]});  // ERROR in Debug mode

// Fix: initialize or use @memset
var buf2: [10]u8 = .{0} ** 10;
// Or:
@memset(&buf, 0);
```

### "capture of comptime value"
```zig
// Problem: trying to use comptime value at runtime
fn process(comptime T: type, items: []const T) void {
    for (items) |item| {
        // Cannot capture T-related comptime info in a runtime loop context
        // if mixed with certain runtime operations
    }
}
// Fix: use `inline for` when iterating comptime-known sequences
inline for (std.meta.fields(T)) |field| { ... }
```

### "error is ignored"
```zig
// Problem: calling a function that returns an error union without handling it
const file = std.fs.cwd().openFile("x.txt", .{});  // ERROR

// Fix: use try, catch, or explicitly discard
const file1 = try std.fs.cwd().openFile("x.txt", .{});
const file2 = std.fs.cwd().openFile("x.txt", .{}) catch |err| { ... };
```

### "unused variable / unused capture"
```zig
// Problem: declared but not used
const x = computeValue();  // ERROR if x is never used

// Fix: discard explicitly
_ = computeValue();
// For loop captures:
for (items) |_| { ... }          // discard value
for (items, 0..) |_, _| { ... }  // discard both
```

### "pointer/slice to stack-allocated memory"
```zig
// Problem: returning pointer to local variable
fn bad() *u8 {
    var x: u8 = 42;
    return &x;  // ERROR: x is on the stack
}

// Fix: allocate on heap or accept a buffer parameter
fn good(allocator: std.mem.Allocator) !*u8 {
    const ptr = try allocator.create(u8);
    ptr.* = 42;
    return ptr;
}
```

### "cannot evaluate comptime expression"
```zig
// Problem: passing runtime value where comptime is needed
fn getField(comptime name: []const u8) void { ... }
var name_buf: [32]u8 = undefined;
getField(name_buf[0..n]);  // ERROR: n is runtime

// This is fundamental — you cannot pass runtime values to comptime parameters.
// Restructure: use a switch or lookup table instead of comptime dispatch.
```

### "division by zero" at comptime
```zig
// Zig evaluates divisions at comptime when both operands are known
const x = 10 / 0;  // compile error, not runtime crash

// Fix: guard the division
const divisor = if (d != 0) d else 1;
```

---

## Undefined Behavior in Release Modes

### The Core Problem

Debug and ReleaseSafe modes include runtime safety checks. ReleaseFast and ReleaseSmall **disable them** for performance. Bugs that panic in Debug silently corrupt in ReleaseFast.

### Common UB Sources

| UB Type | Debug Behavior | ReleaseFast Behavior |
|---|---|---|
| Out-of-bounds access | Panic with index | Memory corruption |
| Integer overflow | Panic | Wrapping arithmetic |
| Null pointer unwrap | Panic | Segfault or corruption |
| `unreachable` reached | Panic | Truly undefined — optimizer assumes impossible |
| Use after free | Panic (with GPA) | Silent corruption |
| Uninitialized read | Panic | Reads garbage |

### Debugging UB

**Step 1:** Always reproduce in Debug mode first:
```sh
zig build -Doptimize=Debug
# or for single file:
zig run -ODebug src/main.zig
```

**Step 2:** Use `@setRuntimeSafety(true)` to enable checks in specific hot spots:
```zig
fn criticalPath(data: []u8, idx: usize) u8 {
    @setRuntimeSafety(true);  // safety even in ReleaseFast
    return data[idx];
}
```

**Step 3:** Use ReleaseSafe as a middle ground for production:
```sh
zig build -Doptimize=ReleaseSafe  # optimized + safety checks
```

**Step 4:** Sanitize integer operations:
```zig
// Instead of @intCast (UB on overflow in release):
const safe = std.math.cast(u8, big_val) orelse return error.Overflow;

// Instead of default arithmetic (wrapping in release):
const result = std.math.add(u32, a, b) catch return error.Overflow;
```

---

## C Interop Issues

### @cImport Failures

**"unable to translate C expr":**
```
// Some C constructs can't be auto-translated:
// - Complex macros with side effects
// - Variadic macros
// - Certain preprocessor tricks

// Workaround: write Zig wrappers manually
// Instead of: c.COMPLEX_MACRO(x)
// Write a C helper:
// helper.c: int wrap_macro(int x) { return COMPLEX_MACRO(x); }
// Then call wrap_macro from Zig
```

**"file not found" in @cInclude:**
```zig
// Fix: add include paths in build.zig
exe.addIncludePath(b.path("include/"));
exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
// Or for pkg-config managed headers:
exe.linkSystemLibrary("libfoo");
```

**Multiple @cImport blocks causing duplicate symbols:**
```zig
// BAD: separate @cImport blocks create separate types
const c1 = @cImport({ @cInclude("a.h"); });
const c2 = @cImport({ @cInclude("b.h"); });
// c1.SomeStruct ≠ c2.SomeStruct even if same definition

// GOOD: single @cImport with all includes
const c = @cImport({
    @cInclude("a.h");
    @cInclude("b.h");
});
```

### Header Translation Issues

```sh
# Inspect what Zig generates from C headers
zig translate-c /usr/include/stdio.h 2>&1 | head -100

# Common issues:
# - Anonymous structs/unions get mangled names
# - Bitfields may not translate correctly
# - Inline functions may be skipped
# - Function-like macros become opaque

# Fix: manually translate problematic declarations
```

### Linking Problems

```zig
// "undefined reference to 'foo'"
// Causes:
// 1. Missing library link
exe.linkSystemLibrary("foo");         // dynamic
exe.addObjectFile(b.path("libfoo.a")); // static

// 2. Missing libc
exe.linkLibC();  // required for any C stdlib usage

// 3. Wrong library name (check pkg-config)
// $ pkg-config --libs openssl
// -lssl -lcrypto
exe.linkSystemLibrary("ssl");
exe.linkSystemLibrary("crypto");

// 4. Static vs dynamic mismatch on cross-compile
exe.linkSystemLibrary2("z", .{ .preferred_link_mode = .static });
```

### C String Handling

```zig
// C strings are [*:0]const u8, Zig strings are []const u8
const c_str: [*:0]const u8 = c.some_function();

// Convert C string to Zig slice
const zig_str: []const u8 = std.mem.span(c_str);

// Convert Zig slice to C string (must be null-terminated)
const c_compat: [:0]const u8 = try allocator.dupeZ(u8, zig_slice);
defer allocator.free(c_compat);
c.takes_c_string(c_compat.ptr);

// String literal shortcut (already null-terminated)
c.puts("hello");  // Zig string literals coerce to [*:0]const u8
```

---

## Build System Errors

### "no such file or directory" for source files
```zig
// build.zig paths are relative to the build.zig location
// Use b.path() for project-relative paths
exe.root_source_file = b.path("src/main.zig");  // GOOD
// Not: .{ .cwd_relative = "src/main.zig" }     // may break
```

### "step has no dependencies" / step ordering
```zig
// Problem: steps not wired together
const run_cmd = b.addRunArtifact(exe);
const run_step = b.step("run", "Run the app");
run_step.dependOn(&run_cmd.step);  // must connect!

// For sequential steps:
step_b.dependOn(&step_a.step);  // b runs after a
```

### Build cache corruption
```sh
# Nuclear option — clear all caches
rm -rf zig-cache/ .zig-cache/ zig-out/
# Then rebuild
zig build
```

### Cross-compilation build failures
```sh
# "unable to find system library" during cross-compile
# System libraries aren't available for foreign targets
# Fix: bundle the library source or use Zig-native alternatives

# In build.zig, conditionally link:
if (target.result.os.tag == .linux) {
    exe.linkSystemLibrary("epoll");
}
```

---

## Dependency Management

### build.zig.zon Issues

**Adding a dependency:**
```sh
# Preferred: auto-fetch and save
zig fetch --save git+https://github.com/author/lib#v1.0.0

# If hash mismatch:
# "hash mismatch: expected 1220abc... got 1220def..."
# The hash in your .zon is stale. Update it:
zig fetch --save git+https://github.com/author/lib#v1.0.1
```

**Wiring dependency in build.zig:**
```zig
// Common mistake: forgetting to wire the dependency module
const dep = b.dependency("mylib", .{
    .target = target,
    .optimize = optimize,
});
// Must add to the compilation:
exe.root_module.addImport("mylib", dep.module("mylib"));
```

**Dependency resolution failures:**
```sh
# "unable to fetch" — check URL is accessible
# "hash mismatch" — archive content changed, update hash
# "dependency loop" — circular deps not allowed

# Debug: inspect what zig fetch downloads
zig fetch --debug-log git+https://github.com/author/lib
```

### Version Conflicts

```zig
// Two deps depend on different versions of same lib:
// Zig doesn't have automatic version resolution.
// Fix: pin both to same version in top-level .zon,
// or use .paths to override with a local copy
.dependencies = .{
    .common_lib = .{
        .path = "vendor/common_lib",  // local override
    },
},
```

---

## Memory Debugging

### Detecting Leaks with GeneralPurposeAllocator

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,  // deeper traces
    }){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.log.err("Memory leak detected!", .{});
            // In debug mode, GPA prints allocation stack traces
        }
    }
    const allocator = gpa.allocator();
    // ... use allocator ...
}
```

### GPA Configuration Options

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{
    .stack_trace_frames = 16,       // frames per allocation trace
    .safety = true,                 // enable safety checks
    .never_unmap = true,            // keep freed pages mapped (catch use-after-free)
    .retain_metadata = true,        // keep metadata for freed allocs
}){};
```

### Testing for Leaks

```zig
test "no memory leaks" {
    // std.testing.allocator panics if any allocation isn't freed
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();  // without this, test FAILS
    try list.append(42);
}
```

### Common Leak Patterns

```zig
// 1. Missing defer on error path
fn init(alloc: std.mem.Allocator) !*Thing {
    const a = try alloc.alloc(u8, 100);
    errdefer alloc.free(a);         // FREE if later alloc fails!
    const b = try alloc.alloc(u8, 200);
    errdefer alloc.free(b);
    return Thing{ .a = a, .b = b };
}

// 2. Overwriting allocated pointer
var ptr = try alloc.create(u32);
ptr = try alloc.create(u32);  // LEAK: original ptr lost
// Fix: free before reassignment

// 3. Container not deinited
var map = std.StringHashMap([]u8).init(alloc);
// Must deinit the map AND free stored values
defer {
    var it = map.valueIterator();
    while (it.next()) |v| alloc.free(v.*);
    map.deinit();
}

// 4. ArrayList/Buffer growing without limit
// ArenaAllocator doesn't free on shrink — memory only grows
// Fix: use reset(.retain_capacity) periodically
```

### OOM Debugging

```zig
// Simulate OOM with FailingAllocator
const failing = std.testing.FailingAllocator.init(
    std.testing.allocator,
    .{ .fail_index = 5 },  // fail after 5 allocations
);
// Test that your code handles OOM gracefully

// Monitor allocations with a logging wrapper
const LoggingAllocator = std.heap.LoggingAllocator(.debug);
var logging = LoggingAllocator.init(backing_allocator);
// Prints every alloc/free to stderr
```

---

## Runtime Debugging Techniques

### Stack Traces

```zig
// Print current stack trace
std.debug.dumpCurrentStackTrace(@returnAddress());

// Capture stack trace for later
var addrs: [16]usize = undefined;
const trace = std.debug.captureStackTrace(@returnAddress(), &addrs);
// Print later:
std.debug.dumpStackTrace(trace);
```

### Debug Printing

```zig
// Print any value (structs, slices, enums)
std.debug.print("value = {any}\n", .{my_struct});

// Print hex dump of memory
std.debug.print("{x}\n", .{std.fmt.fmtSliceHexLower(bytes)});

// Conditional debug output (compiled out in release)
std.log.debug("only in Debug mode: {}", .{val});
std.log.info("always visible: {}", .{val});
```

### GDB/LLDB Integration

```sh
# Build with debug info (default in Debug mode)
zig build -Doptimize=Debug

# Run under GDB
gdb ./zig-out/bin/myapp
(gdb) break src/main.zig:42
(gdb) run

# Run under LLDB
lldb ./zig-out/bin/myapp
(lldb) breakpoint set --file src/main.zig --line 42
(lldb) run

# Zig-specific: inspect slices
(gdb) print *(char(*)[slice.len])slice.ptr
```

### Valgrind Compatibility

```sh
# Zig programs work with Valgrind (disable GPA safety to avoid false positives)
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};
# Or use page_allocator/c_allocator for Valgrind runs:
valgrind --leak-check=full ./zig-out/bin/myapp
```
