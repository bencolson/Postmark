# MailKit Extension: root cause & fix

**Scope:** `PostmarkMail` (MailKit `MEMessageActionHandler` app extension embedded
in `Postmark.app`).

**Status:** RESOLVED 2026-09-17 — the Xcode-compiled appex never ran; a
bare-`swiftc`-compiled appex of the *identical sources* runs correctly.

---

## 1. Symptom

- The extension was registered and toggled ON in Mail → Settings → Extensions,
  but never performed the fast-path signal: no `postmark-signal.txt`, no
  `Trigger: MailKit signal` in the Activity log — triage effectively ran on the
  5-minute poll only.
- Every MailKit attempt to use the extension produced a crash:
  `~/Library/Logs/DiagnosticReports/PostmarkMail-*.ips`, **30+** logs from
  2026-09-09 onwards, one per launch attempt.

## 2. Crash signature (identical in every log)

```
Exception:   EXC_BREAKPOINT / SIGTRAP            (Swift fatalError / trap)
Fault addr:  0x00000002329a66b8
Faulting frame:
  ExtensionFoundation  +[EXConcreteExtensionContextVendor _extensionContextClass]
    _block_invoke  (a dispatch_once block)
Called from: -[EXConcreteExtensionContextVendor listener:shouldAcceptNewConnection:]
             ← ExtensionFoundation service_connection_handler_make_connection
             ← libxpc        (the appex's XPC listener accepting the host connection)
Parent:      launchd (the appex is spawned by ExtensionKit directly)
osVersion:   macOS 26.6.2, build 25G83
```

Key properties:

- The trap fires **before any Postmark code executes** — zero
  `PostmarkMail` frames in every fault stack; `decideAction` is never invoked.
- It is in the **extension bootstrap**, when ExtensionFoundation finalises the
  extension-context class on the first incoming XPC connection from Mail.
- The offending instruction address `0x2329a66b8` is byte-identical across all
  30+ crashes, independent of everything tested below.

## 3. What was ruled out (evidence table)

