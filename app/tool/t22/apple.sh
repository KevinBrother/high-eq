#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
plutil -lint ios/Runner.xcodeproj/project.pbxproj ios/Runner/Runner.entitlements ios/ReplyShare/{Info.plist,ReplyShare.entitlements}
xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -module-cache-path "$tmp/cache" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" ios/ReplyShare/*.swift
xcrun --sdk macosx swiftc -module-cache-path "$tmp/cache" ios/ReplyShare/ReplyInbox.swift tool/t22/inbox_check.swift -o "$tmp/check"
"$tmp/check"
