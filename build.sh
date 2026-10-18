#!/bin/zsh
# Builds XCharge.app (menu bar UI) and xchargectl daemon into ./build
set -e
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/obj
clang -c -O2 -mmacosx-version-min=14.0 Sources/Daemon/smc.c -o build/obj/smc.o
swiftc -O -swift-version 5 -target arm64-apple-macos14 \
  -import-objc-header Sources/Daemon/smc.h \
  Sources/Shared/Model.swift Sources/Daemon/SafeFiles.swift Sources/Daemon/main.swift build/obj/smc.o \
  -framework IOKit -o build/com.ismailx.xcharge.daemon
APP=build/XCharge.app/Contents
mkdir -p $APP/MacOS $APP/Resources
clang -c -O2 -mmacosx-version-min=14.0 -fobjc-arc Sources/App/OBC.m -o build/obj/obc.o
swiftc -O -swift-version 5 -target arm64-apple-macos14 -parse-as-library \
  -import-objc-header Sources/App/OBC.h \
  Sources/Shared/Model.swift Sources/App/XChargeApp.swift Sources/App/Updater.swift build/obj/obc.o -o $APP/MacOS/XCharge
cp Resources/Info.plist $APP/Info.plist
cp Resources/AppIcon.icns $APP/Resources/
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $(cat VERSION)" $APP/Info.plist
$PB -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" $APP/Info.plist
$PB -c "Add :XChargeRepoPath string $PWD" $APP/Info.plist
codesign --force --options runtime --sign - build/XCharge.app
codesign --force --options runtime --sign - --identifier com.ismailx.xcharge.daemon build/com.ismailx.xcharge.daemon
echo "Built: build/XCharge.app + build/com.ismailx.xcharge.daemon"
