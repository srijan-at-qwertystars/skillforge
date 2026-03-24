#!/usr/bin/env bash
#
# init-project.sh — Initialize a new Zig project with build.zig, src structure, and test setup
#
# Usage:
#   ./init-project.sh <project-name> [--lib|--exe]
#
# Examples:
#   ./init-project.sh myapp           # executable project (default)
#   ./init-project.sh mylib --lib     # library project
#

set -euo pipefail

# --- Configuration ---
readonly SCRIPT_NAME="$(basename "$0")"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    echo "Usage: ${SCRIPT_NAME} <project-name> [--lib|--exe]"
    echo ""
    echo "Options:"
    echo "  --exe    Create an executable project (default)"
    echo "  --lib    Create a library project"
    echo "  -h       Show this help"
    exit 1
}

# --- Argument Parsing ---
if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

PROJECT_NAME="$1"
PROJECT_TYPE="exe"

if [[ $# -ge 2 ]]; then
    case "$2" in
        --lib) PROJECT_TYPE="lib" ;;
        --exe) PROJECT_TYPE="exe" ;;
        *) log_error "Unknown option: $2"; usage ;;
    esac
fi

# --- Validation ---
if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    log_error "Invalid project name: '$PROJECT_NAME'. Use alphanumeric, hyphens, underscores."
    exit 1
fi

if command -v zig &>/dev/null; then
    ZIG_VERSION="$(zig version)"
    log_info "Found Zig ${ZIG_VERSION}"
else
    log_warn "Zig not found in PATH. Creating project structure anyway."
    ZIG_VERSION="0.14.0"
fi

if [[ -d "$PROJECT_NAME" ]]; then
    log_error "Directory '$PROJECT_NAME' already exists."
    exit 1
fi

# --- Create Project ---
log_info "Creating ${PROJECT_TYPE} project: ${PROJECT_NAME}"

mkdir -p "${PROJECT_NAME}/src"
cd "$PROJECT_NAME"

# --- build.zig ---
cat > build.zig << 'BUILDEOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
BUILDEOF

if [[ "$PROJECT_TYPE" == "exe" ]]; then
    cat >> build.zig << BUILDEOF

    const exe = b.addExecutable(.{
        .name = "${PROJECT_NAME}",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the application").dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
BUILDEOF
else
    cat >> build.zig << BUILDEOF

    const lib = b.addStaticLibrary(.{
        .name = "${PROJECT_NAME}",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(lib_tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
BUILDEOF
fi

log_ok "Created build.zig"

# --- build.zig.zon ---
# Generate a random fingerprint
FINGERPRINT="0x$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cat > build.zig.zon << ZONEOF
.{
    .name = .${PROJECT_NAME},
    .version = "0.1.0",
    .fingerprint = ${FINGERPRINT},
    .minimum_zig_version = "0.14.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
ZONEOF
log_ok "Created build.zig.zon"

# --- Source Files ---
if [[ "$PROJECT_TYPE" == "exe" ]]; then
    cat > src/main.zig << 'SRCEOF'
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello, {s}!\n", .{"world"});
}

test "basic test" {
    const x = 1 + 1;
    try std.testing.expect(x == 2);
}
SRCEOF
    log_ok "Created src/main.zig"
else
    cat > src/root.zig << 'SRCEOF'
const std = @import("std");

/// Add two numbers, returning an error on overflow.
pub fn add(a: i32, b: i32) !i32 {
    return std.math.add(i32, a, b);
}

test "add" {
    const result = try add(2, 3);
    try std.testing.expect(result == 5);
}

test "overflow" {
    const result = add(std.math.maxInt(i32), 1);
    try std.testing.expectError(error.Overflow, result);
}
SRCEOF
    log_ok "Created src/root.zig"
fi

# --- .gitignore ---
cat > .gitignore << 'GITEOF'
zig-out/
.zig-cache/
zig-cache/
GITEOF
log_ok "Created .gitignore"

# --- Summary ---
echo ""
log_ok "Project '${PROJECT_NAME}' created successfully!"
echo ""
echo "  cd ${PROJECT_NAME}"
if [[ "$PROJECT_TYPE" == "exe" ]]; then
    echo "  zig build run       # build and run"
else
    echo "  zig build           # build library"
fi
echo "  zig build test      # run tests"
echo "  zig fmt src/        # format code"
echo ""
