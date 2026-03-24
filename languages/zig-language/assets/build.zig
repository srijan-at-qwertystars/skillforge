const std = @import("std");

pub fn build(b: *std.Build) void {
    // ── Target & Optimization ──
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Executable ──
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // ── Library (static) ──
    const lib = b.addStaticLibrary(.{
        .name = "mylib",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // ── Shared Library ──
    const shared_lib = b.addSharedLibrary(.{
        .name = "mylib",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(shared_lib);

    // ── Dependencies ──
    // Uncomment and configure after adding deps to build.zig.zon:
    // const dep = b.dependency("mylib", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // exe.root_module.addImport("mylib", dep.module("mylib"));

    // ── C Interop ──
    // exe.linkLibC();
    // exe.linkSystemLibrary("sqlite3");
    // exe.addIncludePath(b.path("include/"));
    // exe.addCSourceFiles(.{
    //     .files = &.{"src/helper.c"},
    //     .flags = &.{"-std=c11", "-Wall"},
    // });

    // ── Run Step ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // ── Unit Tests ──
    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_lib_tests.step);

    // ── Cross-Compilation Targets ──
    // Build for specific targets with:
    //   zig build -Dtarget=aarch64-linux-gnu
    //   zig build -Dtarget=x86_64-windows-gnu
    //   zig build -Dtarget=x86_64-macos
    //   zig build -Dtarget=wasm32-wasi

    // ── Custom Install Step ──
    const install_docs = b.addInstallDirectory(.{
        .source_dir = b.path("docs"),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Install documentation");
    docs_step.dependOn(&install_docs.step);

    // ── Benchmark Step ──
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}
