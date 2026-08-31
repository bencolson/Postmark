# Postmark — Plan

## Goal
A native macOS menu-bar app (fork of `jpwahle/apple-mail-ai-plugin`'s Swift/SwiftUI/AppleScript scaffold) that **replaces the n8n Email Triage pipeline** and **extends Silo with auto call-sheet forwarding**. It reads Apple Mail's Inbox, classifies unread messages via a user-selectable LLM, applies per-category routing actions, and forwards call sheets + other production docs to **your per-user Silo inbound address** (the `<token>@mail.silo.day` credential — **never committed**, see §Secure rule file handling). The sort/classification logic is editable in a macOS GUI; the LLM provider is yours to choose.

This is a **repurpose**, not a drop-in fork: the base app is a *reply composer from a compose window*; Postmark is an *inbox triage + forward engine*. The shared scaffold is the menu-bar lifecycle, the LLM provider picker/clients, Keychain key storage, and the Xcode/Sparkle build+distribution model. The compose-window reading path (`MailBridge.fetchComposerContext`) is discarded.

## Status: one decision resolved
| # | Decision | Chosen | Status |
|---|----------|--------|--------|
| 1 | Silent daemon vs. interactive review queue | **Background daemon + menu-bar config/settings** (silent 15-min auto-triage, no per-message approval, but a per-run digest + "triage now" manual trigger). | **LOCKED** (user confirmed) |

All other decisions below are locked from your infra context. The execution model is the daemon path: no interactive review queue.

## Branding, icon & style direction (locked)
- **Motif**: SF Symbols `envelope.badge` family — the base repo already uses `envelope.badge.fill` for its status item, so this keeps the repurpose visually coherent. App name stays **Postmark**.
- **Menu-bar status icon state machine** (template symbol — tint via `statusItem.button?.contentTintColor`):

  | App state | Symbol | Tint |
  |---|---|---|
  | Triage disabled | `envelope` | none |
  | Armed, idle | `envelope.badge` | none |
  | Polling / busy | `hourglass` | none |
  | Digest waiting (new triage results) | `envelope.badge.fill` | accentColor |
  | Last run had action failures / LLM errors | `exclamationmark.triangle.fill` | red |

- **App icon**: `envelope.badge.fill` rendered on a rounded-rect material background in the accent gradient, matching the base's `VisualEffectBackground`/rounded-card look. Produced from a committed script (`scripts/render-icon.swift`) that renders SF Symbols via AppKit to the asset catalog slices (Xcode 16 `.icon` format; fallback documented to `AppIcon.appiconset` if `.icon` misbehaves). Commit the generated PNGs — no runtime icon synthesis.
- **Window/panel style**: reuse the base's `VisualEffectBackground` (`.underWindowBackground`, `.behindWindow`, `.active`) + rounded-rect cards + the accent-colored primary buttons, so Settings and the (optional) digest panel look like the same family as the original app.
- **Consistent action glyphs in the rule editor** (docs + UI): move → `tray`, mark read → `envelope.open`, leave → `envelope`, forward → `square.and.arrow.up`, draft reply → `square.and.pencil`, triage now → `arrow.clockwise` (or `bolt.fill`), quiet hours → `moon`, errors → `exclamationmark.triangle.fill`.
- **Marketing logos** (`laurel.svg`, `logo-dark/light.png` at repo root): delete or regenerate as a Postmark `envelope.badge` render — cosmetic, not gating.

## Locked design decisions (from infra context)
- **Mail source**: Apple Mail via AppleScript/JXA (same `MacDataAPI`-style approach), reading **unread** messages in **Inbox**, optionally limited to last N days. The mac-data-api `/mail/inbox` endpoint is *supperseded* by the native path but mac-data-api itself stays for calendar/mail endpoints still used elsewhere.
- **Dedup / cooldown**: message `Message-ID` persisted to a local store (Core Data or a single plist/JSON log) with a configurable TTL (default 24h) — replaces n8n's Redis cooldown. Re-triaging the same message within the TTL is skipped.
- **Classifiers**: one **message classifier** (→ category) and one **attachment classifier** (→ document type). Both via streaming LLM calls using the existing `AIClient` protocol; both editable as custom prompts.
- **Document categories (forward targets)**: `Call Sheets`, `Movement Orders`, `Risk Assessments`, `Storyboards`, `Treatments`, `Specs`, `Other`, `skip` (the n8n set). Forwardable ones are sent to Silo inbound email; `skip` and non-production types are left alone.
- **Silo inbound target**: configurable per environment. Prod = your per-user `<token>@mail.silo.day`; dev = `<token>@mail-dev.silocall.com`. The Silo server-side `InboundEmailWebhookController` already files by shoot date / links Job / runs Gemini extraction — Postmark owns only the client leg (detect → forward). No backend changes, but rely on its logs/metrics for feedback (forward failures surface as macOS notifications). **See §Secure rule file handling: the real address is never in the repo.**
- **Providers**: base six + a new **LiteLLM proxy** provider (OpenAI-compatible base URL = `http://localhost:4000/v1`, key from Keychain) so the existing Glimmer local + OpenRouter cloud-fallback chain works transparently. This is the provider most aligned with your infra.
- **Rule file**: single `PostmarkRules.json` in the app's support dir, human-readable, `git`-committable, hand-edit-safe. Schema is JSON Schema-validated on load. The GUI writes it atomically.
- **Packaging**: SwiftPM Build + an Xcode project for `⌘R`; release via `make dmg` + **Sparkle** for in-place auto-update; releases published to GitHub `bencolson/Postmark`. MIT license (inherits base repo).

## What is retired (when Postmark is live + verified)
- n8n **Email Triage** workflow (ID `IZ9oSf2fVJrv0xRc`).
- n8n's parallel **attachment classification branch** (the `mail/save-attachments` → Dropbox tree is already dead since 2026-08-13; the forward-to-Silo branch is absorbed).
- LaunchAgent `com.bencolson.email-triage-poll`.
- mac-data-api `/mail/inbox` + `/mail/messages` + `/mail/search` + `/mail/attachments` + `/mail/move` + `/mail/save-attachments` (these become dead code for triage; keep `/mail/draft`, `/mail/send`, `/mail/callsheet` if still used by Claw/InvoicePreview — **verify before deleting**).
- The Redis dedup for triage (`email-categorisation`, 24h TTL).

mac-data-api's **calendar** endpoints and **/mail/send**, **/mail/draft** are NOT retired unless you confirm they're unused (CLAUDE.md flags `/mail/callsheet` and `/mail/send-attachments` as unverified / dead — confirm before removal).

## Architecture (target)

```
┌─────────────────────────────────────────────────────────┐
│  Postmark.app  (menu-bar, LSUIElement, Sparkle update; │
│   status icon = SF Symbol `envelope.badge` family)     │
│                                                            │
│  MailPoller  ──15m──┐                                     │
│  (AppKit +         │   unread messages                  │
│   AppleScript/JXA)  │                                    │
│                      ▼                                    │
│  RuleEngine ──MessageID cooldown log──▶  skip if fresh   │
│   │  reads PostmarkRules.json                          │
│   ▼                                                    │
│  MessageClassifier ──LLM──▶ category ──▶               │
│     (attachment pass, for every msg with attachments)   │
│     AttachmentClassifier ──LLM──▶ doc type ──▶          │
│        SiloForwarder ──Mail forward──▶ <Silo inbound addr>│
│  CategoryExecutor ──per-rule action──▶                 │
│    move / mark-read / leave / [draft reply]            │
│                                                            │
│  SettingsWindow  ──provider keys (Keychain)──▶           │
│  NotificationsCenter  (errors / forwarded / skipped)      │
│  CooldownLog     (only ticks after an action was attempted)│
└─────────────────────────────────────────────────────────┘
```

Notes:
- All AppleScript runs on a background `DispatchQueue` (as in `MailBridge`).
- Two classifiers, mirroring n8n: a **message classifier** (→ `lead`/`receipt`/`low-priority`/`other`) and an **attachment classifier** (→ `Call Sheets`/`Movement Orders`/.../`skip`). The attachment pass runs on *every* message that has attachments, independent of the message category — that parallel structure is required to match n8n in shadow mode.
- Both call the chosen `AIClient`; for a single-token category return, non-streaming `complete()` is sufficient, but reuse the streaming path so the digest can show in-flight classification.
- Actions are applied **via Mail.app AppleScript** (move mailbox, set unread, forward) so they're real Mail operations, exactly as n8n did through mac-data-api.
- **Cooldown only ticks when an action was *attempted*** (success or not). If the LLM/Mail step threw, the message stays in cooldown=false so the next run retries — otherwise a flaky provider would permanently strand a message in the TTL.

## Rule file schema (`PostmarkRules.json`)
```jsonc
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "version": 1,
  "polling": { "intervalMinutes": 15, "daysWindow": 7 },
  "provider": { "type": "litellm", "baseURL": "http://localhost:4000/v1", "model": "openrouter/laguna-s-2.1" },
  "classifier": {
    "prompt": "<single LLM prompt that classifies an email into one of the message rule ids below; return exactly the id token or empty>"
  },
  "rules": [
    { "id": "lead",    "label": "Leads",        "action": { "markRead": true, "draftReply": true, "draftPrompt": "..." } },
    { "id": "receipt", "label": "Receipts",     "action": { "move": "Receipts & Bookkeeping", "markRead": true } },
    { "id": "low-priority", "label": "Low Priority", "action": { "move": "Low Priority" } },
    { "id": "other",   "label": "Other",        "action": { "leave": true } }
  ],
  "fallback": { "action": { "leave": true } },
  "attachment": {
    "prompt": "<LLM prompt classifying ONE attachment (filename) into: Call Sheets|Movement Orders|Risk Assessments|Storyboards|Treatments|Specs|Other|skip>",
    "forward": {
      "to": "REPLACE_WITH_YOUR_Silo_INBOUND_ADDRESS",       // e.g. <token>@mail.silo.day — NEVER commit the real value
      "devTo": "REPLACE_WITH_YOUR_Silo_DEV_INBOUND_ADDRESS",
      "onlyTypes": ["Call Sheets","Movement Orders","Risk Assessments","Storyboards","Treatments","Specs"]
    }
  }
}
```
- `action` supports: `move` (mailbox name), `markRead` (bool), `leave` (bool), `draftReply` (bool, optional `draftPrompt`). `move`+`markRead` compose; `leave` means "no Mail change".
- `classifier.prompt` is the single message-categorization prompt (port of n8n's `email-categorisation` alias); the returned token must match a rule `id`, else `fallback.action` applies.
- `attachment.prompt` is a separate prompt (port of n8n's attachment-classification prompt); runs on every message with attachments → doc type. `forward.onlyTypes` are the only types actually sent to Silo; `Other`/`skip` are left attached to the message.
- `provider.type` ∈ {`anthropic`,`openai`,`gemini`,`openrouter`,`trustedtokens`,`local`,`litellm`}. `litellm` = OpenAI-compatible at `baseURL`, key pulled from Keychain under a user-named slot. `provider.model` is the routing string; for `litellm` it's a literal LiteLLM route (e.g. `openrouter/laguna-s-2.1`); for the first-class providers the model picker fetches the list.
- `to` is environment-parameterized: the app resolves `to` vs `devTo` from a build-time flag (`SILO_INBOUND_DEV=1` → dev address) so a dev build never fires at prod Silo.
- **G0 (precondition for shadow mode)**: the implementer must extract n8n's exact `email-categorisation` message-classifier prompt and the attachment-classification prompt from the Email Triage workflow JSON and drop them verbatim into `classifier.prompt` / `attachment.prompt` — otherwise G1/G5 (parity) is meaningless. Mark this as a setup todo in step 1.

## Implementation steps (ordered)

1. **Fork + bootstrap**: clone base repo into `/Users/bencolson/Developer/Postmark` (empty dir confirmed — do a clean `git init`, this isn't a git-repo yet). Rename bundle id to `ltd.colson.postmark`; set app name **Postmark**. Swap branding: delete the repo-root `laurel.svg`/`logo-dark.png`/`logo-light.png` and the `logo-dark`/`logo-light` README image; regenerate as an `envelope.badge` render via `scripts/render-icon.swift`. Keep MIT LICENSE. Update README to the Postmark goal (triage + call-sheet forwarding to Silo), icon/style, and the dev/prod env split for the inbound address.

2. **Strip compose path**: remove `ComposerPanelController/ComposerView/ComposerViewModel`, `SystemPrompt.compose/summarize`, `MailBridge.fetchComposerContext/insertReply` usages, the `⌥H` hotkey compose flow, and the `ComposerView` from `AppDelegate`. Keep `MailBridge.executeAppleScript`, `KeychainService`, `AIClient*`, `ModelFetcher`, `ModelCache`, `SettingsStore`, `UpdateChecker`.

3. **MailPoller** (`Services/Mail/MailPoller.swift`): list unread Inbox messages via AppleScript (`get source`/`Message-ID`/`sender`/`subject`/`date`/`recipients`), honoring `daysWindow`. Return `[MailMessage]` (new struct: id=Message-ID, sender, subject, date, body, attachments metadata). Run on the existing background queue pattern.

4. **RuleEngine** (`Services/Rules/RuleEngine.swift`): load+validate `PostmarkRules.json` (JSON Schema). Expose `evaluate(message:)` → `RuleMatch` (matched rule or fallback). Persist cooldown state (message ids → timestamps) via a small Core Data stack or a `codable` cache file under `~/Library/Application Support/Postmark/` (recommend: single-file JSON cache, simpler than Core Data for v1).

5. **MessageClassifier** (`Services/AI/MessageClassifier.swift`): port n8n's `email-categorisation` prompt into `classifier.prompt` (G0). For each message: call the chosen `AIClient` with `classifier.prompt` + sender/subject/body front-matter truncated to a token budget (body first, attachments listed but not read); parse `content` → exact match against rule `id`s, else `nil` → `fallback`. Non-streaming `complete()` is fine for a one-token answer.

6. **CategoryExecutor** (`Services/Mail/CategoryExecutor.swift`): apply the matched rule's `action` via AppleScript — move to mailbox (create if missing), mark read. If `draftReply`, open a compose window pre-filled with a generated reply from the LLM (`draftPrompt`); NOT sent automatically. **Ticks the cooldown log here only after an action was attempted** (success or error), so a provider/Mail failure retries on the next run.

7. **AttachmentClassifier + SiloForwarder** (`Services/Silo/AttachmentClassifier.swift`, `Services/Silo/SiloForwarder.swift`): a **parallel pass over every message that has attachments, regardless of its category** (mirrors n8n's independent attachment branch). `AttachmentClassifier` calls the LLM with `attachment.prompt` per file (filename + size; body content only as a hint) → `Call Sheets|Movement Orders|Risk Assessments|Storyboards|Treatments|Specs|Other|skip`, deliberately conservative (`skip` default — same gate-only semantics n8n uses). `SiloForwarder` then: saves eligible attachments via Mail.app AppleScript to a temp dir (`save in`), builds a Mail message to the resolved Silo address (`to` vs `devTo` per build flag), attaches the files, sends. Per-attachment failures are reported individually (digest/notification), not silently dropped.

8. **Settings window** (`Views/Settings/`): provider API keys (Keychain-backed, same `APIKeySettingsView`), a `RuleEditorView` (table of rules: edit prompt/action/forward target inline), a `ProviderView` row for LiteLLM proxy (base URL + name), and `PollingSettingsView` (interval + days window + start-at-login toggle via `SMAppService`). Reuse the base `SettingsStore`.

9. **Background run loop** (`AppDelegate` + new `TriageCoordinator`): on launch, register a 15-min repeating `Timer` (or `Task.sleep` loop) that calls `MailPoller → RuleEngine → MessageClassifier → CategoryExecutor → (SiloForwarder)`.
    - **Locked daemon model**: silent auto-triage on the interval, no per-message approval. Menu-bar icon follows the state machine in §*Branding* (`envelope`/`envelope.badge`/`hourglass`/`envelope.badge.fill`/red `exclamationmark.triangle.fill`). Menu items: **Triage Now** (`arrow.clockwise`), **Enable Triage** toggle (default OFF until shadow mode passes), **View digest** (shows last-run counts) when results exist, **Quiet Hours** (`moon`) schedule, **Settings…** (`slider.horizontal.3`). Per-run digest notification + error-only alerts via `UNUserNotificationCenter` (request once). Respect `polling.enabled`; when OFF, only `Triage Now` runs.

10. **Notifications**: use `UNUserNotificationCenter` (request once) for errors + a per-run digest ("triaged N, forwarded M, X skipped"). Forward failures surface here and are expected to correlate with Silo inbound webhook logs.

11. **Packaging**: SwiftPM `build` + Xcode project. Add `Makefile` targets `build`/`run`/`release`/`dmg`/`render-icon` (regenerates app-icon slices from the SF Symbol via `scripts/render-icon.swift`). Add a `Sparkle` integration (GitHub-releases appcast feed — public, OSS-friendly) and `make notarize` for Apple distribution. `make dmg` wraps the release build. `render-icon` is a no-op when slices are committed + current.

12. **Cutover plan** (only after Postmark verified end-to-end on a real Inbox; per the locked daemon model):
    a. **Shadow mode**: run Postmark alongside n8n with rules matching n8n exactly; Postmark classifies and logs only, no Mail actions. Diff outcomes against n8n's last clean run.
    b. Once parity + 1 week clean: disable n8n Email Triage + stop `email-triage-poll`; enable Postmark actions (flick the menu-bar "Enable triage" toggle — shadow mode is the gate).
    c. Delete the now-dead mac-data-api `/mail/inbox` family after confirming no other consumer (Claw/InvoicePreview) still calls them.

## Validation gates
- **G1**: Postmark classifies a held-out batch of 50 real unread messages **identically (same message category) to n8n's last clean run** — using n8n's ported `email-categorisation` prompt (G0). Replay log of last 3 days.
- **G2**: A call sheet forwarded by Postmark (against the **dev** Silo inbound address, never prod during testing) appears in Silo at the right `<shoot-date ymd>/` folder, Job-linked, Gemini-extracted, within Silo's normal SLA. Verify via Silo dev `InboundEmailWebhookController` log + the Dropbox tree. Gating the test forward at the dev address is itself a validation of the §runtime guard.
- **G3**: Cooldown log prevents re-triage within TTL; `Message-ID` dedup matches n8n's old Redis behavior within 1h granularity.
- **G4**: `make dmg` produces an unnotarized-valid app; `make run` launches menu-bar app; settings window saves a LiteLLM key+URL and one streaming classification completes against `localhost:4000`.
- **G5**: Rollout shadow-mode diff (Postmark vs n8n) over a 48h window shows ≤2 divergences on >200 messages.

## Secure rule-file handling (the Silo token)
- The repo ships **`PostmarkRules.json.template`** only (with `REPLACE_WITH_YOUR_*` placeholders). The real rule file lives at `~/Library/Application Support/Postmark/PostmarkRules.json` (user's home dir, git-ignored) — the app copies the template there on first launch if absent.
- **GitHygiene**: `.gitignore` includes `PostmarkRules.json` (only `.template` ships). Additionally, add a CI/lint check that the committed template contains `REPLACE_WITH_YOUR_` placeholders and that no rule file with a real-looking `token@mail.silo.day` is ever staged — belt and suspenders for a public repo.
- **Runtime guard**: before any forward, the app asserts `attachment.forward.to` is non-empty AND not equal to the placeholder literal; if it is, it refuses to forward, marks the run failed, and posts a notification ("Silo inbound address not configured — check Settings"). Never send to a placeholder by accident.
- The per-user token is entered in **Settings → Silo** (or auto-filled from the rules file), stored in **Keychain** under an `silo.inbound` slot — consistent with how the base app stores provider keys. Same Keychain discipline as n8n's mac-data-api approach: secrets at rest in Keychain, never in the bundle.

## Risks / edge cases
- **Prompt parity is the whole game**: the only reason Postmark can replace n8n* is that the LLM sees byte-identical instructions + equivalent inputs (same sender/subject/body + attachment list). Extract both prompts verbatim (G0) and keep `PostmarkRules.json`'s `classifier.prompt`/`attachment.prompt` editable from the GUI so drift from n8n is visible.
- **Apple Mail AppleScript fragility**: the base repo's `MailScripts.fetchComposerContext` already has the "outgoing messages empty on recent macOS → AX fallback" problem. Inbox enumeration via `every message of inbox` is generally stable but can return large sets; paginate by `date > (now - daysWindow)` and `read status = false`.
- **Double-fire vs n8n**: strictly gate actions behind shadow mode first; never enable Postmark actions while n8n triage is still active. TTL dedup is per-app (no shared Redis), so the two cannot share cooldown — retire n8n before enabling.
- **Attachment temp paths**: Mail.app saves attachments to a temp dir accessible via AppleScript `save` command; forwarder must `save in <tmp>` then attach. Test on Sonoma.
- **Silo inbound is async**: a forwarded call sheet that Silo rejects (bad Svix signature, wrong token) won't surface to the user synchronously; rely on the `mail.silo.day` Resend inbound log + a Postmark "last forward OK timestamp" in the menu. This risk is amplified because an un-configured/empty token must be caught by the §runtime guard *before* send, never after.
- **Dimension mismatch**: the base app fetches provider models (Anthropic/OpenAI/etc.); for the **LiteLLM** provider there's only one "model" (whatever LiteLLM routes), so `ModelFetcher` should skip model-list fetch for LiteLLM and just expose the configured model id. Flag in UI.
- **Open source exposure**: Sparkle appcast + GitHub releases are public. The repo commits only the templated rules + the icon/render script; the real Silo token, provider API keys, and any per-user prompt tuning live in the user's support-dir copy and Keychain — never the bundle. Documented dev/prod env split (build flag `SILO_INBOUND_DEV=1`).

## Out of scope
- Any change to Silo server code (`InboundEmailWebhookController`, Dropbox filing, Job linking, Gemini extraction) — those already work for call sheets.
- The mac-data-api calendar endpoints or `/mail/send`/`/mail/draft` unless confirmed unused.
- code-index integration (unrelated to this product).
- Anything touching auth/payments/tax/migrations/secrets beyond Keychain (you handle secrets via sops; Postmark keys are user-owned API keys in Keychain, never committed).

## Open question (blocks implementation)
None outstanding. Execution model is locked (background daemon + menu-bar config/settings). Remaining confirm-before-coding details are marked inline in the plan (e.g. verify mac-data-api `/mail/send`/`/mail/draft`/`/mail/callsheet` consumers before deleting the retired family; shadow-mode diff criteria G5).
