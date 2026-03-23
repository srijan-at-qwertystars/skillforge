---
name: cmake-patterns
description: >
  Modern CMake (3.20+) expert for C++ build systems. Generates and refactors CMakeLists.txt files
  using target-based architecture, proper visibility (PUBLIC/PRIVATE/INTERFACE),
  find_package, FetchContent, CMake presets, generator expressions, CTest, CPack, and
  install/export rules. TRIGGER when: user edits or creates CMakeLists.txt, writes CMake modules,
  configures C++ build systems, uses target_link_libraries, find_package, FetchContent_Declare,
  add_library, add_executable, CMakePresets.json, toolchain files, or asks about CMake best
  practices, dependency management, cross-compilation, or packaging. DO NOT trigger for: Makefile,
  Autotools, Meson, Bazel, plain compiler invocations, or non-CMake build systems.
---

# Modern CMake Patterns (3.20+)

## Philosophy

Treat CMake as a dependency graph of **targets**, not a collection of global variables.
Every property flows through targets. Never set global variables when a target property exists.

```cmake
cmake_minimum_required(VERSION 3.20)
project(MyProject VERSION 1.0.0 LANGUAGES CXX)
```

Set the C++ standard on targets, never globally:

```cmake
target_compile_features(mylib PUBLIC cxx_std_20)
set_target_properties(mylib PROPERTIES CXX_EXTENSIONS OFF)
```

## Project Structure

```
project/
├── CMakeLists.txt            # Top-level: project(), options, add_subdirectory()
├── CMakePresets.json
├── cmake/
│   ├── MyProjectConfig.cmake.in
│   └── toolchains/
├── src/
│   ├── CMakeLists.txt        # Library targets
│   └── app/
│       └── CMakeLists.txt    # Executable targets
├── include/
│   └── myproject/            # Public headers
└── tests/
    └── CMakeLists.txt        # Test targets
```

Top-level CMakeLists.txt pattern:

```cmake
cmake_minimum_required(VERSION 3.20)
project(MyProject VERSION 1.0.0 LANGUAGES CXX)

option(MYPROJECT_BUILD_TESTS "Build tests" ON)
option(MYPROJECT_INSTALL "Generate install target" ON)

add_subdirectory(src)

if(MYPROJECT_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
```

## Target Properties: PUBLIC, PRIVATE, INTERFACE

| Keyword     | Used by target | Propagated to consumers |
|-------------|:-:|:-:|
| PRIVATE     | ✓ | ✗ |
| PUBLIC      | ✓ | ✓ |
| INTERFACE   | ✗ | ✓ |

```cmake
add_library(mylib src/mylib.cpp)
add_library(MyProject::mylib ALIAS mylib)

target_include_directories(mylib
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_definitions(mylib
  PUBLIC MYLIB_VERSION=${PROJECT_VERSION}
  PRIVATE MYLIB_INTERNAL
)

target_link_libraries(mylib
  PUBLIC  Boost::headers
  PRIVATE fmt::fmt
)
```

Use ALIAS targets with `Namespace::` to catch misspellings at configure time.

## find_package: Config Mode vs Module Mode

**Config mode** (preferred): Package provides `<Package>Config.cmake`. CMake searches automatically.
**Module mode** (fallback): CMake uses `Find<Package>.cmake` from `CMAKE_MODULE_PATH`.

```cmake
find_package(Boost 1.80 REQUIRED COMPONENTS filesystem)
find_package(fmt 10.0 REQUIRED CONFIG)
find_package(OpenSSL REQUIRED)

target_link_libraries(myapp PRIVATE
  Boost::filesystem
  fmt::fmt
  OpenSSL::SSL
)
```

Prefer imported targets over variables (`Boost::filesystem` not `${Boost_LIBRARIES}`).
Use `REQUIRED` to fail fast. Use `CONFIG` hint when you know a config file exists.

## FetchContent for Dependency Management

Fetch and build dependencies from source when no system package exists:

```cmake
include(FetchContent)

FetchContent_Declare(
  fmt
  GIT_REPOSITORY https://github.com/fmtlib/fmt.git
  GIT_TAG        10.2.1
  GIT_SHALLOW    TRUE
)

FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.14.0
  GIT_SHALLOW    TRUE
  FIND_PACKAGE_ARGS NAMES GTest  # CMake 3.24+: try find_package first
)

FetchContent_MakeAvailable(fmt googletest)
```

Rules:
- Declare at top level to avoid duplicate declarations.
- Use `GIT_SHALLOW TRUE` to speed up clones.
- Use `FIND_PACKAGE_ARGS` (3.24+) to prefer system packages, fall back to source.
- Set `FETCHCONTENT_TRY_FIND_PACKAGE_MODE` to `ALWAYS` globally to always try system first.
- Pin exact tags, never track branches.

