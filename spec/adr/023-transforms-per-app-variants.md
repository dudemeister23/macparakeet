# ADR-023: Transforms — Per-App Prompt Variants

> Status: PROPOSAL
> Date: 2026-05-12
> Related: ADR-022 (Transforms — system-wide LLM rewrites on selected text), ADR-013 (Prompt Library + multi-summary), ADR-009 (custom hotkey support), ADR-012 (telemetry)

## Context

ADR-022 / Phase 2 shipped Transforms as a system-wide hotkey-driven primitive: select text anywhere on macOS, press ⌥1 / ⌥2 / ⌥3, the selection is rewritten in place through the user's configured LLM provider. Every Transform stores a single prompt body that runs verbatim regardless of host app.

That model is correct for the basic primitive but undersells what a Transform *is*. A "Polish" run inside Twitter is a different job from a "Polish" run inside Mail.app — Twitter polish privileges brevity, line-break rhythm, and 280-char ceilings; Mail polish privileges greeting/signoff conventions and professional register. A Slack polish wants markdown-aware behavior and `@mention` preservation. An Xcode-comment polish wants technical precision over rhetoric. Asking *one* prompt body to handle every host app is asking the LLM to make a judgement call on every run, and that judgement call varies — the kind of variance that erodes trust over weeks of daily use.

The Phase 2 plan + design doc both explicitly deferred per-app routing without a commitment. This ADR is the commitment.

The user pushback that prompted this ADR: a `{{currentApp}}` template-variable approach (Option A in the design discussion) was rejected because *predictable beats cheap*. Users want a contract — "I wrote this exactly for Twitter, that's exactly what runs in Twitter" — not a judgement call that the LLM may or may not honor.

## Decision

### 1. `appVariants` JSON column on `prompts`

A new nullable TEXT column on the existing `prompts` table:

```
appVariants  TEXT  (JSON-encoded `[BundleID: String]`, NULL by default)
```

Where `BundleID` is the macOS reverse-DNS bundle identifier of the host app (`com.tinyspeck.slackmacgap`, `com.atebits.Tweetie2`, `com.apple.Mail`, etc.) and `String` is the prompt-body override that runs when that app is frontmost. The struct is a simple Codable dictionary; encoding/decoding mirrors the v0.13 `keyboardShortcut` pattern. NULL means "no overrides" — the Transform uses its default `content` for every app, identical to Phase 2 behavior.

Migration is forward-only and additive (`v0.14-prompt-app-variants`); existing rows are unaffected and round-trip through Codable without loss.

### 2. Resolution rule: lookup → default

At trigger time, `Prompt.resolvedContent(forBundleID:)` returns:

1. `appVariants[bundleID]` if non-nil → use that variant verbatim.
2. Otherwise → return `content` (the default prompt body).

One precedence rule, one fallback, no inheritance hierarchy, no glob matching, no per-OS variants. The first version of any system that tries to be flexible loses on debuggability; we add complexity only when a concrete user need demands it.

### 3. Capture-side bundle ID

`SelectionCaptureService` extends to read the frontmost app's bundle identifier alongside the selected text:

```swift
public struct CaptureContext: Sendable {
    public let bundleID: String?         // e.g. "com.tinyspeck.slackmacgap"
    public let displayName: String?      // e.g. "Slack"
}

public enum SelectionCaptureResult {
    case ax(text: String, element: AXUIElement, context: CaptureContext)
    case clipboard(text: String, savedClipboard: NSPasteboardItemSnapshot?, context: CaptureContext)
    case empty
    case failed(SelectionCaptureError)
}
```

Bundle ID is read once via `NSWorkspace.shared.frontmostApplication.bundleIdentifier` at capture time. Display name is read from the same `NSRunningApplication` via `localizedName`. Both are best-effort — the resolver falls back to the default `content` when context is nil.

No new entitlement is required; we already hold Accessibility permission for AX-capture, and `NSWorkspace.frontmostApplication` is unrestricted.

### 4. `TransformsCoordinator` resolution at trigger time

The coordinator's `handleTrigger(promptID:)` calls `prompt.resolvedContent(forBundleID: captured.context.bundleID)` after capture but before `TransformExecutor.run(prompt:)`. The executor signature stays unchanged — it always receives a resolved string.

```swift
let captured = await captureService.captureSelection()
let resolvedBody = prompt.resolvedContent(forBundleID: captured.context?.bundleID)
try await executor.run(prompt: resolvedBody, onProgress: ...)
```

### 5. Editor sheet: collapsible per-app overrides

`TransformEditorSheet` grows a fourth EditorCard below `Customize prompt`:

```
─── Per-app overrides ─────────────────────────── [▾ 0 apps ]
```

Default-collapsed when the Transform has no variants. Click expands to reveal the existing variants and an `[+ Add app]` affordance. The Add-app picker uses `NSWorkspace.shared.runningApplications` filtered to apps with a non-empty `localizedName`, shown with their `icon` (NSImage), sorted by display name. Manual bundle-ID entry is offered as a small disclosure (`Advanced: enter bundle ID`) for power users targeting apps that aren't currently running.

Each variant card shows: app icon + display name + bundle ID in monospace below, the variant's prompt body in a TextEditor identical in shape to the default-prompt card, plus per-card Delete. The variant body uses the same `parakeetAction` button roles and DesignSystem token chrome as the rest of the editor.

