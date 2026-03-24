const std = @import("std");

// ── Application Entry Point ──
pub fn main() !void {
    // ── Allocator Setup ──
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.log.err("Memory leak detected!", .{});
    }
    const allocator = gpa.allocator();

    // ── Argument Parsing ──
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "greet")) {
        const name = if (args.len > 2) args[2] else "world";
        try greet(name);
    } else if (std.mem.eql(u8, command, "count")) {
        const path = if (args.len > 2) args[2] else ".";
        try countFiles(allocator, path);
    } else if (std.mem.eql(u8, command, "read")) {
        if (args.len < 3) {
            std.log.err("Usage: myapp read <filename>", .{});
            return;
        }
        try readFile(allocator, args[2]);
    } else {
        std.log.err("Unknown command: {s}", .{command});
        try printUsage();
    }
}

// ── Commands ──

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: myapp <command> [args]
        \\
        \\Commands:
        \\  greet [name]      Say hello
        \\  count [path]      Count files in directory
        \\  read <file>       Read and display a file
        \\
    );
}

fn greet(name: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello, {s}!\n", .{name});
}

fn countFiles(allocator: std.mem.Allocator, path: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.log.err("Cannot open directory '{s}': {}", .{ path, err });
        return;
    };
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        _ = allocator;
        count += 1;
        std.log.debug("{s} ({s})", .{ entry.name, @tagName(entry.kind) });
    }
    try stdout.print("{} entries in '{s}'\n", .{ count, path });
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const max_size = 1 << 20; // 1 MB limit

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.log.err("Cannot open file '{s}': {}", .{ path, err });
        return;
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, max_size) catch |err| {
        std.log.err("Cannot read file '{s}': {}", .{ path, err });
        return;
    };
    defer allocator.free(contents);

    try stdout.print("── {s} ({} bytes) ──\n", .{ path, contents.len });
    try stdout.writeAll(contents);
    if (contents.len > 0 and contents[contents.len - 1] != '\n') {
        try stdout.writeByte('\n');
    }
}

// ── Logging ──
// Override default log level (set to .debug for verbose output)
pub const std_options: std.Options = .{
    .log_level = .info,
};

// ── Tests ──
test "greet does not error" {
    // Redirect stdout for testing
    try greet("test");
}

test "printUsage does not error" {
    try printUsage();
}
