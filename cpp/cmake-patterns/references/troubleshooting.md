# CMake Troubleshooting Guide

## Table of Contents

- [Target Not Found Errors](#target-not-found-errors)
- [Linking Order Problems](#linking-order-problems)
- [Generator Expression Gotchas](#generator-expression-gotchas)
- [RPATH Issues on Linux/macOS](#rpath-issues-on-linuxmacos)
- [Windows-Specific Problems](#windows-specific-problems)
- [vcpkg Integration Issues](#vcpkg-integration-issues)
- [Conan Integration Issues](#conan-integration-issues)
- [Cache Variable Pitfalls](#cache-variable-pitfalls)
- [Policy Warnings](#policy-warnings)
- [Migration from CMake 2.x](#migration-from-cmake-2x)

---

## Target Not Found Errors

### "Target X not found" / "Cannot specify link libraries for target X"

**Cause**: Referencing a target before it's defined or in a different scope.

```cmake
# ✗ WRONG — target defined in subdirectory isn't visible here yet
target_link_libraries(myapp PRIVATE somelib)
add_subdirectory(libs/somelib)

# ✓ FIX — define before use, or use ALIAS targets
add_subdirectory(libs/somelib)
target_link_libraries(myapp PRIVATE SomeLib::somelib)
```

**Diagnosis checklist:**
1. Is the target defined via `add_library`/`add_executable`?
2. Is it defined *before* you reference it?
3. Is it in the same directory scope or a parent scope?
4. Check for typos — use `Namespace::target` ALIAS to catch misspellings at configure time

### "No rule to make target" / "Cannot find -lfoo"

**Cause**: Library file doesn't exist or isn't in the linker's search path.

```bash
# Debug: check what CMake resolved
cmake -B build -DCMAKE_FIND_DEBUG_MODE=ON 2>&1 | grep -i "foo"
```

### find_package Can't Find a Package

```cmake
# Debug find_package resolution
find_package(Foo REQUIRED CONFIG)
# → Error: Could not find a configuration file for package "Foo"
```

**Fixes:**
1. Set `CMAKE_PREFIX_PATH` to the install prefix containing `FooConfig.cmake`
2. Set `Foo_DIR` to the directory containing `FooConfig.cmake`
3. Check if the package provides Module mode instead: `find_package(Foo REQUIRED MODULE)`
4. Ensure the package was built/installed with the same architecture

```bash
# Find where config files are
find / -name "FooConfig.cmake" -o -name "foo-config.cmake" 2>/dev/null
```

---

## Linking Order Problems

### Undefined Symbols Despite Correct `target_link_libraries`

On Unix linkers, library order matters. The linker processes libraries left-to-right and discards
symbols it doesn't need yet.

```cmake
# ✗ If libA depends on libB, this may fail
target_link_libraries(myapp PRIVATE B A)

# ✓ Dependent libraries come first (or use groups)
target_link_libraries(myapp PRIVATE A B)
```

CMake handles ordering for targets it knows about. Problems arise with:
- Manually specified libraries (`-lfoo`)
- Circular dependencies between static libraries

### Circular Dependencies

```cmake
# Static libraries with circular deps — use linker groups
target_link_libraries(myapp PRIVATE
  -Wl,--start-group
  libA libB libC
  -Wl,--end-group
)

# Or on macOS (no --start-group):
target_link_libraries(myapp PRIVATE libA libB libC libA)
```

### Mixed Static/Shared Linking

```cmake
# Force static linking for specific library
find_library(ZLIB_STATIC libz.a PATHS /usr/lib/x86_64-linux-gnu)
target_link_libraries(myapp PRIVATE ${ZLIB_STATIC})

# Or use imported target
add_library(ZLIB::static STATIC IMPORTED)
set_target_properties(ZLIB::static PROPERTIES
  IMPORTED_LOCATION /usr/lib/x86_64-linux-gnu/libz.a
)
```

### "Multiple Definition" Errors

**Causes:**
- Same source compiled into multiple targets that are linked together
- Missing `inline` or `static` on functions defined in headers
- Object library linked multiple times

```cmake
# ✗ Same objects ending up in both library and executable
add_library(mylib STATIC common.cpp feature.cpp)
add_executable(myapp main.cpp common.cpp)  # common.cpp compiled twice!

# ✓ Link the library instead
add_executable(myapp main.cpp)
target_link_libraries(myapp PRIVATE mylib)
```

---

## Generator Expression Gotchas

### Expressions Not Evaluated at Configure Time

Generator expressions are evaluated at **generation/build** time, not during `cmake` configure:

```cmake
# ✗ WRONG — genex in message() prints literal string
message(STATUS "Config: $<CONFIG>")
# Prints: "Config: $<CONFIG>"

# ✗ WRONG — genex in if() doesn't work
if($<CONFIG:Debug>)  # Always false!
  message("Debug mode")
endif()

# ✓ Use CMAKE_BUILD_TYPE at configure time
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  message(STATUS "Debug mode")
endif()
```

### Genex in Cache Variables

```cmake
# ✗ WRONG — cache variables store the literal string
set(MY_FLAGS "$<$<CONFIG:Debug>:-DDEBUG>" CACHE STRING "flags")
# Stores: "$<$<CONFIG:Debug>:-DDEBUG>"

# ✓ Use genex only in target properties
target_compile_definitions(mylib PRIVATE $<$<CONFIG:Debug>:DEBUG>)
```

### Where Genex CAN Be Used

| Context                          | Genex works? |
|----------------------------------|:------------:|
| `target_compile_options`         | ✅           |
| `target_compile_definitions`     | ✅           |
| `target_include_directories`     | ✅           |
| `target_link_libraries`          | ✅           |
| `target_sources` (CMake 3.13+)  | ✅           |
| `install(TARGETS ... DESTINATION)` | ✅         |
| `set()` / cache variables        | ❌           |
| `message()`                      | ❌           |
| `if()` / `elseif()`              | ❌           |
| `file()` operations              | ❌           |

### Common Genex Patterns

```cmake
# Config-specific flags
$<$<CONFIG:Debug>:-DDEBUG_MODE>
$<$<CONFIG:Release>:-O3>

# Compiler-specific
$<$<CXX_COMPILER_ID:GNU>:-Wno-maybe-uninitialized>

# Platform-specific
$<$<PLATFORM_ID:Windows>:WIN32_LEAN_AND_MEAN>

# Build vs install paths
$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>

# Boolean logic
$<AND:$<CONFIG:Debug>,$<PLATFORM_ID:Linux>>
$<OR:$<CXX_COMPILER_ID:GNU>,$<CXX_COMPILER_ID:Clang>>
$<NOT:$<BOOL:${SOME_VAR}>>

# Target existence check (CMake 3.12+)
$<TARGET_EXISTS:Foo::Bar>
```

---

## RPATH Issues on Linux/macOS

### Symptoms

- Binary works in build tree but not after `make install`
- `error while loading shared libraries: libfoo.so`
- `dyld: Library not loaded` on macOS

### Understanding RPATH

| Property                           | Purpose                                    |
|------------------------------------|--------------------------------------------|
| `CMAKE_BUILD_RPATH`               | RPATH for build tree binaries              |
| `CMAKE_INSTALL_RPATH`             | RPATH for installed binaries               |
| `CMAKE_INSTALL_RPATH_USE_LINK_PATH` | Add linked library dirs to install RPATH |
| `CMAKE_BUILD_WITH_INSTALL_RPATH`  | Use install RPATH in build tree too        |
| `CMAKE_SKIP_BUILD_RPATH`          | Don't set any build RPATH                  |

### Recommended Configuration

```cmake
# Linux: use $ORIGIN for relocatable installs
set(CMAKE_INSTALL_RPATH "$ORIGIN/../lib")
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)

# macOS: use @executable_path
set(CMAKE_INSTALL_RPATH "@executable_path/../lib")
set(CMAKE_MACOSX_RPATH TRUE)

# Or use both for cross-platform
if(APPLE)
  set(CMAKE_INSTALL_RPATH "@executable_path/../lib")
else()
  set(CMAKE_INSTALL_RPATH "$ORIGIN/../lib")
endif()
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)
```

### Debugging RPATH

```bash
# Linux: inspect RPATH
readelf -d mybinary | grep -E 'RPATH|RUNPATH'
chrpath -l mybinary
ldd mybinary

# macOS: inspect
otool -l mybinary | grep -A2 LC_RPATH
otool -L mybinary

# Linux: trace library resolution
LD_DEBUG=libs ./mybinary 2>&1 | head -50
```

### Common Mistakes

```cmake
# ✗ Hardcoded absolute path — not relocatable
set(CMAKE_INSTALL_RPATH "/home/user/project/build/lib")

# ✗ Forgot to set RPATH on install
# (CMake strips build RPATH on install by default)

# ✓ Set install RPATH before defining targets
set(CMAKE_INSTALL_RPATH "$ORIGIN/../lib")
# Then define your targets...
```

---

## Windows-Specific Problems

### DLL Hell: Export Macros

Windows shared libraries require explicit symbol export/import:

```cmake
# Modern approach: GenerateExportHeader
include(GenerateExportHeader)

add_library(mylib SHARED src/mylib.cpp)
generate_export_header(mylib
  EXPORT_FILE_NAME ${CMAKE_CURRENT_BINARY_DIR}/mylib_export.h
  EXPORT_MACRO_NAME MYLIB_API
)

target_include_directories(mylib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}>
)
```

Then in your header:
```cpp
#include "mylib_export.h"

class MYLIB_API MyClass {
public:
    void doSomething();
};

MYLIB_API void freeFunction();
```

### DLL Not Found at Runtime

Windows doesn't have RPATH. DLLs must be in:
1. Same directory as the `.exe`
2. System PATH
3. Current working directory

```cmake
# Copy DLLs to executable output directory
add_custom_command(TARGET myapp POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    $<TARGET_FILE:mylib>
    $<TARGET_FILE_DIR:myapp>
)

# Or set all outputs to same directory
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
```

### Debug/Release Library Name Conflicts

```cmake
# Separate debug and release libs with suffix
set_target_properties(mylib PROPERTIES
  DEBUG_POSTFIX "d"
)
# Produces: mylib.lib (release), mylibd.lib (debug)
```

### MSVC-Specific Issues

```cmake
# Suppress common MSVC warnings
target_compile_definitions(mylib PRIVATE
  _CRT_SECURE_NO_WARNINGS      # scanf, fopen deprecation
  _SILENCE_ALL_MS_EXT_WARNINGS # Extension warnings
  NOMINMAX                      # Prevent min/max macros
  WIN32_LEAN_AND_MEAN           # Reduce windows.h bloat
)

# Set MSVC runtime library (CMake 3.15+)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
```

---

## vcpkg Integration Issues

### CMAKE_TOOLCHAIN_FILE Conflicts

Problem: You have your own toolchain file AND need vcpkg's.

```cmake
# ✗ WRONG — can only have one CMAKE_TOOLCHAIN_FILE
cmake -DCMAKE_TOOLCHAIN_FILE=my-toolchain.cmake
      -DCMAKE_TOOLCHAIN_FILE=vcpkg/scripts/buildsystems/vcpkg.cmake

# ✓ FIX — chain toolchains
# In your toolchain file, include vcpkg at the end:
# my-toolchain.cmake:
set(CMAKE_C_COMPILER gcc-13)
set(CMAKE_CXX_COMPILER g++-13)
# ... your toolchain settings ...
include($ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake)

# Or use VCPKG_CHAINLOAD_TOOLCHAIN_FILE
cmake -DCMAKE_TOOLCHAIN_FILE=vcpkg/scripts/buildsystems/vcpkg.cmake
      -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=my-toolchain.cmake
```

### Triplet Mismatch

```bash
# Check what triplet is being used
cmake -B build --preset dev 2>&1 | grep -i triplet

# Common triplets:
# x64-linux         (shared, dynamic CRT)
# x64-linux-static  (static, static CRT)
# x64-windows       (shared, dynamic CRT)
# x64-windows-static (static, static CRT)
```

### Package Not Found After vcpkg Install

```bash
# Verify package is installed
vcpkg list | grep <package>

# Check the correct find_package name
vcpkg search <package>
# Read "The package <X> provides CMake targets: find_package(<Y>...)"
```

### Manifest Mode Issues

```json
// vcpkg.json — ensure valid
{
  "name": "myproject",
  "version-string": "1.0.0",
  "dependencies": [
    "fmt",
    { "name": "boost-filesystem", "version>=": "1.83.0" }
  ]
}
```

Common gotcha: vcpkg manifest mode installs to `build/vcpkg_installed/`, not global.

---

## Conan Integration Issues

### Legacy vs Modern Generators

```python
# ✗ OLD — don't use these with Conan 2.x
generators = "cmake", "cmake_paths", "cmake_find_package"

# ✓ NEW — use modern generators
generators = "CMakeToolchain", "CMakeDeps"
```

### CMakeLists.txt Not Finding Conan Packages

```bash
# Make sure to pass the toolchain file
conan install . --output-folder=build --build=missing
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake

# Or use the generated presets
cmake --preset conan-release
```

### Profile Mismatches

```bash
# Check default profile
conan profile show

# Common issue: compiler.cppstd not matching project requirements
# Fix: create or update profile
conan profile detect --force

# Custom profile
cat > ~/.conan2/profiles/gcc13-cpp20 << 'EOF'
[settings]
os=Linux
arch=x86_64
compiler=gcc
compiler.version=13
compiler.cppstd=20
compiler.libcxx=libstdc++11
build_type=Release
EOF

conan install . -pr gcc13-cpp20 --output-folder=build --build=missing
```

### Build Missing Dependencies

```bash
# If binary packages aren't available
conan install . --build=missing  # Build only missing
conan install . --build=*        # Force rebuild all
```

---

## Cache Variable Pitfalls

### Variables Don't Update

```cmake
# Cache variable set once, never updates unless FORCE is used
set(MY_OPTION "old" CACHE STRING "An option")
# Second run: still "old" even if you change this line

# ✓ Use FORCE to always update
set(MY_OPTION "new" CACHE STRING "An option" FORCE)

# ✓ Better: use option() for booleans
option(MY_FEATURE "Enable feature" ON)
```

### Cache vs Normal Variable Scope

```cmake
# Normal variable shadows cache variable in current scope
set(FOO "normal")
set(FOO "cached" CACHE STRING "")
message(STATUS "${FOO}")  # Prints "normal" if both exist!

# ✓ Clear normal variable to see cache value
unset(FOO)
message(STATUS "${FOO}")  # Now prints "cached"
```

### Stale Cache Entries

After changing `CMakeLists.txt`, old cache entries persist:

```bash
# Nuclear option: delete cache entirely
rm build/CMakeCache.txt
cmake -B build

# Targeted: remove specific entry
cmake -B build -U MY_OLD_VARIABLE

# View current cache
cmake -B build -L    # List non-advanced
cmake -B build -LA   # List all
cmake -B build -LAH  # List all with help strings
```

### option() vs set(... CACHE BOOL)

```cmake
# option() is syntactic sugar for:
# set(MY_OPT <default> CACHE BOOL "description")
# It does NOT overwrite existing cache values

option(BUILD_TESTS "Build tests" ON)
# If user passed -DBUILD_TESTS=OFF, this doesn't override it ✓
```

---

## Policy Warnings

### What Policies Are

CMake policies preserve backward compatibility. Each policy has OLD (legacy) and NEW
(modern) behavior. `cmake_minimum_required` sets all policies up to that version to NEW.

### Common Policies

| Policy   | Version | What It Controls                                          |
|----------|---------|-----------------------------------------------------------|
| CMP0048  | 3.0     | `project()` manages VERSION variables                      |
| CMP0054  | 3.1     | `if()` doesn't dereference quoted arguments               |
| CMP0063  | 3.3     | Visibility properties honored for all target types        |
| CMP0069  | 3.9     | IPO/LTO support via `INTERPROCEDURAL_OPTIMIZATION`        |
| CMP0074  | 3.12    | `find_package` uses `<PackageName>_ROOT` variables        |
| CMP0076  | 3.13    | `target_sources()` converts relative paths                |
| CMP0077  | 3.13    | `option()` honors normal variables                        |
| CMP0079  | 3.13    | `target_link_libraries` on targets in other directories   |
| CMP0135  | 3.24    | URL download timestamp handling                           |
| CMP0144  | 3.27    | `find_package` uses upper-case `<PACKAGENAME>_ROOT`       |

### Handling Policy Warnings

```cmake
# ✓ Best: set cmake_minimum_required high enough
cmake_minimum_required(VERSION 3.20)

# Handle specific policy in older code
if(POLICY CMP0077)
  cmake_policy(SET CMP0077 NEW)
endif()

# Scope policies with cmake_policy(PUSH/POP)
cmake_policy(PUSH)
cmake_policy(SET CMP0054 NEW)
# ... code affected by policy ...
cmake_policy(POP)
```

### "Policy CMP0XXX is not set" Warnings

This means your `cmake_minimum_required` version is older than when the policy was introduced.
**Fix:** raise your minimum version.

```cmake
# ✗ Too old — will trigger policy warnings for newer CMake features
cmake_minimum_required(VERSION 2.8)

# ✓ Modern — sets all policies up to 3.20 to NEW
cmake_minimum_required(VERSION 3.20)
```

---

## Migration from CMake 2.x

### Step-by-Step Migration

#### 1. Raise Minimum Version

```cmake
# ✗ Before
cmake_minimum_required(VERSION 2.8.12)

# ✓ After — pick the minimum that supports features you need
cmake_minimum_required(VERSION 3.20)
```

#### 2. Replace Global Commands with Target Commands

```cmake
# ✗ Old style                           # ✓ Modern style
include_directories(${X_DIRS})          → target_include_directories(tgt PRIVATE ${X_DIRS})
link_directories(${X_LIBDIRS})          → # Remove — use imported targets
link_libraries(${X_LIBS})              → target_link_libraries(tgt PRIVATE X::X)
add_definitions(-DFOO)                  → target_compile_definitions(tgt PRIVATE FOO)
set(CMAKE_CXX_FLAGS "... -Wall")        → target_compile_options(tgt PRIVATE -Wall)
set(CMAKE_CXX_STANDARD 17)             → target_compile_features(tgt PUBLIC cxx_std_17)
```

#### 3. Use Imported Targets from find_package

```cmake
# ✗ Old: use variables
find_package(Boost REQUIRED COMPONENTS filesystem)
include_directories(${Boost_INCLUDE_DIRS})
target_link_libraries(myapp ${Boost_LIBRARIES})

# ✓ Modern: use imported targets
find_package(Boost REQUIRED COMPONENTS filesystem)
target_link_libraries(myapp PRIVATE Boost::filesystem)
```

#### 4. Add Visibility Specifiers

```cmake
# ✗ Old: no visibility
target_link_libraries(mylib somelib)

# ✓ Modern: explicit visibility
target_link_libraries(mylib
  PUBLIC  Boost::headers          # Part of mylib's public API
  PRIVATE fmt::fmt                # Implementation detail
)
```

#### 5. Replace file(GLOB) with Explicit Sources

```cmake
# ✗ Old: glob sources
file(GLOB SOURCES "src/*.cpp")
add_library(mylib ${SOURCES})

# ✓ Modern: list explicitly (new files detected on add)
add_library(mylib
  src/core.cpp
  src/utils.cpp
  src/network.cpp
)
```

#### 6. Use Presets Instead of Shell Scripts

Before (build.sh):
```bash
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=g++-13
make -j$(nproc)
```

After (CMakePresets.json):
```json
{
  "version": 6,
  "configurePresets": [{
    "name": "release",
    "generator": "Ninja",
    "binaryDir": "${sourceDir}/build/release",
    "cacheVariables": {
      "CMAKE_BUILD_TYPE": "Release",
      "CMAKE_CXX_COMPILER": "g++-13"
    }
  }]
}
```

```bash
cmake --preset release && cmake --build --preset release
```

### Migration Checklist

- [ ] Set `cmake_minimum_required(VERSION 3.20)` or higher
- [ ] Replace all `include_directories` → `target_include_directories`
- [ ] Replace all `add_definitions` → `target_compile_definitions`
- [ ] Replace all `link_libraries` → `target_link_libraries`
- [ ] Remove all `link_directories` calls
- [ ] Add `PUBLIC`/`PRIVATE`/`INTERFACE` to all `target_*` calls
- [ ] Replace variable-based find_package usage with imported targets
- [ ] Add ALIAS targets: `add_library(Ns::tgt ALIAS tgt)`
- [ ] Use `target_compile_features` instead of `CMAKE_CXX_STANDARD`
- [ ] Replace `file(GLOB)` with explicit source lists
- [ ] Use `GNUInstallDirs` for install paths
- [ ] Add `CMakePresets.json` for reproducible builds
- [ ] Enable `CMAKE_EXPORT_COMPILE_COMMANDS` for IDE/tooling support
