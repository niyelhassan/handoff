#!/bin/sh
# Source this; do not execute.
#
# Xcode 16.1 on macOS 26.6 has a broken xcodebuild/xcrun: they abort with
#   dlopen(libxcodebuildLoader.dylib): Symbol not found: _XPCTypeBool
# (CoreDevice <-> Mercury mismatch). The TOOLCHAIN BINARIES are fine; only the
# shims that route through xcodebuild are not. So: absolute paths everywhere,
# and never call bare `swift`, `swiftc`, `clang`, or `xcrun`.

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export TOOLCHAIN_BIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
export MACOSX_DEPLOYMENT_TARGET="15.0"

# Toolchain first: SwiftPM shells out to bare `clang` (for linking), `ar`, and
# `swift-frontend`. /usr/bin/clang is a shim that routes through xcode-select
# and aborts. Prepending the real bin dir bypasses every shim.
# $DEVELOPER_DIR/usr/bin holds the REAL make, git, etc. /usr/bin/make is
# itself an xcode-select shim and aborts like the rest of them.
export PATH="$TOOLCHAIN_BIN:$DEVELOPER_DIR/usr/bin:$PATH"

export SWIFT="$TOOLCHAIN_BIN/swift"
export SWIFTC="$TOOLCHAIN_BIN/swiftc"
