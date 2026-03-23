#!/usr/bin/env bash
# cmake-init.sh — Initialize a new modern CMake C++ project
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <project-name> [options]

Initialize a new CMake C++ project with modern structure.

Options:
  -s, --standard <11|14|17|20|23>  C++ standard (default: 20)
  -t, --type <app|lib|both>        Project type (default: both)
  -p, --package-manager <none|vcpkg|conan>  Package manager (default: none)
  -h, --help                       Show this help

Example:
  $(basename "$0") my-awesome-lib --standard 20 --type lib --package-manager vcpkg
EOF
    exit "${1:-0}"
}

# Defaults
CXX_STANDARD=20
PROJECT_TYPE="both"
PKG_MANAGER="none"

# Parse arguments
if [[ $# -lt 1 ]]; then
    usage 1
fi

PROJECT_NAME="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--standard) CXX_STANDARD="$2"; shift 2 ;;
        -t|--type) PROJECT_TYPE="$2"; shift 2 ;;
        -p|--package-manager) PKG_MANAGER="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# Validate
if [[ ! "$CXX_STANDARD" =~ ^(11|14|17|20|23)$ ]]; then
    echo "Error: Invalid C++ standard: $CXX_STANDARD" >&2; exit 1
fi
if [[ ! "$PROJECT_TYPE" =~ ^(app|lib|both)$ ]]; then
    echo "Error: Invalid project type: $PROJECT_TYPE" >&2; exit 1
fi

# Convert project name to valid identifiers
PROJECT_UPPER=$(echo "$PROJECT_NAME" | tr '[:lower:]-' '[:upper:]_')
PROJECT_LOWER=$(echo "$PROJECT_NAME" | tr '[:upper:]-' '[:lower:]_')
PROJECT_NS="$PROJECT_NAME"

echo "Creating project: $PROJECT_NAME (C++$CXX_STANDARD, type=$PROJECT_TYPE)"

mkdir -p "$PROJECT_NAME"/{src,include/"$PROJECT_LOWER",tests,cmake}

# --- Root CMakeLists.txt ---
cat > "$PROJECT_NAME/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.20)
project(${PROJECT_NAME}
  VERSION 1.0.0
  DESCRIPTION "A modern C++ project"
  LANGUAGES CXX
)

# Prevent in-source builds
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
  message(FATAL_ERROR "In-source builds are not allowed. Use: cmake -B build")
endif()

# Options
option(${PROJECT_UPPER}_BUILD_TESTS "Build tests" ON)
option(${PROJECT_UPPER}_INSTALL "Generate install target" ON)

# Global settings for all targets
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Dependencies
# find_package(fmt REQUIRED CONFIG)

# Subdirectories
add_subdirectory(src)

