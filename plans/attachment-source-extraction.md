# Plan: source-based attachment extraction (Silo doc-forward + Hubdoc)

**Goal** — fix the inert Silo production-doc forward and the empty-attachment
bookkeeping path. Root cause (verified 2026-09-18): Mail's AppleScript
`every attachment` / `count of attachments` element errors `-1728` for every
message on macOS 26.6.2 (reproduced via bare `osascript`, not Postmark), so
`MailMessage.attachments` is always empty → the attachment pass never fires →
no call sheets reach Silo, and every receipt forward skips on "0 attachments".
Verified working alternative: `source of <message>` returns the full raw RFC822
message (1.8 MB for the McD's FESTIVE call sheet).

## Architecture

Replace "trust Mail's attachment enumeration" with "parse attachments from the
message's MIME source". One resolution point upstream of all consumers so
everything (Silo doc forward, receipt→Hubdoc forward, attachment classifier)
works off the same populated list.

## Changes

### 1. `Postmark/Models/MailMessage.swift`
- `MailAttachment`: add `var data: Data?` (decoded bytes once resolved).
- `MailMessage`: `attachments` becomes `var`; add `var attachmentsResolved = false`.

### 2. New file `Postmark/Services/Mail/MIMEParser.swift`
Minimal RFC 2045/2046 walker (no third-party deps):
```swift
enum MIMEParser {
    static func parse(source: String) -> [MailAttachment]   // name, size, data
}
```
- Walk MIME tree: headers until blank line; `Content-Type` (subtype, boundary),
  `Content-Disposition` (attachment/inline, `filename=`), `Content-Transfer-Encoding`.
- multipart/* → split body on boundary (handle `--boundary`, `--boundary--`)
  and recurse into child parts.
- Leaf parts: attachment iff it carries an explicit filename
  (`Content-Disposition: attachment; filename="…"` **or** `Content-Type: …; name="…"`).
  This matches Mail's "attachments" semantics (inline images without a filename
  are excluded); the existing `onlyTypes` gate ([Call Sheets, Movement Orders,
  Risk Assessments, Storyboards, Treatments, Specs]) does the semantic filter later.
- Decode body data: `base64` via `Data(base64Encoded:)`, `quoted-printable` via
  a small manual decoder, otherwise raw bytes.
- `size = data.count`; skip empty/zero-length parts and filename-less leaves.

### 3. `Postmark/Services/Mail/MailScripts.swift`
- Add `static func messageSource(messageID:) -> String` — AppleScript that
  looks the message up in inbox then every mailbox of every account (the same
  search `markRead`/`saveAttachments` already use; the message may already have
  been moved by a rule before the forward runs) and returns `source of m`.
- Delete the now-unused AppleScript `saveAttachments(...)` constant once the
  forwarder stops calling it (grep to confirm; only `SiloForwarder` uses it).

### 4. `Postmark/Services/Mail/MailBridge.swift`
- Add `static func resolveAttachments(for messageID: String) async throws -> [MailAttachment]`:
  `executeAppleScript(MailScripts.messageSource(messageID:))` → guard non-empty →
  `MIMEParser.parse` → `MailAttachment(name:size:data:)`.

### 5. `Postmark/Services/Silo/SiloForwarder.swift`
- Rewrite `saveAttachments(of:into:outcome:)` to stop using AppleScript:
  for each `MessageAttachment` with `data != nil`, write bytes to
  `folder/<sanitized filename>` (strip `/` `:` `\`; skip empties) and map
  `name → path`; missing `data` → append "attachment data missing: <name>"
  to `outcome.errors` (preserves the existing skip-guard semantics: an
  unresolvable attachment still prevents an empty forward).
- Both `forward(...)` and `forwardWholeMessage(...)` keep their
  `guard !attachFiles.isEmpty` skips unchanged.

### 6. `Postmark/Services/Triage/TriageCoordinator.swift`
After classification (message 1449 at line ~101), before the step-2 attachment
pass, resolve the real attachment list:
```swift
if !message.attachmentsResolved {
    do {
        message.attachments = try await MailBridge.resolveAttachments(for: message.id)
        message.attachmentsResolved = true
        ActivityLog.record("Resolved \(message.attachments.count) attachment(s) from MIME source", kind: .poll, level: .debug, messageID: message.id)
    } catch {
        // Never mark cooldown / never silently skip: a resolution failure
        // means we cannot know whether a production doc exists — retry next run.
        errors.append("\(message.subject): attachment resolution failed: \(error.localizedDescription)")
        await ActivityLog.shared.record(
            "Attachment resolution failed (\(error.localizedDescription)) — not cooldown-marked: will retry",
            kind: .silo, level: .error, messageID: message.id)
        continue   // skips steps 2+3 for this message this run
    }
}
```
- Step 2's `if !message.attachments.isEmpty` gate then sees the resolved list;
  the classifier, doc-forward, and receipt-forward all consume the same data.
- No cooldown: unchanged for classification failures (already `continue`).

That satisfies both asks: **call sheets forward**, and **no silent skip** when
resolution fails.

### 7. Verification
- `make build` (all targets) — then a standalone smoke test of the exact
 MIME parser against the **real McD's FESTIVE message (1.8 MB source)**: a tiny
/var/tmp Swift driver that fetches `source of m` via the same script and runs
`MIMEParser` printing name/size per part. Expect the call-sheet PDF name + size.
- Manual end-to-end after install: email `Luisa` a call sheet, watch the
Activity log for `Resolved … attachment(s) from MIME source` → `Classified:
Call Sheets` → `Forwarded … to <Silo address>` (Silo inbound must be configured
in Settings → Silo keychain) / `Forwarded … + N attachment(s) to …@app.hubdoc.com`.
- Confirm the daemon binary actually running contains the new strings
(`strings …/Postmark | grep -c "from MIME source"`).

## Open items / risks
- Silo inbound address lives in the Keychain (`KeychainService.siloInboundLabel)
  — if unset, `SiloForwarder.forward` refuses (address empty); user must configure
  once in Settings → Silo. Not part of this change.
- File size cost: fetching full source per unprocessed message per run is fine at
  current volumes; a future `Content-Length`-prefilter could skip huge sources.
- MIME edge cases: folded header parameters, weird boundary/encodings, fingernail
  — the parser is deliberately conservative (filename-less ⇒ not an attachment);
  if a part still fails, the forward guard (zero saved → skip) prevents an empty
  send, and the retry-without-cooldown path means nothing is dropped silently.