## CMake Presets (CMakePresets.json)

Standardize builds across developers and CI. Version-control `CMakePresets.json`,
gitignore `CMakeUserPresets.json`.

```json
{
  "version": 6,
  "cmakeMinimumRequired": { "major": 3, "minor": 25 },
  "configurePresets": [
    {
      "name": "dev",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/${presetName}",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_EXPORT_COMPILE_COMMANDS": "ON",
        "MYPROJECT_BUILD_TESTS": "ON"
      }
    },
    {
      "name": "release",
      "inherits": "dev",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release",
        "MYPROJECT_BUILD_TESTS": "OFF"
      }
    },
    {
      "name": "ci-linux",
      "inherits": "dev",
      "toolchainFile": "cmake/toolchains/gcc-13.cmake"
    }
  ],
  "buildPresets": [
    { "name": "dev", "configurePreset": "dev" },
    { "name": "release", "configurePreset": "release" }
  ],
  "testPresets": [
    {
      "name": "dev",
      "configurePreset": "dev",
      "output": { "outputOnFailure": true },
      "execution": { "jobs": 0 }
    }
  ]
}
```

Usage:
```sh
cmake --preset=dev
cmake --build --preset=dev
ctest --preset=dev
```

## Generator Expressions

Use generator expressions for build/install differences and per-config logic:

```cmake
# Different flags per build type
target_compile_options(mylib PRIVATE
  $<$<CONFIG:Debug>:-fsanitize=address -fno-omit-frame-pointer>
  $<$<CONFIG:Release>:-O3 -DNDEBUG>
)

# Platform-specific
target_compile_definitions(mylib PRIVATE
  $<$<PLATFORM_ID:Windows>:WIN32_LEAN_AND_MEAN>
  $<$<PLATFORM_ID:Linux>:_GNU_SOURCE>
)

# Build vs install include paths
target_include_directories(mylib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)

# Compiler-specific
target_compile_options(mylib PRIVATE
  $<$<CXX_COMPILER_ID:GNU>:-Wall -Wextra -Wpedantic>
  $<$<CXX_COMPILER_ID:Clang>:-Wall -Wextra -Wpedantic>
  $<$<CXX_COMPILER_ID:MSVC>:/W4>
)
```

## Custom Commands and Targets

Generate files at build time:

```cmake
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/generated.h
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/gen.py
          --output ${CMAKE_CURRENT_BINARY_DIR}/generated.h
  DEPENDS gen.py schema.json
  COMMENT "Generating header from schema"
)

add_custom_target(generate_headers
  DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/generated.h
)

add_dependencies(mylib generate_headers)
target_include_directories(mylib PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
```

Always list `DEPENDS` to ensure correct rebuild. Use `BYPRODUCTS` for Ninja.

## Installing and Exporting Packages

Make your library consumable via `find_package()`:

```cmake
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

install(TARGETS mylib
  EXPORT MyProjectTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(DIRECTORY include/myproject
  DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

install(EXPORT MyProjectTargets
  FILE MyProjectTargets.cmake
  NAMESPACE MyProject::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/MyProject
)

configure_package_config_file(
  cmake/MyProjectConfig.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/MyProjectConfig.cmake
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/MyProject
)

write_basic_package_version_file(
  ${CMAKE_CURRENT_BINARY_DIR}/MyProjectConfigVersion.cmake
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion
)

install(FILES
  ${CMAKE_CURRENT_BINARY_DIR}/MyProjectConfig.cmake
  ${CMAKE_CURRENT_BINARY_DIR}/MyProjectConfigVersion.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/MyProject
)
```

Config template (`MyProjectConfig.cmake.in`):

```cmake
@PACKAGE_INIT@
include(CMakeFindDependencyMacro)
find_dependency(Boost 1.80 COMPONENTS filesystem)
include("${CMAKE_CURRENT_LIST_DIR}/MyProjectTargets.cmake")
check_required_components(MyProject)
```

## Testing with CTest

```cmake
enable_testing()

add_executable(mylib_tests tests/test_main.cpp tests/test_core.cpp)
target_link_libraries(mylib_tests PRIVATE MyProject::mylib GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(mylib_tests
  DISCOVERY_TIMEOUT 30
  PROPERTIES TIMEOUT 10
)
```

Run: `ctest --test-dir build --output-on-failure -j$(nproc)`

For non-GTest tests:

```cmake
add_test(NAME integration_test
  COMMAND $<TARGET_FILE:myapp> --run-tests
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/testdata
)
set_tests_properties(integration_test PROPERTIES
  TIMEOUT 60
  ENVIRONMENT "DATA_DIR=${CMAKE_CURRENT_SOURCE_DIR}/testdata"
)
```

## Cross-Compilation Toolchain Files

