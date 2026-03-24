# Zig C Interop Guide

## Table of Contents
- [Overview](#overview)
- [@cImport and @cInclude](#cimport-and-cinclude)
- [translate-c](#translate-c)
- [Calling C from Zig](#calling-c-from-zig)
- [Calling Zig from C](#calling-zig-from-c)
- [Linking System Libraries](#linking-system-libraries)
- [pkg-config Integration](#pkg-config-integration)
- [Wrapping C APIs Idiomatically](#wrapping-c-apis-idiomatically)
- [C Strings](#c-strings)
- [Void Pointers](#void-pointers)
- [Function Pointers](#function-pointers)
- [Variadic Functions](#variadic-functions)
- [Type Mappings Reference](#type-mappings-reference)

---

## Overview

Zig has first-class C ABI compatibility. You can import C headers directly, call C functions with zero overhead, and export Zig functions callable from C. No FFI bindings generators or unsafe blocks required.

Key mechanisms:
- `@cImport` / `@cInclude` — import C headers inline
- `zig translate-c` — convert C headers to Zig source
- `export` — expose Zig functions to C
- `extern struct` — C-ABI-compatible struct layout
- `build.zig` — link C libraries and compile C source files

---

## @cImport and @cInclude

### Basic Usage

```zig
const c = @cImport({
    @cDefine("_GNU_SOURCE", {});
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("mylib.h");
});

pub fn main() void {
    _ = c.printf("Hello from C! %d\n", @as(c_int, 42));
    const ptr = c.malloc(256) orelse @panic("OOM");
    defer c.free(ptr);
}
```

### Rules and Best Practices

1. **Use a single @cImport block per application** — multiple blocks create independent type namespaces, so `c1.SomeStruct != c2.SomeStruct` even for the same C type.

2. **@cDefine for preprocessor macros:**
```zig
const c = @cImport({
    @cDefine("NDEBUG", {});
    @cDefine("MY_VERSION", "\"1.0\"");
    @cInclude("mylib.h");
});
```

3. **@cUndef to undefine macros:**
```zig
@cUndef("SOME_MACRO");
```

4. **Include paths** must be configured in build.zig (see [Linking System Libraries](#linking-system-libraries)).

### What @cImport Cannot Handle

- Function-like macros with complex logic
- Macros that expand to statement expressions (`({ ... })`)
- Computed `goto`
- `_Complex` types
- Most inline assembly in headers
- Variadic macros

For these, write a thin C wrapper function that Zig can call.

---

## translate-c

### Command-Line Usage

```sh
# Basic header translation
zig translate-c myheader.h > myheader.zig

# With include paths and defines
zig translate-c -I./include -DFOO=1 myheader.h > myheader.zig

# For a specific target
zig translate-c -target aarch64-linux-gnu myheader.h > myheader.zig

# System headers
zig translate-c -lc /usr/include/zlib.h > zlib.zig
```

### Build System Integration

```zig
// In build.zig — translate C headers as a build step
const translated = b.addTranslateC(.{
    .root_source_file = b.path("include/mylib.h"),
    .target = target,
    .optimize = optimize,
});
translated.addIncludePath(b.path("include/"));
exe.root_module.addImport("mylib", translated.createModule());
```

### When to Use translate-c vs @cImport

| Scenario | Use |
|---|---|
| Quick prototyping | `@cImport` |
| Auditing generated bindings | `translate-c` |
| Customizing translations | `translate-c` + manual edits |
| Build reproducibility | `translate-c` (checked into repo) |
| Complex headers with macros | `translate-c` + manual fixups |

---

## Calling C from Zig

### Functions

```zig
const c = @cImport({ @cInclude("math.h"); });

pub fn main() void {
    const result = c.sin(3.14159);
    std.debug.print("sin(pi) = {d:.6}\n", .{result});
}
```

### Structs

```zig
const c = @cImport({ @cInclude("time.h"); });

pub fn main() void {
    var t: c.time_t = undefined;
    _ = c.time(&t);
    const tm = c.localtime(&t);
    if (tm) |local| {
        std.debug.print("Hour: {}\n", .{local.*.tm_hour});
    }
}
```

### Compiling C Source Files

```zig
// In build.zig
exe.addCSourceFiles(.{
    .files = &.{
        "src/helper.c",
        "src/utils.c",
    },
    .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-O2",
    },
});
exe.addIncludePath(b.path("include/"));
exe.linkLibC();
```

### Handling C Errors

```zig
const c = @cImport({ @cInclude("errno.h"); @cInclude("stdio.h"); });

fn openFileC(path: [*:0]const u8) !*c.FILE {
    const fp = c.fopen(path, "r");
    if (fp == null) {
        const err = c.__errno_location().*;
        return switch (err) {
            c.ENOENT => error.FileNotFound,
            c.EACCES => error.AccessDenied,
            else => error.UnexpectedErrno,
        };
    }
    return fp.?;
}
```

---

## Calling Zig from C

### Exporting Functions

```zig
// mathlib.zig
const std = @import("std");

export fn zig_add(a: c_int, b: c_int) c_int {
    return a + b;
}

export fn zig_strlen(s: [*:0]const u8) usize {
    return std.mem.len(s);
}

// For C-compatible error handling, return error codes
export fn zig_parse(input: [*]const u8, len: usize, out: *c_int) c_int {
    const slice = input[0..len];
    const parsed = std.fmt.parseInt(i32, slice, 10) catch return -1;
    out.* = parsed;
    return 0;
}
```

### C Header File (manual)

```c
/* mathlib.h */
#ifndef MATHLIB_H
#define MATHLIB_H

#include <stddef.h>

int zig_add(int a, int b);
size_t zig_strlen(const char *s);
int zig_parse(const char *input, size_t len, int *out);

#endif
```

### Building a Static/Shared Library

```zig
// build.zig
const lib = b.addSharedLibrary(.{
    .name = "mathlib",
    .root_source_file = b.path("src/mathlib.zig"),
    .target = target,
    .optimize = optimize,
});
b.installArtifact(lib);

// For static library:
const static_lib = b.addStaticLibrary(.{
    .name = "mathlib",
    .root_source_file = b.path("src/mathlib.zig"),
    .target = target,
    .optimize = optimize,
});
b.installArtifact(static_lib);
```

### Using from C

```c
// main.c
#include "mathlib.h"
#include <stdio.h>

int main(void) {
    printf("3 + 4 = %d\n", zig_add(3, 4));
    printf("len = %zu\n", zig_strlen("hello"));
    return 0;
}
```

```sh
# Compile and link
zig build
gcc -o main main.c -L./zig-out/lib -lmathlib
```

---

## Linking System Libraries

### In build.zig

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libc (required for any C stdlib usage)
    exe.linkLibC();

    // Dynamic system library
    exe.linkSystemLibrary("sqlite3");

    // Prefer static linking
    exe.linkSystemLibrary2("z", .{
        .preferred_link_mode = .static,
    });

    // Add include search paths
    exe.addIncludePath(b.path("include/"));
    exe.addLibraryPath(b.path("lib/"));

    // Link a pre-built object/archive
    exe.addObjectFile(b.path("vendor/libfoo.a"));

    // Frameworks (macOS)
    exe.linkFramework("CoreFoundation");

    b.installArtifact(exe);
}
```

### Conditional Linking

```zig
const target_info = target.result;
if (target_info.os.tag == .linux) {
    exe.linkSystemLibrary("rt");
    exe.linkSystemLibrary("pthread");
} else if (target_info.os.tag == .macos) {
    exe.linkFramework("Security");
}
```

---

## pkg-config Integration

Zig's build system automatically uses pkg-config when available:

```zig
// This queries pkg-config for include paths, library paths, and flags
exe.linkSystemLibrary("libcurl");
exe.linkSystemLibrary("openssl");
exe.linkSystemLibrary("libpng");
```

```sh
# Verify pkg-config works for your library
pkg-config --cflags --libs libcurl
# -I/usr/include/x86_64-linux-gnu -lcurl

# If pkg-config is not available, specify paths manually:
```

```zig
exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
exe.linkSystemLibrary("curl");
```

---

## Wrapping C APIs Idiomatically

### Strategy: Thin Zig Wrapper

Transform C patterns into idiomatic Zig: error unions, slices, defer, allocators.

```zig
const c = @cImport({ @cInclude("sqlite3.h"); });

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Database {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        return .{ .handle = db.? };
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: *Database, sql: [:0]const u8) !void {
        var errmsg: ?[*:0]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg) |msg| {
                std.log.err("SQL error: {s}", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return error.SqliteExecFailed;
        }
    }
};

// Usage
var db = try Database.open("test.db");
defer db.close();
try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY)");
```

### Wrapping Patterns

```zig
// Pattern 1: C enum → Zig enum
const CResult = enum(c_int) {
    ok = c.LIB_OK,
    err_not_found = c.LIB_NOT_FOUND,
    err_invalid = c.LIB_INVALID,
    _,  // allow unknown values
};

fn checkResult(rc: c_int) !void {
    const result: CResult = @enumFromInt(rc);
    switch (result) {
        .ok => {},
        .err_not_found => return error.NotFound,
        .err_invalid => return error.Invalid,
        _ => return error.Unknown,
    }
}

// Pattern 2: Opaque C pointer → Zig struct
pub const Handle = struct {
    raw: *c.opaque_handle_t,

    pub fn init() !Handle {
        const h = c.handle_create() orelse return error.CreateFailed;
        return .{ .raw = h };
    }

    pub fn deinit(self: Handle) void {
        c.handle_destroy(self.raw);
    }
};

// Pattern 3: C buffer + length → Zig slice
fn getData(handle: Handle, allocator: std.mem.Allocator) ![]u8 {
    var len: usize = 0;
    var ptr: [*]u8 = undefined;
    if (c.get_data(handle.raw, &ptr, &len) != 0) return error.GetDataFailed;
    const result = try allocator.alloc(u8, len);
    @memcpy(result, ptr[0..len]);
    c.free_data(ptr);
    return result;
}
```

---

## C Strings

### Conversions

```zig
// Zig string literal → C string
// String literals are *const [N:0]u8, coerce to [*:0]const u8
c.puts("hello");

// Zig []const u8 → C string (must add null terminator)
const zig_str: []const u8 = "hello";
const c_str = try allocator.dupeZ(u8, zig_str);
defer allocator.free(c_str);
c.puts(c_str.ptr);

// Using a stack buffer
var buf: [256:0]u8 = undefined;
const len = @min(zig_str.len, buf.len - 1);
@memcpy(buf[0..len], zig_str[0..len]);
buf[len] = 0;
c.puts(&buf);

// C string → Zig slice
const from_c: [*:0]const u8 = c.getenv("HOME") orelse return error.NoHome;
const home: []const u8 = std.mem.span(from_c);
```

### Printf-Style Formatting

```zig
// Zig slices aren't null-terminated — use %.*s in printf
const name: []const u8 = "world";
_ = c.printf("Hello, %.*s!\n", @as(c_int, @intCast(name.len)), name.ptr);
```

---

## Void Pointers

C uses `void*` for generic data; Zig maps it to `?*anyopaque`:

```zig
// Receiving void* from C
const raw: ?*anyopaque = c.get_user_data(handle);

// Cast to known type
const data: *MyData = @ptrCast(@alignCast(raw orelse return error.NullPointer));

// Passing Zig pointer as void* to C
var my_data = MyData{ .value = 42 };
c.set_user_data(handle, @ptrCast(&my_data));

// Common pattern: callback with user data
fn myCallback(user_data: ?*anyopaque) callconv(.C) void {
    const self: *MyHandler = @ptrCast(@alignCast(user_data));
    self.handle();
}
c.register_callback(myCallback, @ptrCast(&handler));
```

---

## Function Pointers

```zig
// C callback typedef: void (*callback_t)(int, void*)
// In Zig:
const CallbackFn = *const fn (c_int, ?*anyopaque) callconv(.C) void;

// Implementing a C callback in Zig
fn onEvent(code: c_int, user_data: ?*anyopaque) callconv(.C) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data));
    ctx.processEvent(@intCast(code));
}

// Register the callback
c.set_event_handler(onEvent, @ptrCast(&my_context));

// Optional function pointers (nullable in C)
const maybe_fn: ?CallbackFn = c.get_handler();
if (maybe_fn) |handler| {
    handler(42, null);
}

// Casting C function pointers
const c_fn = c.dlsym(handle, "my_function");
const typed: ?*const fn () callconv(.C) c_int = @ptrCast(c_fn);
```

---

## Variadic Functions

```zig
// Calling C variadic functions from Zig
// Zig translates variadic C functions and they can be called directly:
const c = @cImport({ @cInclude("stdio.h"); });

_ = c.printf("Name: %s, Age: %d\n",
    @as([*:0]const u8, "Alice"),
    @as(c_int, 30),
);

// Zig does NOT support defining variadic functions.
// For C interop, use a slice parameter instead:
export fn zig_sum(values: [*]const c_int, count: c_int) c_int {
    var total: c_int = 0;
    for (values[0..@intCast(count)]) |v| total += v;
    return total;
}
```

---

## Type Mappings Reference

| C Type | Zig Type | Notes |
|---|---|---|
| `char` | `u8` | Use `c_char` for signedness portability |
| `signed char` | `i8` | |
| `unsigned char` | `u8` | |
| `short` | `c_short` | |
| `int` | `c_int` | |
| `unsigned int` | `c_uint` | |
| `long` | `c_long` | |
| `unsigned long` | `c_ulong` | |
| `long long` | `c_longlong` | |
| `size_t` | `usize` | |
| `ssize_t` | `isize` | |
| `float` | `f32` | |
| `double` | `f64` | |
| `void*` | `?*anyopaque` | |
| `const void*` | `?*const anyopaque` | |
| `T*` | `*T` or `[*]T` | Single vs many-item pointer |
| `const T*` | `*const T` or `[*]const T` | |
| `T*` (nullable) | `?*T` | |
| `T[N]` | `[N]T` | Fixed-size array |
| `char*` (string) | `[*:0]u8` | Null-terminated |
| `const char*` | `[*:0]const u8` | |
| `bool` (`_Bool`) | `bool` | |
| `enum` | `c_int` or typed enum | |
| `struct` | `extern struct` | Must match C layout |
| `union` | `extern union` | |
| `NULL` | `null` | |
| `FILE*` | `*c.FILE` | Via @cImport |

### Pointer Type Cheat Sheet

```zig
// C: int*        → Zig: *c_int         (single, non-null)
// C: int*        → Zig: [*]c_int       (many-item, non-null)
// C: int*        → Zig: ?*c_int        (single, nullable)
// C: int*        → Zig: ?[*]c_int      (many-item, nullable)
// C: const int*  → Zig: *const c_int   (single, non-null, const)
// C: int[]       → Zig: [*]c_int       (array-to-pointer decay)
// C: int (*)[N]  → Zig: *[N]c_int      (pointer to array)

// [*c]T — the "C pointer" type, used in auto-translated code
// Supports C-style arithmetic, coerces to/from other pointer types
// Prefer explicit Zig pointer types in hand-written code
```

### extern struct Layout Rules

```zig
// extern struct guarantees C-compatible layout
const CPoint = extern struct {
    x: f64,     // offset 0
    y: f64,     // offset 8
    z: f64,     // offset 16
};
// @sizeOf(CPoint) == 24, matching C struct

// For bitfields, use packed struct instead:
const CFlags = packed struct(u32) {
    read: bool,
    write: bool,
    exec: bool,
    _padding: u29 = 0,
};
```
