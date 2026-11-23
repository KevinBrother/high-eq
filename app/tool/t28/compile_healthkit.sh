#!/usr/bin/env bash
# Compile the real Runner Swift sources against iPhone Simulator / HealthKit;
# does not boot a device, sign, authorize, or read anything. Run pub get first.
set -euo pipefail
cd "$(dirname "$0")/../.."
flutter_root=${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}
framework="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# GeneratedPluginRegistrant is a Flutter build product and is intentionally
# ignored by git. Supply only its declaration for this compile-only check.
mkdir -p "$out/include"
cat >"$out/include/GeneratedPluginRegistrant.h" <<'HEADER'
#import <Flutter/Flutter.h>

@interface GeneratedPluginRegistrant : NSObject
+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry;
@end
HEADER
xcrun --sdk iphonesimulator swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios15.0-simulator -F "$framework" -module-cache-path "$out/modules" \
  -Xcc -I -Xcc "$out/include" \
  -import-objc-header ios/Runner/Runner-Bridging-Header.h -whole-module-optimization \
  -emit-object ios/Runner/{AppDelegate,MobileCommerce,HealthHistory,VoiceCapture,VoicePCMConverter,VoicePCMCaptureSession}.swift \
  ios/ReplyShare/ReplyInbox.swift -o "$out/Runner.o"
file "$out/Runner.o" | grep 'Mach-O 64-bit object arm64'
