# C++ Dependency Management with CMake

## Table of Contents

- [Overview and Comparison](#overview-and-comparison)
- [FetchContent Advanced Usage](#fetchcontent-advanced-usage)
- [vcpkg Integration](#vcpkg-integration)
- [Conan 2.x Integration](#conan-2x-integration)
- [System Package Managers](#system-package-managers)
- [Vendoring Dependencies](#vendoring-dependencies)
- [Decision Framework](#decision-framework)

---

## Overview and Comparison

| Feature                 | FetchContent        | vcpkg               | Conan 2.x            | System Packages      | Vendoring            |
|-------------------------|---------------------|----------------------|----------------------|----------------------|----------------------|
| Central registry        | ❌                  | ✅ centralized       | ✅ decentralized     | ✅ per-distro        | ❌                   |
| Binary packages         | ❌ (source only)    | ✅ (from source)     | ✅ (prebuilt)        | ✅                   | ❌                   |
| Version management      | Manual (git tags)   | Global               | Per-project          | Distro-managed       | Manual               |
| Offline builds          | ✅ (with cache)     | ✅ (export mode)     | ✅ (local cache)     | ✅                   | ✅                   |
| Custom/private repos    | ✅ (any git URL)    | Complex              | Excellent            | N/A                  | ✅                   |
| Reproducibility         | Weak                | Moderate             | Excellent (lockfiles)| Weak                 | Excellent            |
| Build speed impact      | Slow (full rebuild) | Moderate             | Fast (binaries)      | None                 | Slow (full rebuild)  |
| Learning curve          | Low                 | Moderate             | Steep                | Low                  | Low                  |
| Cross-compilation       | Depends on deps     | Via triplets         | Via profiles         | Difficult            | Depends              |

---

## FetchContent Advanced Usage

### Basic Pattern (Review)

```cmake
include(FetchContent)

FetchContent_Declare(
  spdlog
  GIT_REPOSITORY https://github.com/gabime/spdlog.git
  GIT_TAG        v1.14.1
  GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(spdlog)
```

### Prefer System Packages with Fallback (CMake 3.24+)

```cmake
FetchContent_Declare(
  fmt
  GIT_REPOSITORY https://github.com/fmtlib/fmt.git
  GIT_TAG        10.2.1
  GIT_SHALLOW    TRUE
  FIND_PACKAGE_ARGS NAMES fmt    # Try find_package(fmt) first
)

# Global policy: always try system first
set(FETCHCONTENT_TRY_FIND_PACKAGE_MODE ALWAYS)

FetchContent_MakeAvailable(fmt)
```

### Override Dependency Options

```cmake
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.14.0
  GIT_SHALLOW    TRUE
)

# Set options BEFORE MakeAvailable
set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)  # Windows

FetchContent_MakeAvailable(googletest)
```

### Using URL Instead of Git

```cmake
FetchContent_Declare(
  json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757f21f1c2b2f4e50
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(json)
```

### Manual Population (Advanced Control)

```cmake
FetchContent_Declare(
  protobuf
  GIT_REPOSITORY https://github.com/protocolbuffers/protobuf.git
  GIT_TAG        v25.3
  GIT_SHALLOW    TRUE
  SOURCE_SUBDIR  cmake   # CMakeLists.txt is in a subdirectory
)

FetchContent_GetProperties(protobuf)
if(NOT protobuf_POPULATED)
  FetchContent_Populate(protobuf)
  
  # Custom configuration before add_subdirectory
  set(protobuf_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(protobuf_BUILD_PROTOC_BINARIES ON CACHE BOOL "" FORCE)
  
  add_subdirectory(${protobuf_SOURCE_DIR}/cmake ${protobuf_BINARY_DIR})
endif()
```

### Speeding Up FetchContent

```cmake
# Use FETCHCONTENT_BASE_DIR to share downloads across builds
set(FETCHCONTENT_BASE_DIR ${CMAKE_SOURCE_DIR}/.fetchcontent-cache)

# Skip updates on subsequent configures
set(FETCHCONTENT_UPDATES_DISCONNECTED ON)

# For CI: pre-populate with FETCHCONTENT_SOURCE_DIR_<name>
# cmake -DFETCHCONTENT_SOURCE_DIR_FMT=/path/to/local/fmt ..
```

### Grouping Dependencies

```cmake
# cmake/Dependencies.cmake
include(FetchContent)

FetchContent_Declare(fmt GIT_REPOSITORY ... GIT_TAG ...)
FetchContent_Declare(spdlog GIT_REPOSITORY ... GIT_TAG ...)
FetchContent_Declare(nlohmann_json URL ...)

FetchContent_MakeAvailable(fmt spdlog nlohmann_json)

# Top-level CMakeLists.txt:
include(cmake/Dependencies.cmake)
```

### Pitfalls

1. **Namespace collisions**: If two FetchContent deps both define a target with the same name,
   CMake errors out. No conflict resolution.
2. **Option pollution**: Deps may add options/targets/install rules you don't want.
   Use `set(... CACHE BOOL "" FORCE)` to override before `MakeAvailable`.
3. **Build time**: Every clean build recompiles all fetched sources.
   Consider using `ccache` or a package manager for heavy deps.
4. **Version conflicts**: If dep A and dep B both fetch different versions of dep C, the
   first declaration wins (CMake ignores subsequent `FetchContent_Declare` for the same name).

---

## vcpkg Integration

### Setup

```bash
# Clone vcpkg (or use as git submodule)
git clone https://github.com/microsoft/vcpkg.git
./vcpkg/bootstrap-vcpkg.sh   # Linux/macOS
.\vcpkg\bootstrap-vcpkg.bat  # Windows
```

### Manifest Mode (Recommended)

Create `vcpkg.json` in project root:

```json
{
  "name": "myproject",
  "version-string": "1.0.0",
  "dependencies": [
    "fmt",
    "spdlog",
    "boost-filesystem",
    {
      "name": "grpc",
      "version>=": "1.60.0"
    },
    {
      "name": "openssl",
      "platform": "!windows"
    }
  ],
  "overrides": [
    { "name": "fmt", "version": "10.2.1" }
  ],
  "builtin-baseline": "a1a1cbc975ed0bdd29cf..."
}
```

### CMake Integration via Presets

```json
{
  "version": 6,
  "configurePresets": [
    {
      "name": "vcpkg",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/${presetName}",
      "toolchainFile": "$env{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Debug"
      }
    },
    {
      "name": "vcpkg-release",
      "inherits": "vcpkg",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release"
      }
    }
  ]
}
```

### CMakeLists.txt (vcpkg-Agnostic)

```cmake
cmake_minimum_required(VERSION 3.20)
project(MyProject VERSION 1.0.0 LANGUAGES CXX)

# These just work — vcpkg toolchain sets up find_package paths
find_package(fmt REQUIRED CONFIG)
find_package(spdlog REQUIRED CONFIG)
find_package(Boost REQUIRED COMPONENTS filesystem)

add_executable(myapp src/main.cpp)
target_link_libraries(myapp PRIVATE
  fmt::fmt
  spdlog::spdlog
  Boost::filesystem
)
```

### Custom Triplets

```cmake
# custom-triplets/x64-linux-static.cmake
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)
```

```bash
# Use custom triplet
cmake --preset vcpkg -DVCPKG_OVERLAY_TRIPLETS=custom-triplets \
                     -DVCPKG_TARGET_TRIPLET=x64-linux-static
```

### Chaining with Custom Toolchain

```bash
# vcpkg provides VCPKG_CHAINLOAD_TOOLCHAIN_FILE for this purpose
cmake -B build \
  -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=cmake/toolchains/gcc-13.cmake
```

### Binary Caching for CI

```bash
# Enable binary caching (avoid rebuilding on CI)
export VCPKG_BINARY_SOURCES="clear;nuget,https://my-feed.example.com/index.json,readwrite"

# Or use GitHub Actions cache
export VCPKG_BINARY_SOURCES="clear;x-gha,readwrite"
```

---

## Conan 2.x Integration

### Setup

```bash
pip install conan
conan profile detect  # Auto-detect compiler, OS, etc.
```

### conanfile.py (Full Control)

```python
from conan import ConanFile
from conan.tools.cmake import cmake_layout

class MyProjectConan(ConanFile):
    name = "myproject"
    version = "1.0.0"
    settings = "os", "compiler", "arch", "build_type"
    generators = "CMakeToolchain", "CMakeDeps"

    def requirements(self):
        self.requires("fmt/10.2.1")
        self.requires("spdlog/1.14.1")
        self.requires("boost/1.84.0")
        self.requires("grpc/1.60.0")

    def build_requirements(self):
        self.tool_requires("cmake/3.28.1")
        self.tool_requires("ninja/1.11.1")

    def layout(self):
        cmake_layout(self)

    def configure(self):
        # Override transitive dependency options
        self.options["boost"].without_locale = True
        self.options["boost"].without_log = True
```

### conanfile.txt (Simple)

```ini
[requires]
fmt/10.2.1
spdlog/1.14.1
boost/1.84.0

[generators]
CMakeToolchain
CMakeDeps

[layout]
cmake_layout
```

### Workflow

```bash
# Install dependencies
conan install . --output-folder=build --build=missing

# Configure with generated toolchain
cmake --preset conan-release
# Or: cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake

# Build
cmake --build --preset conan-release
```

### CMakeLists.txt (Conan-Agnostic)

```cmake
cmake_minimum_required(VERSION 3.20)
project(MyProject VERSION 1.0.0 LANGUAGES CXX)

# Works identically whether deps come from Conan, vcpkg, or system
find_package(fmt REQUIRED)
find_package(spdlog REQUIRED)

add_executable(myapp src/main.cpp)
target_link_libraries(myapp PRIVATE fmt::fmt spdlog::spdlog)
```

### Profiles

```ini
# ~/.conan2/profiles/gcc13-debug
[settings]
os=Linux
arch=x86_64
compiler=gcc
compiler.version=13
compiler.cppstd=20
compiler.libcxx=libstdc++11
build_type=Debug

[conf]
tools.cmake.cmaketoolchain:generator=Ninja
tools.build:jobs=8
```

```bash
conan install . -pr gcc13-debug --output-folder=build --build=missing
```

### Cross-Compilation with Conan

```ini
# ~/.conan2/profiles/aarch64-linux
[settings]
os=Linux
arch=armv8
compiler=gcc
compiler.version=12
compiler.libcxx=libstdc++11
build_type=Release

[buildenv]
CC=aarch64-linux-gnu-gcc
CXX=aarch64-linux-gnu-g++
```

```bash
conan install . -pr:h aarch64-linux -pr:b default --build=missing
```

### Lockfiles for Reproducibility

```bash
# Generate lockfile
conan lock create .

# Install from lockfile (exact versions guaranteed)
conan install . --lockfile=conan.lock --build=missing
```

### Creating Your Own Conan Package

```python
from conan import ConanFile
from conan.tools.cmake import CMake, cmake_layout

class MyLibConan(ConanFile):
    name = "mylib"
    version = "1.0.0"
    settings = "os", "compiler", "arch", "build_type"
    generators = "CMakeToolchain", "CMakeDeps"
    exports_sources = "CMakeLists.txt", "src/*", "include/*"

    def layout(self):
        cmake_layout(self)

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["mylib"]
```

```bash
conan create .
```

---

## System Package Managers

### CMake Pattern for System Dependencies

```cmake
# Always try system packages first
find_package(ZLIB REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(CURL REQUIRED)

target_link_libraries(myapp PRIVATE
  ZLIB::ZLIB
  OpenSSL::SSL
  OpenSSL::Crypto
  CURL::libcurl
)
```

### Platform-Specific Install Commands

```bash
# Ubuntu/Debian
sudo apt install libboost-all-dev libssl-dev libcurl4-openssl-dev

# Fedora/RHEL
sudo dnf install boost-devel openssl-devel libcurl-devel

# macOS
brew install boost openssl curl

# Arch Linux
sudo pacman -S boost openssl curl
```

### Finding Packages via pkg-config

For libraries without CMake config files:

```cmake
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBAV REQUIRED IMPORTED_TARGET
  libavcodec
  libavformat
  libavutil
)

target_link_libraries(myapp PRIVATE PkgConfig::LIBAV)
```

### Hybrid Approach

```cmake
# Try system first, fall back to FetchContent
find_package(fmt 10.0 QUIET)
if(NOT fmt_FOUND)
  message(STATUS "fmt not found on system, fetching from source")
  include(FetchContent)
  FetchContent_Declare(fmt
    GIT_REPOSITORY https://github.com/fmtlib/fmt.git
    GIT_TAG 10.2.1
    GIT_SHALLOW TRUE
  )
  FetchContent_MakeAvailable(fmt)
endif()

target_link_libraries(myapp PRIVATE fmt::fmt)
```

---

## Vendoring Dependencies

### Structure

```
project/
├── CMakeLists.txt
├── third_party/
│   ├── CMakeLists.txt
│   ├── fmt/              # Full source copy or git submodule
│   ├── spdlog/
│   └── json/
└── src/
```

### Git Submodules

```bash
git submodule add https://github.com/fmtlib/fmt.git third_party/fmt
git submodule add https://github.com/gabime/spdlog.git third_party/spdlog
```

```cmake
# third_party/CMakeLists.txt

# Disable tests/examples for vendored deps
set(FMT_DOC OFF CACHE BOOL "" FORCE)
set(FMT_TEST OFF CACHE BOOL "" FORCE)
set(FMT_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(fmt)

set(SPDLOG_FMT_EXTERNAL ON CACHE BOOL "" FORCE)
set(SPDLOG_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SPDLOG_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(SPDLOG_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(spdlog)
```

### Header-Only Vendoring

```cmake
# Simplest approach for header-only libs
add_library(json INTERFACE)
target_include_directories(json INTERFACE
  ${CMAKE_CURRENT_SOURCE_DIR}/third_party/json/include
)
```

### When to Vendor

**Do vendor:**
- Header-only libraries (nearly zero maintenance)
- Small utilities without frequent updates
- When you need to patch the dependency
- Air-gapped / offline environments

**Don't vendor:**
- Large frameworks (Boost, Qt, LLVM)
- Security-critical libraries (OpenSSL) — you need updates
- Anything with complex transitive dependencies

---

## Decision Framework

### Quick Decision Tree

```
Need a C++ dependency?
│
├─ Header-only, < 5 files?
│   └─ Copy into project (vendor)
│
├─ Available via system package manager?
│   ├─ Stable API, security-critical?
│   │   └─ Use system packages
│   └─ Need specific version?
│       └─ Use vcpkg or Conan
│
├─ Small, self-contained CMake library?
│   └─ Use FetchContent
│
├─ Enterprise/CI environment, many deps?
│   └─ Use Conan 2.x (lockfiles, binary cache)
│
├─ Windows/Visual Studio focus?
│   └─ Use vcpkg (best IDE integration)
│
└─ Complex build, non-CMake deps?
    └─ Use ExternalProject_Add (superbuild)
```

### Recommended Combinations

**Open-source library:**
```
System packages (runtime deps) + FetchContent (dev-only deps like testing)
```

**Enterprise application:**
```
Conan 2.x (all deps) + lockfiles + CI binary cache
```

**Cross-platform application:**
```
vcpkg manifest mode + CMakePresets.json
```

**Embedded / cross-compilation:**
```
Conan 2.x with host/build profiles, or superbuild with ExternalProject_Add
```

### Mixed Approach Example

```cmake
cmake_minimum_required(VERSION 3.24)
project(MyApp VERSION 1.0.0 LANGUAGES CXX)

# System dependencies (stable, security-critical)
find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)

# FetchContent with system fallback (dev dependencies)
include(FetchContent)

FetchContent_Declare(fmt
  GIT_REPOSITORY https://github.com/fmtlib/fmt.git
  GIT_TAG 10.2.1
  GIT_SHALLOW TRUE
  FIND_PACKAGE_ARGS NAMES fmt    # Prefer system
)

FetchContent_Declare(googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG v1.14.0
  GIT_SHALLOW TRUE
  FIND_PACKAGE_ARGS NAMES GTest
)

FetchContent_MakeAvailable(fmt googletest)

add_executable(myapp src/main.cpp)
target_link_libraries(myapp PRIVATE
  OpenSSL::SSL
  ZLIB::ZLIB
  fmt::fmt
)
```
