#!/bin/zsh
# Builds MacCleaner.app and its root helper into ./build
set -e
cd "$(dirname "$0")"
rm -rf build && mkdir -p build
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14)

swiftc $FLAGS Sources/Shared/*.swift Sources/Helper/*.swift -o build/com.ismailx.maccleaner.helper

APP=build/MacCleaner.app/Contents
mkdir -p $APP/MacOS $APP/Resources
swiftc $FLAGS -parse-as-library Sources/Shared/*.swift Sources/App/*.swift Sources/App/Core/*.swift Sources/App/Views/*.swift \
  -o $APP/MacOS/MacCleaner
cp Resources/Info.plist $APP/Info.plist
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Resources/
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $(cat VERSION)" $APP/Info.plist
$PB -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" $APP/Info.plist
$PB -c "Add :MacCleanerRepoPath string $PWD" $APP/Info.plist
codesign --force --options runtime --sign - build/MacCleaner.app
codesign --force --options runtime --sign - --identifier com.ismailx.maccleaner.helper build/com.ismailx.maccleaner.helper
echo "Built: build/MacCleaner.app + build/com.ismailx.maccleaner.helper"
