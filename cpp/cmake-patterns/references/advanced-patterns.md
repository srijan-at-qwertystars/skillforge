# Advanced CMake Patterns

## Table of Contents

- [Superbuild Pattern](#superbuild-pattern)
- [ExternalProject_Add](#externalproject_add)
- [Custom Find Modules](#custom-find-modules)
- [Imported Targets](#imported-targets)
- [Interface Libraries](#interface-libraries)
- [Object Libraries](#object-libraries)
- [Toolchain Files for Cross-Compilation](#toolchain-files-for-cross-compilation)
- [Sanitizer Integration](#sanitizer-integration)
- [Code Coverage with gcov/lcov](#code-coverage-with-gcovlcov)
- [Useful CMake Modules](#useful-cmake-modules)
- [Package Versioning](#package-versioning)

---

## Superbuild Pattern

A superbuild is a top-level CMake project that orchestrates building all dependencies via
`ExternalProject_Add`, then builds the main project against those installed artifacts.

### When to Use

- Dependencies don't support modern CMake or `FetchContent`
- You need full isolation between dependency builds
- Dependencies require install steps before consumption
- Building large frameworks (Qt, LLVM) from source alongside your project

### Structure

```
superbuild/
├── CMakeLists.txt          # Superbuild orchestrator
├── cmake/
│   └── External_*.cmake    # One file per dependency
└── project/
    └── CMakeLists.txt      # Actual project
```

### Superbuild CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.20)
project(MySuperBuild LANGUAGES NONE)

include(ExternalProject)

set(INSTALL_PREFIX ${CMAKE_BINARY_DIR}/install)
set(CMAKE_ARGS_COMMON
  -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}
  -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
  -DCMAKE_PREFIX_PATH=${INSTALL_PREFIX}
)

# Build zlib first
ExternalProject_Add(ep_zlib
  URL https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
  URL_HASH SHA256=...
  CMAKE_ARGS ${CMAKE_ARGS_COMMON}
)

# Build the main project, depending on zlib
ExternalProject_Add(ep_main
  SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/project
  CMAKE_ARGS ${CMAKE_ARGS_COMMON}
  DEPENDS ep_zlib
  INSTALL_COMMAND ""
)
```

### Key Rules

1. **Install deps to a local prefix** — use `${CMAKE_BINARY_DIR}/install`
2. **Pass `CMAKE_PREFIX_PATH`** to downstream projects so `find_package()` works
3. **Always specify `DEPENDS`** for correct build ordering
4. **Forward toolchain settings** — pass `CMAKE_TOOLCHAIN_FILE`, compilers, sysroot
5. **Use `LANGUAGES NONE`** in the superbuild — it doesn't compile anything itself

---

## ExternalProject_Add

Full-featured module for downloading, configuring, building, and installing external projects
at **build time** (not configure time — this is the key difference from `FetchContent`).

### Complete Example

```cmake
include(ExternalProject)

ExternalProject_Add(ep_spdlog
  GIT_REPOSITORY  https://github.com/gabime/spdlog.git
  GIT_TAG         v1.14.1
  GIT_SHALLOW     TRUE
  GIT_PROGRESS    TRUE
  
  CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    -DCMAKE_BUILD_TYPE=Release
    -DSPDLOG_BUILD_SHARED=OFF
    -DSPDLOG_FMT_EXTERNAL=OFF
  
  # Control build steps
  UPDATE_COMMAND    ""    # Don't re-pull on rebuild
  TEST_COMMAND      ""    # Skip tests
  
  # For Ninja generator compatibility
  BUILD_BYPRODUCTS <INSTALL_DIR>/lib/libspdlog.a
)

# Create an imported target for downstream use
ExternalProject_Get_Property(ep_spdlog INSTALL_DIR)

add_library(spdlog::spdlog STATIC IMPORTED GLOBAL)
set_target_properties(spdlog::spdlog PROPERTIES
  IMPORTED_LOCATION ${INSTALL_DIR}/lib/libspdlog.a
  INTERFACE_INCLUDE_DIRECTORIES ${INSTALL_DIR}/include
)
add_dependencies(spdlog::spdlog ep_spdlog)

# Must create include dir at configure time for CMake validation
file(MAKE_DIRECTORY ${INSTALL_DIR}/include)
```

### Placeholders

| Placeholder      | Meaning                                    |
|-------------------|--------------------------------------------|
| `<SOURCE_DIR>`    | Where sources are extracted/cloned         |
| `<BINARY_DIR>`    | Build directory                            |
| `<INSTALL_DIR>`   | Install prefix (set via `PREFIX`)          |
| `<TMP_DIR>`       | Temp directory for scripts                 |

### Non-CMake Projects

```cmake
ExternalProject_Add(ep_openssl
  URL https://www.openssl.org/source/openssl-3.2.0.tar.gz
  URL_HASH SHA256=...
  CONFIGURE_COMMAND <SOURCE_DIR>/config --prefix=<INSTALL_DIR>
                    --openssldir=<INSTALL_DIR>/ssl
                    no-shared
  BUILD_COMMAND make -j${N}
  INSTALL_COMMAND make install_sw
  BUILD_IN_SOURCE TRUE
)
```

---

## Custom Find Modules

Write `Find<Package>.cmake` when a library doesn't provide CMake config files.

### Template: `cmake/FindLibFoo.cmake`

```cmake
# FindLibFoo.cmake — Find the Foo library
#
# Imported targets:
#   LibFoo::LibFoo — The Foo library
#
# Result variables:
#   LibFoo_FOUND
#   LibFoo_INCLUDE_DIRS
#   LibFoo_LIBRARIES
#   LibFoo_VERSION

find_path(LibFoo_INCLUDE_DIR
  NAMES foo/foo.h
  PATHS
    ${LibFoo_ROOT}
    ENV LibFoo_ROOT
  PATH_SUFFIXES include
)

find_library(LibFoo_LIBRARY
  NAMES foo libfoo
  PATHS
    ${LibFoo_ROOT}
    ENV LibFoo_ROOT
  PATH_SUFFIXES lib lib64
)

# Extract version from header
if(LibFoo_INCLUDE_DIR AND EXISTS "${LibFoo_INCLUDE_DIR}/foo/version.h")
  file(STRINGS "${LibFoo_INCLUDE_DIR}/foo/version.h" _ver_line
    REGEX "^#define[ \t]+FOO_VERSION[ \t]+\"[^\"]*\"")
  string(REGEX REPLACE ".*\"([^\"]*)\".*" "\\1" LibFoo_VERSION "${_ver_line}")
  unset(_ver_line)
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(LibFoo
  REQUIRED_VARS LibFoo_LIBRARY LibFoo_INCLUDE_DIR
  VERSION_VAR LibFoo_VERSION
)

if(LibFoo_FOUND AND NOT TARGET LibFoo::LibFoo)
  add_library(LibFoo::LibFoo UNKNOWN IMPORTED)
  set_target_properties(LibFoo::LibFoo PROPERTIES
    IMPORTED_LOCATION "${LibFoo_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${LibFoo_INCLUDE_DIR}"
  )
endif()

mark_as_advanced(LibFoo_INCLUDE_DIR LibFoo_LIBRARY)
```

### Usage

```cmake
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
find_package(LibFoo 2.0 REQUIRED)
target_link_libraries(myapp PRIVATE LibFoo::LibFoo)
```

### Best Practices

- Always create an `IMPORTED` target with a `Namespace::` prefix
- Use `find_package_handle_standard_args` for consistent output
- Support `<Package>_ROOT` variables (CMake 3.12+ honors these by default)
- Use `UNKNOWN IMPORTED` if you don't know if the library is static or shared
- Mark internal cache variables as advanced

---

## Imported Targets

Imported targets represent pre-built libraries/executables. They enable clean `target_link_libraries` usage without exposing build details.

### Types

```cmake
# Static library
add_library(ext::static STATIC IMPORTED)
set_target_properties(ext::static PROPERTIES
  IMPORTED_LOCATION "/opt/ext/lib/libext.a"
  INTERFACE_INCLUDE_DIRECTORIES "/opt/ext/include"
)

# Shared library
add_library(ext::shared SHARED IMPORTED)
set_target_properties(ext::shared PROPERTIES
  IMPORTED_LOCATION "/opt/ext/lib/libext.so.2.1"
  IMPORTED_SONAME "libext.so.2"
  INTERFACE_INCLUDE_DIRECTORIES "/opt/ext/include"
)

# On Windows — need implib
set_target_properties(ext::shared PROPERTIES
  IMPORTED_LOCATION "${_ext_prefix}/bin/ext.dll"
  IMPORTED_IMPLIB "${_ext_prefix}/lib/ext.lib"
)

# Per-configuration locations
set_target_properties(ext::mylib PROPERTIES
  IMPORTED_LOCATION_DEBUG "${_prefix}/lib/libextd.a"
  IMPORTED_LOCATION_RELEASE "${_prefix}/lib/libext.a"
)
```

### GLOBAL Keyword

By default, imported targets are visible only in the directory that created them. Use `GLOBAL` to make them visible project-wide:

```cmake
add_library(ext::mylib STATIC IMPORTED GLOBAL)
```

---

## Interface Libraries

Interface libraries have no build artifacts — they carry only usage requirements (headers, compile definitions, flags, link dependencies).

### Header-Only Libraries

```cmake
add_library(myheaderlib INTERFACE)
add_library(MyProject::myheaderlib ALIAS myheaderlib)

target_include_directories(myheaderlib INTERFACE
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)

target_compile_features(myheaderlib INTERFACE cxx_std_17)

target_compile_definitions(myheaderlib INTERFACE
  MYHEADER_VERSION=${PROJECT_VERSION}
)
```

### Compile Flag Bundles

Group related flags into an interface target for reuse:

```cmake
add_library(project_warnings INTERFACE)
target_compile_options(project_warnings INTERFACE
  $<$<CXX_COMPILER_ID:GNU,Clang>:
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion
    -Wnon-virtual-dtor -Wold-style-cast -Woverloaded-virtual
  >
  $<$<CXX_COMPILER_ID:MSVC>:
    /W4 /w14242 /w14254 /w14263 /w14265 /w14287
  >
)

add_library(project_options INTERFACE)
target_compile_features(project_options INTERFACE cxx_std_20)
set_target_properties(project_options PROPERTIES CXX_EXTENSIONS OFF)

# Usage — link once, applies everywhere
target_link_libraries(mylib PRIVATE project_warnings project_options)
target_link_libraries(myapp PRIVATE project_warnings project_options)
```

---

## Object Libraries

Object libraries compile sources to object files without creating an archive or shared library. Useful for sharing compiled objects between static and shared library variants.

```cmake
add_library(mylib_objects OBJECT
  src/core.cpp
  src/utils.cpp
)

target_include_directories(mylib_objects PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)

# Shared library needs PIC
set_target_properties(mylib_objects PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Build both static and shared from same objects
add_library(mylib_static STATIC $<TARGET_OBJECTS:mylib_objects>)
add_library(mylib_shared SHARED $<TARGET_OBJECTS:mylib_objects>)

# Since CMake 3.12, you can also link object libraries directly
add_library(mylib_static STATIC)
target_link_libraries(mylib_static PUBLIC mylib_objects)
```

### When to Use

- Building both static and shared variants without compiling twice
- Grouping object files that will be linked into multiple targets
- Avoiding intermediate archive creation overhead

---

## Toolchain Files for Cross-Compilation

### Structure

```cmake
# cmake/toolchains/aarch64-linux-gnu.cmake

# Target system
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Cross-compiler
set(CROSS_PREFIX aarch64-linux-gnu-)
set(CMAKE_C_COMPILER   ${CROSS_PREFIX}gcc)
set(CMAKE_CXX_COMPILER ${CROSS_PREFIX}g++)
set(CMAKE_ASM_COMPILER ${CROSS_PREFIX}gcc)
set(CMAKE_AR           ${CROSS_PREFIX}ar)
set(CMAKE_RANLIB       ${CROSS_PREFIX}ranlib)
set(CMAKE_STRIP        ${CROSS_PREFIX}strip)

# Sysroot (optional)
set(CMAKE_SYSROOT /opt/sysroots/aarch64-linux-gnu)

# Search behavior
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)   # Host tools
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)    # Target libs
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)    # Target headers
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)    # Target packages
```

### Embedded / Bare-Metal

```cmake
# cmake/toolchains/arm-none-eabi.cmake

set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   arm-none-eabi-gcc)
set(CMAKE_CXX_COMPILER arm-none-eabi-g++)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# MCU-specific flags
set(CMAKE_C_FLAGS_INIT   "-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16")
set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
```

### Using with Presets

```json
{
  "name": "cross-aarch64",
  "inherits": "dev",
  "toolchainFile": "${sourceDir}/cmake/toolchains/aarch64-linux-gnu.cmake",
  "cacheVariables": {
    "CMAKE_SYSROOT": "/opt/sysroots/aarch64"
  }
}
```

---

## Sanitizer Integration

### Modular CMake Function

```cmake
# cmake/Sanitizers.cmake

function(enable_sanitizers target)
  set(options "")
  set(oneValueArgs "")
  set(multiValueArgs SANITIZERS)
  cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  include(CheckCXXCompilerFlag)

  foreach(sanitizer IN LISTS ARG_SANITIZERS)
    check_cxx_compiler_flag("-fsanitize=${sanitizer}" HAS_${sanitizer})
    if(HAS_${sanitizer})
      list(APPEND _san_flags "-fsanitize=${sanitizer}")
    else()
      message(WARNING "Sanitizer '${sanitizer}' not supported by compiler")
    endif()
  endforeach()

  if(_san_flags)
    list(JOIN _san_flags "," _san_joined)
    target_compile_options(${target} PRIVATE -fsanitize=${_san_joined} -fno-omit-frame-pointer)
    target_link_options(${target} PRIVATE -fsanitize=${_san_joined})
  endif()
endfunction()
```

### Usage

```cmake
include(cmake/Sanitizers.cmake)

option(ENABLE_ASAN "Enable AddressSanitizer" OFF)
option(ENABLE_TSAN "Enable ThreadSanitizer" OFF)
option(ENABLE_UBSAN "Enable UndefinedBehaviorSanitizer" OFF)

set(_sanitizer_list "")
if(ENABLE_ASAN)
  list(APPEND _sanitizer_list address)
endif()
if(ENABLE_TSAN)
  list(APPEND _sanitizer_list thread)
endif()
if(ENABLE_UBSAN)
  list(APPEND _sanitizer_list undefined)
endif()

if(_sanitizer_list)
  enable_sanitizers(mylib SANITIZERS ${_sanitizer_list})
  enable_sanitizers(myapp SANITIZERS ${_sanitizer_list})
endif()
```

### Incompatibility Matrix

| Combination       | Compatible? |
|--------------------|:-----------:|
| ASan + UBSan       | ✅          |
| ASan + LSan        | ✅ (default)|
| ASan + TSan        | ❌          |
| TSan + UBSan       | ✅          |
| MSan + ASan/TSan   | ❌          |

### Runtime Options

```cmake
# Pass to test execution via environment
set_tests_properties(my_test PROPERTIES ENVIRONMENT
  "ASAN_OPTIONS=detect_leaks=1:halt_on_error=1"
  "UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1"
)
```

---

## Code Coverage with gcov/lcov

### CMake Integration

```cmake
# cmake/Coverage.cmake

option(ENABLE_COVERAGE "Enable code coverage" OFF)

if(ENABLE_COVERAGE)
  if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    message(WARNING "Coverage results are best with Debug builds")
  endif()

  include(CheckCXXCompilerFlag)
  check_cxx_compiler_flag(--coverage HAS_COVERAGE_FLAG)

  if(HAS_COVERAGE_FLAG)
    add_compile_options(--coverage -O0 -g)
    add_link_options(--coverage)
  else()
    message(FATAL_ERROR "Compiler does not support --coverage flag")
  endif()

  # Custom target to generate HTML report
  find_program(LCOV lcov)
  find_program(GENHTML genhtml)

  if(LCOV AND GENHTML)
    add_custom_target(coverage
      COMMAND ${LCOV} --directory ${CMAKE_BINARY_DIR} --capture
              --output-file coverage.info
      COMMAND ${LCOV} --remove coverage.info
              '/usr/*' '*/tests/*' '*/build/*' '*/external/*'
              --output-file coverage.filtered.info
      COMMAND ${GENHTML} coverage.filtered.info
              --output-directory ${CMAKE_BINARY_DIR}/coverage-report
              --title "${PROJECT_NAME} Coverage"
              --legend --show-details
      WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
      COMMENT "Generating coverage report..."
      VERBATIM
    )
  endif()
endif()
```

### Workflow

```bash
cmake -B build -DENABLE_COVERAGE=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build
cd build && ctest
cmake --build build --target coverage
# Open build/coverage-report/index.html
```

### With gcovr (Alternative to lcov)

```cmake
find_program(GCOVR gcovr)
if(GCOVR)
  add_custom_target(coverage-gcovr
    COMMAND ${GCOVR} --root ${CMAKE_SOURCE_DIR}
            --filter ${CMAKE_SOURCE_DIR}/src
            --filter ${CMAKE_SOURCE_DIR}/include
            --exclude '.*test.*'
            --html-details ${CMAKE_BINARY_DIR}/coverage.html
            --print-summary
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    COMMENT "Generating coverage report with gcovr"
  )
endif()
```

---

## Useful CMake Modules

### CheckCXXCompilerFlag

Test compiler flag support before using:

```cmake
include(CheckCXXCompilerFlag)

check_cxx_compiler_flag(-march=native HAS_MARCH_NATIVE)
if(HAS_MARCH_NATIVE)
  target_compile_options(mylib PRIVATE -march=native)
endif()

check_cxx_compiler_flag(-fcoroutines HAS_COROUTINES)
if(HAS_COROUTINES)
  target_compile_options(mylib PUBLIC -fcoroutines)
endif()
```

### WriteCompilerDetectionHeader

Generate a header with compiler feature detection macros:

```cmake
include(WriteCompilerDetectionHeader)

write_compiler_detection_header(
  FILE "${CMAKE_CURRENT_BINARY_DIR}/myproject_compiler_detection.h"
  PREFIX MYPROJECT
  COMPILERS GNU Clang MSVC
  FEATURES
    cxx_constexpr
    cxx_nullptr
    cxx_override
    cxx_noexcept
)
```

Generates macros like `MYPROJECT_COMPILER_CXX_CONSTEXPR` and
portability wrappers like `MYPROJECT_CONSTEXPR`.

### CheckIPOSupported

Enable link-time optimization safely:

```cmake
include(CheckIPOSupported)
check_ipo_supported(RESULT ipo_supported OUTPUT ipo_output)
if(ipo_supported)
  set_target_properties(mylib PROPERTIES INTERPROCEDURAL_OPTIMIZATION TRUE)
else()
  message(STATUS "IPO not supported: ${ipo_output}")
endif()
```

### FetchContent

(Covered in SKILL.md — see also `dependency-management.md` for advanced usage)

### GNUInstallDirs

Provides standard install directory variables:

```cmake
include(GNUInstallDirs)
# Available: CMAKE_INSTALL_BINDIR, CMAKE_INSTALL_LIBDIR,
#   CMAKE_INSTALL_INCLUDEDIR, CMAKE_INSTALL_DATADIR, etc.
```

### CMakePackageConfigHelpers

Generate config and version files for `find_package()` consumers:

```cmake
include(CMakePackageConfigHelpers)

configure_package_config_file(
  cmake/MyProjectConfig.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/MyProjectConfig.cmake
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/MyProject
)

write_basic_package_version_file(
  ${CMAKE_CURRENT_BINARY_DIR}/MyProjectConfigVersion.cmake
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion
  ARCH_INDEPENDENT   # For header-only libraries
)
```

---

## Package Versioning

### Version Compatibility Modes

`write_basic_package_version_file` supports these modes:

| Mode                      | Meaning                                          |
|---------------------------|--------------------------------------------------|
| `AnyNewerVersion`         | Any version ≥ requested is compatible            |
| `SameMajorVersion`        | Major version must match, minor+ can be newer    |
| `SameMinorVersion`        | Major.Minor must match (CMake 3.11+)             |
| `ExactVersion`            | Must be exactly the requested version             |

### Setting Project Version

```cmake
project(MyLib VERSION 2.3.1 LANGUAGES CXX)

# Components available:
#   PROJECT_VERSION         → "2.3.1"
#   PROJECT_VERSION_MAJOR   → "2"
#   PROJECT_VERSION_MINOR   → "3"
#   PROJECT_VERSION_PATCH   → "1"
```

### Generating a Version Header

```cmake
configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/include/mylib/version.h.in
  ${CMAKE_CURRENT_BINARY_DIR}/include/mylib/version.h
  @ONLY
)

# version.h.in:
# #pragma once
# #define MYLIB_VERSION "@PROJECT_VERSION@"
# #define MYLIB_VERSION_MAJOR @PROJECT_VERSION_MAJOR@
# #define MYLIB_VERSION_MINOR @PROJECT_VERSION_MINOR@
# #define MYLIB_VERSION_PATCH @PROJECT_VERSION_PATCH@
```

### Complete Versioned Install

```cmake
write_basic_package_version_file(
  ${CMAKE_CURRENT_BINARY_DIR}/MyLibConfigVersion.cmake
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion
)

install(FILES
  ${CMAKE_CURRENT_BINARY_DIR}/MyLibConfig.cmake
  ${CMAKE_CURRENT_BINARY_DIR}/MyLibConfigVersion.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/MyLib
)
```

Consumers then use: `find_package(MyLib 2.0 REQUIRED)` — finds 2.x.x but not 3.x.x.