### 6. Default-variant seeding — one pedagogical example per built-in

The built-in Polish, Distill, and Decide Transforms each ship with **one** seeded `appVariant` so the affordance is visible the first time the user opens the editor for any built-in. Seeded entries (subject to refinement during Phase 3D):

- **Polish** seeds a Twitter/X variant (`com.atebits.Tweetie2`).
- **Distill** seeds a Slack variant (`com.tinyspeck.slackmacgap`).
- **Decide** seeds a Mail.app variant (`com.apple.mail`).

Rationale: zero defaults makes the feature invisible; four-per-built-in commits us to maintaining 12 hand-tuned bodies forever; one-per-built-in teaches the pattern and lets users learn-by-example without long-term curation debt. Users can delete or replace the seed without consequence. The reconciler does **not** re-add a deleted seed (same contract as the Phase-2 built-in body itself — user edits survive).

### 7. Browser limitation, named honestly

When the focused app is a browser (Safari, Chrome, Arc, Firefox, etc.), the bundle ID identifies the browser, not the site. `com.google.Chrome` is what we see whether the user is in Twitter, Gmail, or a Notion doc inside Chrome. Three honest stances:

1. **Variant on browser bundle ID** = "polish for general web text" — fine fallback.
2. **Variant prompt bodies can include `{{currentApp}}` and `{{currentAppBundle}}` template variables** rendered by `PromptTemplateRenderer` (the same plumbing ADR-020 already uses for `{{userNotes}}`). A power user who wants "if Chrome, infer site from the selected text" can write that into their variant body.
3. Site-aware browser context (AX-walking the web view to read its URL) is **out of scope** for Phase 3. Tracked as a future ADR if/when the data tells us browser variants are common.

### 8. Telemetry — `app_variant_used` flag, no bundle ID transmitted

The existing `transform_executed` event (ADR-022 §8) gains one new property:

```
app_variant_used : "true" | "false"
```

True when `resolvedContent(forBundleID:)` returned a variant; false when it returned the default. **No bundle ID is transmitted in telemetry** — observing "X% of Polish runs used a variant" is enough to answer the product question; transmitting which apps would leak environment fingerprinting.

The bundle ID DOES go to the user's configured LLM provider (via the rendered variant body, and optionally via `{{currentApp}}` template substitution). This is a strictly smaller leak than the already-transmitted selected-text payload and is acceptable on the same opt-in basis as the rest of the LLM call.

Allowlist update: `transform_executed` property keys grow by one (`app_variant_used`) in `macparakeet-website/functions/api/telemetry.ts`. Per `memory/feedback_telemetry_allowlist.md`, this is a coordinated two-repo change.

## Consequences

### Positive

- Predictability: the Transform that runs in a given app is the exact body the user authored for that app. No LLM judgement call between intent and output.
- Editor surface is small and collapsible; users who don't care never see it.
- Schema cost is one nullable column; the resolution rule is a one-line dictionary lookup.
- The architecture subsumes the rejected `{{currentApp}}` template-variable approach — power users who want adaptive behavior *within* a variant scope can use template substitution inside any variant body. We get both worlds without paying for both.
- Zero registry change: the 1:1 hotkey → Transform.ID dispatch from ADR-022 stays clean. Resolution happens *after* dispatch.

### Negative / accepted trade-offs

- More user surface area in the editor sheet. Mitigated by collapsible default-zero state.
- One additional dependency: the capture service now reads the frontmost app. Acceptable — `NSWorkspace.frontmostApplication` is cheap and stable.
- Browser-as-bundle-ID is a real limitation. Acknowledged in §7; revisited in a future ADR.
- Built-in seed bodies need light maintenance as host apps change their conventions (e.g., Twitter rebrand → X). Acceptable churn for the discoverability win; the reconciler never overwrites user edits.

## Alternatives considered

### Alternative A — `{{currentApp}}` template variable, no schema change

One Polish prompt body, with the host app name interpolated as context for the LLM to adapt against. Zero schema change, half-day implementation.

Rejected: probabilistic, not deterministic. The LLM does the adaptation on every call; sometimes nails it, sometimes drifts. The variance is exactly the *"AI being flaky"* failure mode that erodes trust over weeks of daily use. **Subsumed by this ADR** — Option A's template variables remain available *inside* any variant body for power users; the contract layer is what changes.

### Alternative C — Multiple Transforms sharing one hotkey, app-scoped

Polish-Twitter and Polish-Slack as separate `Prompt` rows, both bound to ⌥1; registry picks the best match at trigger time via an `appliesTo: [BundleID]?` field on each row.

Rejected: same key doing different things is the variance-kills-trust failure mode. The user can't see which Polish is about to run before they press ⌥1. Multiple matches require conflict resolution that's hard to teach. And it forks the data model — Transforms now have an identity layer on top of just-a-prompt.

### Alternative D — Per-OS variants (macOS version) in addition to per-app

A natural extension: variants keyed on `BundleID × OSMajorVersion` or even `BundleID × locale`. Rejected for v1: zero user demand surfaced; adds a multi-axis lookup with no proven benefit.

## Implementation pointer

Phase 3 plan: `plans/active/2026-05-transforms-phase-3-per-app-variants.md`. The implementation graduates this ADR from PROPOSAL → IMPLEMENTED. Stacks on PR #282 (Phase 2); should land after #282 merges to `main`.
