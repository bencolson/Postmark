<p align="center">
  <img src="Postmark/Resources/Assets.xcassets/AppIcon.appiconset/app-icon-512x512@1x.png" width="128" height="128" alt="Postmark logo">
</p>

<h1 align="center">Postmark</h1>

<p align="center">
  A native macOS menu-bar app that triages your Apple Mail inbox with an LLM and
  forwards production call sheets straight into Silo. Postmark replaces the n8n
  Email Triage pipeline with a quiet background daemon that reads unread Mail,
  classifies each message, applies per-category routing, and runs a parallel
  attachment pass that forwards call sheets to your Silo inbound address.
</p>

<p align="center">
  <a href="#installation">Installation</a> &middot;
  <a href="#configuration">Configuration</a> &middot;
  <a href="#usage">Usage</a> &middot;
  <a href="#building-from-source">Build from Source</a> &middot;
  <a href="#cutover--shadow-mode">Cutover</a>
</p>

---

## How it works

```
MailPoller (15 min) → RuleEngine (Message-ID cooldown)
                        ├─ MessageClassifier  → category  → CategoryExecutor   (move / mark read / draft reply)
                        └─ AttachmentClassifier → doc type → SiloForwarder      (Mail forward → <Silo inbound addr>)
```

- **Background daemon**: silent 15-minute auto-triage from the menu bar. No per-message approval; a per-run digest notification summarises what happened.
- **Two classifiers**, mirroring the old n8n pipeline: a *message* classifier (→ `lead`/`receipt`/`low-priority`/`other`) and an *attachment* classifier (→ `Call Sheets`/`Movement Orders`/`Risk Assessments`/`Storyboards`/`Treatments`/`Specs`/`Other`/`skip`). The attachment pass runs on every message that has attachments, regardless of category — that parallel structure is what makes a shadow-mode diff against n8n meaningful.
- **Dev/prod env split**: forwarding targets the **dev** Silo inbound address in debug builds and the **prod** address only in release builds, gated by a runtime check that refuses to send to a placeholder address.
- **No secrets in the bundle**: provider keys live in Keychain; the Silo inbound address and rule prompts live in `~/Library/Application Support/Postmark/PostmarkRules.json` (user copy), seeded from a committed `PostmarkRules.json.template`.

## Configuration

Rules live in `~/Library/Application Support/Postmark/PostmarkRules.json`, created on first launch from the committed `Postmark/Resources/PostmarkRules.json.template`. Edit it directly or via **Settings → Rules**.

The shipped template contains the exact classification prompts ported verbatim from the n8n Email Triage workflow, so a Postmark classification is driven by byte-identical instructions to the pipeline it replaces.

## Usage

- Click the menu-bar icon → **Triage Now** runs a poll immediately.
- **Enable Triage** toggles the 15-minute background schedule (off by default until shadow mode passes).
- **Quiet Hours** suppresses the digest notification.
- The status icon walks `envelope` → `envelope.badge` → `hourglass` → `envelope.badge.fill` (digest ready) / `exclamationmark.triangle.fill` (errors).

## Installation

**Requirements:** macOS 14 (Sonoma) or later. Grant **Automation** permission for Mail when prompted. Postmark reads Mail via AppleScript only, so no Accessibility permission is required for inbox enumeration.

Grab the latest `.dmg` from the [releases](https://github.com/bencolson/Postmark/releases).

## Building from Source

```bash
git clone https://github.com/bencolson/Postmark.git
cd Postmark
make build
make run
```

### Available Make Targets

| Command | Description |
|---------|-------------|
| `make build` | Debug build (renders icon + compiles) |
| `make run` | Build and launch the app |
| `make release` | Optimized universal (arm64 + x86_64) build |
| `make sign` | Code sign (ad-hoc or with `SIGNING_IDENTITY`) |
| `make dmg` | Create a `.dmg` installer |
| `make render-icon` | Regenerate app-icon slices from SF Symbol |
| `make appcast` | Generate the Sparkle `appcast.xml` from GitHub releases |
| `make clean` | Remove build artifacts |

### Developing in Xcode

Open `Postmark.xcodeproj` and hit Run — the shared `Postmark` scheme builds and launches the app bundle directly (requires Xcode 16+). The project uses a synchronized folder group, so new Swift files under `Postmark/` are picked up automatically.

## Cutover & Shadow Mode

Before Postmark replaces n8n, run **shadow mode**:

1. Postmark rules are pinned to match n8n's categories exactly.
2. In shadow mode Postmark classifies only — no Mail actions, no Silo forwards. It logs outcomes.
3. Diff Postmark's per-message category against n8n's last clean run (G1 gate: ≤2 divergences over 48h / >200 messages).
4. Once parity holds + 1 week clean, disable the n8n Email Triage workflow, stop `com.bencolson.email-triage-poll`, then flip Postmark's **Enable Triage** toggle to act for real.
5. After the mac-data-api `/mail/inbox` family is confirmed unused, delete it.

See the plan file `docs/postmark-plan.md` for the full architecture, rule schema, and validation gates G1–G5.

## Privacy

- Provider API keys are stored in macOS Keychain — never written to disk as plaintext.
- Email content is sent only to your chosen LLM provider and (for forwardable attachments) to your siloed Silo inbound address — never anywhere else.
- No analytics, no telemetry, no data collection.

## License

[MIT](LICENSE)