Create `cmake/toolchains/arm-linux.cmake`:

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_SYSROOT /opt/sysroots/aarch64-linux)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
```

Reference via preset or command line: `cmake -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-linux.cmake`

## CPack for Packaging

```cmake
set(CPACK_PACKAGE_NAME "${PROJECT_NAME}")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "My library")
set(CPACK_PACKAGE_CONTACT "dev@example.com")

# Generator-specific
set(CPACK_GENERATOR "TGZ;DEB")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libboost-filesystem1.80.0")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)

include(CPack)
```

Build packages: `cpack --config build/CPackConfig.cmake -G DEB`

## Common Anti-Patterns

**Never do these:**

```cmake
# ✗ Global include paths — pollutes all targets
include_directories(${SOME_DIR})
# ✓ Use target_include_directories

# ✗ Global compile flags — affects everything
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall")
# ✓ Use target_compile_options

# ✗ Global definitions
add_definitions(-DFOO)
# ✓ Use target_compile_definitions

# ✗ Link by file path
target_link_libraries(myapp /usr/lib/libfoo.so)
# ✓ Use find_package + imported targets

# ✗ Glob sources — new files not detected without reconfigure
file(GLOB SOURCES "src/*.cpp")
# ✓ List sources explicitly

# ✗ Modify CMAKE_CXX_STANDARD globally
set(CMAKE_CXX_STANDARD 20)
# ✓ Use target_compile_features(mylib PUBLIC cxx_std_20)

# ✗ Hardcode paths
set(BOOST_ROOT "/home/user/boost")
# ✓ Use presets or toolchain files

# ✗ Skip ALIAS targets
add_library(mylib ...)
# ✓ add_library(MyProject::mylib ALIAS mylib)
```

## IDE Integration

Generate `compile_commands.json` for clangd, clang-tidy, and IDEs:
```cmake
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
```
Or in presets: `"cacheVariables": { "CMAKE_EXPORT_COMPILE_COMMANDS": "ON" }`
Symlink to project root: `ln -sf build/compile_commands.json .`

## Performance

### ccache

```cmake
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
  set(CMAKE_C_COMPILER_LAUNCHER ${CCACHE_PROGRAM})
  set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE_PROGRAM})
endif()
```

### Precompiled Headers (3.16+)

```cmake
target_precompile_headers(mylib PRIVATE
  <vector>
  <string>
  <unordered_map>
  <memory>
)

# Reuse PCH from another target
target_precompile_headers(myapp REUSE_FROM mylib)
```

### Unity Builds (3.16+)

```cmake
set_target_properties(mylib PROPERTIES UNITY_BUILD ON)
# Or globally via preset: "CMAKE_UNITY_BUILD": "ON"
```

### Parallel Configuration

Use Ninja generator for maximum parallel builds. Set in presets:
```json
{ "generator": "Ninja" }
```

### Link-Time Optimization

```cmake
include(CheckIPOSupported)
check_ipo_supported(RESULT ipo_supported)
if(ipo_supported)
  set_target_properties(mylib PROPERTIES INTERPROCEDURAL_OPTIMIZATION TRUE)
endif()
```

## Resources

### references/
- **`advanced-patterns.md`** — Superbuild pattern, ExternalProject_Add, custom find modules, imported/interface/object libraries, cross-compilation toolchains, sanitizers (ASan/TSan/UBSan), code coverage (gcov/lcov), CMake modules, package versioning.
- **`troubleshooting.md`** — "Target not found" errors, linking order, generator expression gotchas, RPATH issues, Windows DLL export macros, vcpkg/Conan issues, cache pitfalls, policy warnings, CMake 2.x migration.
- **`dependency-management.md`** — FetchContent advanced usage, vcpkg manifest mode, Conan 2.x (CMakeToolchain/CMakeDeps), system packages, vendoring, decision framework.

### scripts/
- **`cmake-init.sh`** — Initialize a modern CMake project. Flags: `--standard`, `--type` (app/lib/both), `--package-manager` (vcpkg/conan).
- **`cmake-lint.sh`** — cmake-lint/cmake-format checks with built-in fallback. `--fix` for auto-formatting.
- **`cmake-analyze.sh`** — Anti-pattern analysis (globals, old-style commands, missing visibility). `--json` for CI.

### assets/
- **`CMakeLists-root.txt`** — Root CMakeLists.txt template with options, sanitizers, ccache, dependencies.
- **`CMakeLists-library.txt`** — Library template with install/export rules and GenerateExportHeader.
- **`CMakePresets.json`** — Presets: dev/release/asan/tsan/coverage, CI, and workflow presets.
- **`toolchain-arm.cmake`** — ARM cross-compilation toolchain (Linux + bare-metal variants).
- **`.cmake-format.yaml`** — cmake-format config with formatting and naming rules.
