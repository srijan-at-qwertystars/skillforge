# Zig Advanced Patterns

## Table of Contents
- [Comptime Metaprogramming](#comptime-metaprogramming)
- [Type Functions and Generic Data Structures](#type-functions-and-generic-data-structures)
- [Type Reflection with @typeInfo](#type-reflection-with-typeinfo)
- [Type Construction with @Type](#type-construction-with-type)
- [Allocator Patterns](#allocator-patterns)
- [SIMD with @Vector](#simd-with-vector)
- [Inline Assembly](#inline-assembly)
- [Packed Structs](#packed-structs)
- [Sentinel-Terminated Types](#sentinel-terminated-types)
- [Error Traces and Safety](#error-traces-and-safety)

---

## Comptime Metaprogramming

Zig's `comptime` replaces macros, templates, and generics with actual Zig code executed at compile time. All comptime results are baked into the binary — zero runtime cost.

### Comptime Blocks and Variables

```zig
// Comptime block — evaluated at compile time, result is a constant
const lookup = comptime blk: {
    var table: [256]u8 = undefined;
    for (0..256) |i| {
        table[i] = @intCast((i * 7 + 3) % 256);
    }
    break :blk table;
};

// Comptime variable — only exists during compilation
comptime var sum: usize = 0;
inline for (.{ 1, 2, 3, 4 }) |v| {
    sum += v;
}
// sum == 10, known at compile time
```

### @setEvalBranchQuota

Recursive or iterative comptime code may hit the default 1000-branch limit:

```zig
fn comptimeHeavy(comptime n: usize) usize {
    @setEvalBranchQuota(100_000);
    var result: usize = 0;
    for (0..n) |i| result += i;
    return result;
}
```

### @compileLog and @compileError

```zig
fn debugType(comptime T: type) void {
    @compileLog("Type name:", @typeName(T));       // prints during compilation
    @compileLog("Size:", @sizeOf(T));
    if (@sizeOf(T) > 1024) @compileError("Type too large for this API");
}
```

---

## Type Functions and Generic Data Structures

Zig generics are just functions that accept `comptime T: type` and return a `type`:

```zig
fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, item: T) !void {
            if (self.count == capacity) return error.BufferFull;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }
    };
}

// Usage:
var rb = RingBuffer(u32, 64){};
try rb.push(42);
```

### Trait / Interface Pattern

```zig
fn Writeable(comptime T: type) type {
    // Validate that T has a write method at compile time
    if (!@hasDecl(T, "write")) {
        @compileError(@typeName(T) ++ " must have a write() method");
    }
    return struct {
        pub fn writeAll(self: *T, data: []const u8) !void {
            for (data) |byte| try self.write(byte);
        }
    };
}
```

---

## Type Reflection with @typeInfo

`@typeInfo(T)` returns a `std.builtin.Type` tagged union with full structure metadata:

```zig
fn serializeStruct(comptime T: type, value: T, writer: anytype) !void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                const fval = @field(value, field.name);
                try serializeField(field.type, fval, writer);
            }
        },
        else => @compileError("serializeStruct requires a struct type"),
    }
}
```

### Useful @typeInfo Fields

```zig
// Struct fields
const fields = @typeInfo(MyStruct).@"struct".fields;
// Each field: .name, .type, .default_value, .is_comptime, .alignment

// Enum fields
const enum_fields = @typeInfo(MyEnum).@"enum".fields;
// Each: .name, .value

// Function params
const params = @typeInfo(@TypeOf(myFn)).@"fn".params;
// Each: .type, .is_generic, .is_noalias

// Pointer info
const ptr_info = @typeInfo(*const u8).pointer;
// .size, .is_const, .is_volatile, .alignment, .child, .sentinel
```

### Compile-Time Field Iteration

```zig
fn fieldNames(comptime T: type) []const []const u8 {
    const fields = std.meta.fields(T);
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    return &names;
}
```

---

## Type Construction with @Type

Build types programmatically from `std.builtin.Type` values:

```zig
// Create an integer type with N more bits
fn Wider(comptime T: type) type {
    const info = @typeInfo(T).int;
    return @Type(.{ .int = .{
        .bits = info.bits * 2,
        .signedness = info.signedness,
    } });
}
// Wider(u16) == u32

// Create a struct type dynamically
fn makeStruct(comptime field_names: []const []const u8) type {
    var fields: [field_names.len]std.builtin.Type.StructField = undefined;
    for (field_names, 0..) |name, i| {
        fields[i] = .{
            .name = name,
            .type = []const u8,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}
```

---

## Allocator Patterns

### Custom Allocator Implementation

Every allocator implements `std.mem.Allocator` via a vtable:

```zig
const PoolAllocator = struct {
    free_list: ?*Node,
    backing: std.mem.Allocator,

    const Node = struct { next: ?*Node };

    pub fn allocator(self: *PoolAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        _ = ret_addr;
        if (self.free_list) |node| {
            self.free_list = node.next;
            return @ptrCast(node);
        }
        return self.backing.rawAlloc(len, ptr_align, @returnAddress());
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = .{ ctx, buf, buf_align, new_len, ret_addr };
        return false; // pool doesn't support resize
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = .{ buf_align, ret_addr };
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        const node: *Node = @ptrCast(@alignCast(buf.ptr));
        node.next = self.free_list;
        self.free_list = node;
    }
};
```

### Arena Strategies

```zig
// Per-request arena (web server pattern)
fn handleRequest(parent_alloc: std.mem.Allocator, req: Request) !Response {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit(); // bulk-free everything after response
    const alloc = arena.allocator();

    const body = try parseBody(alloc, req.body);
    const result = try processRequest(alloc, body);
    return try serializeResponse(alloc, result);
}

// Resettable arena for frame-based processing
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
while (running) {
    defer _ = arena.reset(.retain_capacity); // keep pages, reset pointer
    const frame_alloc = arena.allocator();
    try processFrame(frame_alloc);
}
```

### Allocator Selection Guide

| Allocator | Use Case | Individual Free? |
|---|---|---|
| `GeneralPurposeAllocator` | Development, leak detection | Yes |
| `ArenaAllocator` | Batch alloc, bulk free | No (bulk only) |
| `FixedBufferAllocator` | Stack/embedded, no heap | Yes |
| `page_allocator` | Large aligned blocks | Yes |
| `std.testing.allocator` | Tests (fails on leak) | Yes |
| Custom pool | Fixed-size hot objects | Yes (O(1)) |

---

## SIMD with @Vector

```zig
const Vec4f = @Vector(4, f32);

fn dotProduct(a: Vec4f, b: Vec4f) f32 {
    return @reduce(.Add, a * b);
}

// Splat: broadcast scalar to all lanes
const ones = @as(Vec4f, @splat(1.0));

// Shuffle: rearrange elements
const v = Vec4f{ 1, 2, 3, 4 };
const reversed = @shuffle(f32, v, undefined, [4]i32{ 3, 2, 1, 0 });

// Convert between vector and array
const arr: [4]f32 = v;
const back: Vec4f = arr;

// SIMD-accelerated array processing
fn simdSum(data: []const f32) f32 {
    const vec_len = 8;
    var i: usize = 0;
    var acc: @Vector(vec_len, f32) = @splat(0.0);
    while (i + vec_len <= data.len) : (i += vec_len) {
        const chunk: @Vector(vec_len, f32) = data[i..][0..vec_len].*;
        acc += chunk;
    }
    var sum = @reduce(.Add, acc);
    while (i < data.len) : (i += 1) sum += data[i]; // remainder
    return sum;
}

// Use std.simd for portable vector length selection
const preferred_len = std.simd.suggestVectorLength(f32) orelse 4;
```

---

## Inline Assembly

```zig
// Read CPU timestamp counter (x86_64)
fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

// Memory fence
fn mfence() void {
    asm volatile ("mfence" ::: "memory");
}

// Syscall (Linux x86_64)
fn linuxSyscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : "rcx", "r11", "memory"
    );
}
```

---

## Packed Structs

Bit-level memory layout control — no padding between fields:

```zig
// Network protocol header
const TcpFlags = packed struct(u8) {
    fin: bool,
    syn: bool,
    rst: bool,
    psh: bool,
    ack: bool,
    urg: bool,
    ece: bool,
    cwr: bool,
};

// Reinterpret raw bytes as packed struct
const raw: u8 = 0x12;
const flags: TcpFlags = @bitCast(raw);

// Packed struct with integer fields
const PixelRGB565 = packed struct(u16) {
    red: u5,
    green: u6,
    blue: u5,
};

// Access bit fields
var pixel = PixelRGB565{ .red = 31, .green = 63, .blue = 0 };
pixel.green = 32;
const raw_u16: u16 = @bitCast(pixel);
```

**Rules:** Fields in packed structs cannot have `undefined` default values. Pointers to fields are not allowed (not naturally aligned). Use `@bitCast` for raw conversion.

---

## Sentinel-Terminated Types

```zig
// Sentinel-terminated array: [N:sentinel]T
const data = [3:0]u8{ 'a', 'b', 'c' }; // 4 bytes total, last is 0

// Sentinel-terminated slice: [:sentinel]T
const slice: [:0]const u8 = "hello"; // null-terminated string

// Sentinel-terminated many-pointer: [*:sentinel]T
const c_str: [*:0]const u8 = "hello"; // C-compatible string pointer

// Convert between sentinel and non-sentinel types
const plain_slice: []const u8 = slice; // coerces implicitly
const with_sentinel = std.mem.sliceTo(c_str, 0); // [*:0] → [:0]

// Create sentinel-terminated slice from regular slice
const owned = try allocator.dupeZ(u8, some_slice); // appends sentinel 0
defer allocator.free(owned);
```

---

## Error Traces and Safety

### Error Return Traces

Zig captures stack traces on error returns in Debug and ReleaseSafe:

```zig
fn deepFunction() !void {
    return error.SomethingWrong; // trace captured here
}

fn middleFunction() !void {
    try deepFunction(); // trace propagated
}

pub fn main() !void {
    middleFunction() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        // In Debug mode, prints full error return trace
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return err;
    };
}
```

### @panic and Custom Panic Handlers

```zig
// Trigger panic (unrecoverable)
@panic("fatal: invariant violated");

// Custom panic handler (override in root source file)
pub const panic = std.debug.FullPanic(struct {
    pub fn call(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
        // Log to file, send telemetry, etc.
        std.debug.defaultPanic(msg, error_return_trace, ret_addr);
    }
}.call);
```

### Safety Checks by Build Mode

| Check | Debug | ReleaseSafe | ReleaseFast | ReleaseSmall |
|---|---|---|---|---|
| Bounds checking | ✅ | ✅ | ❌ | ❌ |
| Integer overflow | ✅ | ✅ | ❌ (wrapping) | ❌ |
| Null unwrap | ✅ | ✅ | ❌ | ❌ |
| Unreachable | ✅ | ✅ | ❌ (UB) | ❌ |
| Error return trace | ✅ | ✅ | ❌ | ❌ |

```zig
// Force safety checks in a specific scope, even in ReleaseFast
{
    @setRuntimeSafety(true);
    const x: u8 = @intCast(big_value); // will panic if overflow
}
```
