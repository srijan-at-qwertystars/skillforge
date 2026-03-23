# ARM Cross-Compilation Toolchain File
#
# Usage:
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-linux.cmake
#   Or reference via CMakePresets.json: "toolchainFile": "cmake/toolchains/arm-linux.cmake"
#
# Customize:
#   - Set CROSS_COMPILE_PREFIX for your specific toolchain
#   - Set CMAKE_SYSROOT if using a custom sysroot
#   - Adjust MCU_FLAGS for your target hardware

# ── Target System ────────────────────────────────────────────────────────────

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# ── Cross-Compiler ───────────────────────────────────────────────────────────

# Change this prefix to match your installed cross-toolchain
# Common options:
#   aarch64-linux-gnu-    (64-bit ARM Linux)
#   arm-linux-gnueabihf-  (32-bit ARM Linux, hard float)
#   arm-none-eabi-        (Bare-metal ARM, no OS)
set(CROSS_COMPILE_PREFIX aarch64-linux-gnu-)

set(CMAKE_C_COMPILER   ${CROSS_COMPILE_PREFIX}gcc)
set(CMAKE_CXX_COMPILER ${CROSS_COMPILE_PREFIX}g++)
set(CMAKE_ASM_COMPILER ${CROSS_COMPILE_PREFIX}gcc)
set(CMAKE_AR           ${CROSS_COMPILE_PREFIX}ar)
set(CMAKE_RANLIB       ${CROSS_COMPILE_PREFIX}ranlib)
set(CMAKE_STRIP        ${CROSS_COMPILE_PREFIX}strip)
set(CMAKE_OBJCOPY      ${CROSS_COMPILE_PREFIX}objcopy)
set(CMAKE_OBJDUMP      ${CROSS_COMPILE_PREFIX}objdump)
set(CMAKE_SIZE         ${CROSS_COMPILE_PREFIX}size)

# ── Sysroot (Optional) ──────────────────────────────────────────────────────

# Uncomment and set if using a custom sysroot
# set(CMAKE_SYSROOT /opt/sysroots/aarch64-linux-gnu)
# set(CMAKE_STAGING_PREFIX /opt/staging/aarch64)

# ── Search Behavior ──────────────────────────────────────────────────────────

# NEVER:  Search host paths (for build tools like protoc, flatc)
# ONLY:   Search target paths only (for libraries, headers, packages)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# ── Default Flags (Optional) ────────────────────────────────────────────────

# CPU-specific optimization flags
# Uncomment and adjust for your target:

# Cortex-A53 (Raspberry Pi 3/4)
# set(CMAKE_C_FLAGS_INIT   "-mcpu=cortex-a53 -mfpu=neon-fp-armv8")
# set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-a53 -mfpu=neon-fp-armv8")

# Cortex-A72 (Raspberry Pi 4, higher performance)
# set(CMAKE_C_FLAGS_INIT   "-mcpu=cortex-a72")
# set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-a72")

# Generic AArch64
# set(CMAKE_C_FLAGS_INIT   "-march=armv8-a")
# set(CMAKE_CXX_FLAGS_INIT "-march=armv8-a")

# ── Bare-Metal Variant ───────────────────────────────────────────────────────

# Uncomment the following block for bare-metal (no OS) targets:
# set(CMAKE_SYSTEM_NAME Generic)
# set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
# set(CROSS_COMPILE_PREFIX arm-none-eabi-)
# 
# Cortex-M4 (STM32F4, nRF52)
# set(MCU_FLAGS "-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16")
# set(CMAKE_C_FLAGS_INIT   "${MCU_FLAGS}")
# set(CMAKE_CXX_FLAGS_INIT "${MCU_FLAGS}")
# set(CMAKE_ASM_FLAGS_INIT "${MCU_FLAGS}")
#
# Linker script (required for bare-metal)
# set(CMAKE_EXE_LINKER_FLAGS_INIT "-T ${CMAKE_SOURCE_DIR}/linker.ld -Wl,--gc-sections")