| Hypothesis | Result |
|---|---|
| Ad-hoc signing | ✗ — ad-hoc appexes crash identically |
| Developer ID signing | ✗ — Xcode Developer-ID builds crash identically |
| Notarized build | ✗ — the notarized 0.2.0 appex crashes identically |
| Entitlements (app-sandbox alone, + application-groups) | ✗ — same trap with both |
| Registration origin (DerivedData, /Applications, ~/Applications) | ✗ — same trap |
| Info.plist shape (differs from Apple's Mail Extension template/WWDC21 sample) | ✗ — matches; crash unchanged |
| The sandbox / file-based signal design | ✗ — the appex's own container is writable (system CrashReporter files live there); never reached anyway |
| macOS 26.6.2 general defect affecting all appexes | ✗ — no other appex on this machine shows this trap; a control appex did run |
| **Our handler code** | ✗ — see §4: same code works when compiled differently |

## 4. The decisive bisection

Two appexes were built with the **same bundle id, same Info.plist, same
entitlements, same signing** — the only difference being how the Swift sources
were compiled:

| Build | Result |
|---|---|
| **Trivial** handler (no static storage, no extras) | **Works.** `trivial-decided.txt` written to its container on 2026-09-14 08:34 (real `decideAction` ran; no crash). |
| **Real sources** (`MailExtension.swift` + `MessageActionHandler.swift`), compiled with **bare `swiftc`** (`-parse-as-library -Xlinker -e -Xlinker _NSExtensionMain`, no Xcode build settings) | **Works.** `postmark-signal.txt` contains a real message-id; daemon logged `Trigger: MailKit signal (<923583A4-…@bencolson.com>)` → `MailKit-triggered triage run` (2026-09-17 20:39). |
| **Real sources**, compiled by **Xcode** (Debug and Release, all signings) | **Crashes.** Same `0x2329a66b8` trap. |

Conclusion: **the source code, Info.plist, bundle identity, and signing are all
innocent. The crash is caused by the Swift class metadata (and/or linkage) that
Xcode's build settings emit for the appex binary.** ExtensionFoundation's
class-finalization check inside `+[EXConcreteExtensionContextVendor
_extensionContextClass]` trips on the Xcode-compiled variant at bootstrap,
before MailKit ever calls `handlerForMessageActions` or `decideAction`.

## 5. Root cause (state of knowledge)

One line: **compiling the MailKit appex with Xcode's default per-target Swift
settings produces a binary whose clclass metadata ExtensionFoundation rejects
with a Swift `fatalError` during extension-context bootstrap; compiling the
identical sources with a bare `swiftc` invocation (language mode and flag set
defaulted by the toolchain) produces a binary that boots and runs fine.**

The *exact* build setting responsible has not been isolated (candidates:
`SWIFT_VERSION` language-mode pinning, Xcode's injected frontend flags, the
`SWIFT_UPCOMING_FEATURE_*` / `SWIFT_APPROACHABLE_CONCURRENCY` settings on the
target, or link-time differences Xcode injects into the executable). Because the
bare-`swiftc` binary demonstrably works, a durable fix was chosen over further
flag forensics (see §6). If anyone revisits the flag hunt: compile the appex
with `swiftc -###` and diff the emitted frontend flags against a known-good
bare build.

## 6. The fix

1. `scripts/build-mailkit-appex.sh` — compiles the appex executable with the
   proven recipe:

   ```
   swiftc \
     -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" \
     -parse-as-library -Xlinker -e -Xlinker _NSExtensionMain \
     -framework MailKit \
     PostmarkMail/MailExtension.swift PostmarkMail/MessageActionHandler.swift \
     -o <appex>/Contents/MacOS/PostmarkMail
   ```

2. The Makefile `build`, `release`, and `sign` targets call the script after
   assembling the bundle, then **re-seal**:
   - re-sign the appex (its own entitlements),
   - re-sign the parent `Postmark.app` bundle (the parent embeds the appex's
     code-directory hash — replacing the appex invalidates the old seal),
   - `codesign --verify --deep --strict`.

   Replacing the appex must happen **before** `make notarize` zips the bundle,
   or the notarized artifact would contain the crashing Xcode appex.

3. Do **not** let xcodebuild produce the appex executable for shipping. Editing
   the `PostmarkMail` target's build settings to match the working recipe is
   possible future cleanup, but the script path is the canonical guarantee.

## 7. Verification

End-to-end, on 2026-09-17:

```
~/Library/Containers/ltd.colson.postmark.PostmarkMail/Data/Documents/postmark-signal.txt
  → 1789677543 / <923583A4-964F-4CDE-A4A0-0E1D4F302408@bencolson.com>
Activity log:
  20:39:11 Trigger: MailKit signal (<923583A4-…@bencolson.com>)
  20:39:32 MailKit-triggered triage run
  20:39:32 Run started — manual, live mode
```

No new `PostmarkMail-*.ips` after the bare-`swiftc` build was installed.
`make release-dmg` from the fixed tree: notarization **Accepted**, both app and
DMG stapled, `spctl`: `Notarized Developer ID`.

## 8. Timeline

| When | What |
|---|---|
| 2026-08-31 | `PostmarkMail` target created; first appex launches (container created) |
| 2026-09-09 | First crash logs (`EXConcreteExtensionContextVendor` trap) — every launch since died in the extension |
| 2026-09-13 → 14 | Exhaustive false-lead investigation (signing, entitlements, registration, sandbox model, "macOS defect") |
| 2026-09-14 08:34 | Trivial bare-`swiftc` appex writes `trivial-decided.txt` — first hint it is NOT the OS |
| 2026-09-17 20:39 | Real sources, bare `swiftc`: full signal chain fires; root cause identified |
| 2026-09-17 21:47 | `scripts/build-mailkit-appex.sh` + Makefile wiring committed (`0b2706c`); DMG notarized |

## 9. Related

- Summary section: `docs/postmark-plan.md` → "MailKit extension: RESOLVED".
- The extension's signal contract: appex writes
  `~/Library/Containers/ltd.colson.postmark.PostmarkMail/Data/Documents/postmark-signal.txt`
  (`<unixEpoch>\n<messageID>\n`); daemon `TriageTrigger` watches it and converts
  an advance into a debounced, rate-limited triage run. The 5-minute poll is
  the source of truth and the backstop.