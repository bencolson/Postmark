#!/bin/bash
# Builds PostmarkMail.appex's executable with a bare swiftc invocation that is
# PROVEN not to crash ExtensionFoundation on macOS 26.6.2.
#
# Why: the Xcode-compiled appex SIGTRAPs at
# `EXConcreteExtensionContextVendor._extensionContextClass` (EXC_BREAKPOINT,
# address 0x2329a66b8) during bootstrap — before decideAction ever runs —
# every build (Debug + Release, ad-hoc + Developer ID + notarized). Compiling
# the identical sources with bare `swiftc` (no Xcode build settings) loads and
# fires decideAction fine (verified end-to-end 2026-09-17). The emitted Swift
# class metadata differs, and Xcode's variant trips ExtensionFoundation's
# class-finalization check.
#
# Use this instead of letting xcodebuild produce the appex executable. After
# swapping the binary in, re-sign the appex (and, because it changes nested
# code, the parent bundle) — see the Makefile `sign` and `release` targets.
set -euo pipefail

APPEX="${1:?usage: build-mailkit-appex.sh <PostmarkMail.appex dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
xcrun swiftc \
  -target arm64-apple-macos14.0 -sdk "$SDK" \
  -parse-as-library \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -framework MailKit \
  "$ROOT/PostmarkMail/MailExtension.swift" \
  "$ROOT/PostmarkMail/MessageActionHandler.swift" \
  -o "$APPEX/Contents/MacOS/PostmarkMail"

echo "✅ PostmarkMail.appex executable rebuilt (bare swiftc)"