if(${PROJECT_UPPER}_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
CMAKE

# --- src/CMakeLists.txt ---
if [[ "$PROJECT_TYPE" == "lib" || "$PROJECT_TYPE" == "both" ]]; then
    cat > "$PROJECT_NAME/src/CMakeLists.txt" <<CMAKE
add_library(${PROJECT_LOWER}
  ${PROJECT_LOWER}.cpp
)
add_library(${PROJECT_NS}::${PROJECT_LOWER} ALIAS ${PROJECT_LOWER})

target_include_directories(${PROJECT_LOWER}
  PUBLIC
    \$<BUILD_INTERFACE:\${CMAKE_SOURCE_DIR}/include>
    \$<INSTALL_INTERFACE:\${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE
    \${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_features(${PROJECT_LOWER} PUBLIC cxx_std_${CXX_STANDARD})
set_target_properties(${PROJECT_LOWER} PROPERTIES CXX_EXTENSIONS OFF)

# target_link_libraries(${PROJECT_LOWER} PUBLIC ...)
CMAKE

    if [[ "$PROJECT_TYPE" == "both" ]]; then
        cat >> "$PROJECT_NAME/src/CMakeLists.txt" <<CMAKE

add_executable(${PROJECT_LOWER}_app main.cpp)
target_link_libraries(${PROJECT_LOWER}_app PRIVATE ${PROJECT_NS}::${PROJECT_LOWER})
CMAKE
    fi

    # Source files
    cat > "$PROJECT_NAME/src/${PROJECT_LOWER}.cpp" <<CPP
#include "${PROJECT_LOWER}/${PROJECT_LOWER}.h"

namespace ${PROJECT_LOWER} {

std::string greet(const std::string& name) {
    return "Hello, " + name + "!";
}

} // namespace ${PROJECT_LOWER}
CPP

    # Public header
    cat > "$PROJECT_NAME/include/${PROJECT_LOWER}/${PROJECT_LOWER}.h" <<CPP
#pragma once

#include <string>

namespace ${PROJECT_LOWER} {

/// Returns a greeting string for the given name.
std::string greet(const std::string& name);

} // namespace ${PROJECT_LOWER}
CPP

    if [[ "$PROJECT_TYPE" == "both" ]]; then
        cat > "$PROJECT_NAME/src/main.cpp" <<CPP
#include "${PROJECT_LOWER}/${PROJECT_LOWER}.h"
#include <iostream>

int main() {
    std::cout << ${PROJECT_LOWER}::greet("World") << std::endl;
    return 0;
}
CPP
    fi
elif [[ "$PROJECT_TYPE" == "app" ]]; then
    cat > "$PROJECT_NAME/src/CMakeLists.txt" <<CMAKE
add_executable(${PROJECT_LOWER} main.cpp)

target_compile_features(${PROJECT_LOWER} PUBLIC cxx_std_${CXX_STANDARD})
set_target_properties(${PROJECT_LOWER} PROPERTIES CXX_EXTENSIONS OFF)

# target_link_libraries(${PROJECT_LOWER} PRIVATE ...)
CMAKE

    cat > "$PROJECT_NAME/src/main.cpp" <<CPP
#include <iostream>

int main() {
    std::cout << "Hello from ${PROJECT_NAME}!" << std::endl;
    return 0;
}
CPP
fi

# --- tests/CMakeLists.txt ---
cat > "$PROJECT_NAME/tests/CMakeLists.txt" <<CMAKE
include(FetchContent)

FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.14.0
  GIT_SHALLOW    TRUE
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

include(GoogleTest)
CMAKE

if [[ "$PROJECT_TYPE" == "lib" || "$PROJECT_TYPE" == "both" ]]; then
    cat >> "$PROJECT_NAME/tests/CMakeLists.txt" <<CMAKE

add_executable(${PROJECT_LOWER}_tests test_${PROJECT_LOWER}.cpp)
target_link_libraries(${PROJECT_LOWER}_tests PRIVATE
  ${PROJECT_NS}::${PROJECT_LOWER}
  GTest::gtest_main
)

gtest_discover_tests(${PROJECT_LOWER}_tests
  DISCOVERY_TIMEOUT 30
)
CMAKE

    cat > "$PROJECT_NAME/tests/test_${PROJECT_LOWER}.cpp" <<CPP
#include <gtest/gtest.h>
#include "${PROJECT_LOWER}/${PROJECT_LOWER}.h"

TEST(${PROJECT_NS}Test, Greet) {
    EXPECT_EQ(${PROJECT_LOWER}::greet("World"), "Hello, World!");
}

TEST(${PROJECT_NS}Test, GreetEmpty) {
    EXPECT_EQ(${PROJECT_LOWER}::greet(""), "Hello, !");
}
CPP
else
    cat >> "$PROJECT_NAME/tests/CMakeLists.txt" <<CMAKE

# add_executable(app_tests test_main.cpp)
# target_link_libraries(app_tests PRIVATE GTest::gtest_main)
# gtest_discover_tests(app_tests)
CMAKE
fi

# --- CMakePresets.json ---
cat > "$PROJECT_NAME/CMakePresets.json" <<JSON
{
  "version": 6,
  "cmakeMinimumRequired": { "major": 3, "minor": 20 },
  "configurePresets": [
    {
      "name": "dev",
      "description": "Development build",
      "generator": "Ninja",
      "binaryDir": "\${sourceDir}/build/\${presetName}",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_EXPORT_COMPILE_COMMANDS": "ON",
        "${PROJECT_UPPER}_BUILD_TESTS": "ON"
      }
    },
    {
      "name": "release",
      "description": "Release build",
      "inherits": "dev",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release",
        "${PROJECT_UPPER}_BUILD_TESTS": "OFF"
      }
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
JSON

# --- .gitignore ---
cat > "$PROJECT_NAME/.gitignore" <<GIT
build/
cmake-build-*/
.cache/
compile_commands.json
CMakeUserPresets.json
*.o
*.a
*.so
*.dylib
*.dll
*.lib
*.exe
GIT

# --- cmake/MyProjectConfig.cmake.in ---
if [[ "$PROJECT_TYPE" == "lib" || "$PROJECT_TYPE" == "both" ]]; then
    cat > "$PROJECT_NAME/cmake/${PROJECT_NAME}Config.cmake.in" <<CMAKE
@PACKAGE_INIT@

include(CMakeFindDependencyMacro)
# find_dependency(fmt 10.0)

include("\${CMAKE_CURRENT_LIST_DIR}/${PROJECT_NAME}Targets.cmake")
check_required_components(${PROJECT_NAME})
CMAKE
fi

# --- Package manager files ---
case "$PKG_MANAGER" in
    vcpkg)
        cat > "$PROJECT_NAME/vcpkg.json" <<JSON
{
  "name": "${PROJECT_LOWER}",
  "version-string": "1.0.0",
  "dependencies": []
}
JSON
        echo "Created vcpkg.json"
        ;;
    conan)
        cat > "$PROJECT_NAME/conanfile.txt" <<CONAN
[requires]

[generators]
CMakeToolchain
CMakeDeps

[layout]
cmake_layout
CONAN
        echo "Created conanfile.txt"
        ;;
esac

# --- Symlink compile_commands.json ---
cat > "$PROJECT_NAME/.clang-format" <<CLANG
BasedOnStyle: LLVM
IndentWidth: 4
ColumnLimit: 100
CLANG

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Get started:"
echo "  cd $PROJECT_NAME"
echo "  cmake --preset dev"
echo "  cmake --build --preset dev"
echo "  ctest --preset dev"
