#!/bin/zsh
# Builds and runs the tests. They only use temp folders; your real files are never touched.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/tests
F=(-swift-version 5 -target arm64-apple-macos14)
swiftc $F Sources/Shared/*.swift Sources/App/Core/*.swift Tests/CoreTests/main.swift -o build/tests/core
swiftc $F Sources/Shared/*.swift Sources/Helper/SafeFiles.swift Sources/Helper/Actions.swift Tests/HelperTests/main.swift -o build/tests/helper
build/tests/core
build/tests/helper
