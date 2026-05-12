# Plan: Transforms — Phase 3 (Per-App Prompt Variants)

> Status: **ACTIVE** — implementation plan for ADR-023.
> Author: agent (Claude) + Daniel
> Date: 2026-05-12
> Related:
> - Locks-on-merge ADR: `spec/adr/023-transforms-per-app-variants.md`
> - Phase 2 (foundation this stacks on): `plans/active/2026-05-transforms-phase-2-productize.md`, PR #282 (`feat/transforms-premium`)
> - Parent ADR: `spec/adr/022-transforms-system-wide-rewrite.md`

---

## TL;DR

Phase 2 (PR #282) shipped Transforms as a single-body primitive — `⌥1` runs the same *Polish* prompt regardless of host app. **Phase 3 makes the Transform contract app-aware** by letting users pin a different prompt body for specific apps. *Polish* in Twitter writes Twitter; *Polish* in Mail.app writes Mail; *Polish* without an override falls back to the default body. Resolution is a one-line dictionary lookup at trigger time; the LLM does no judgement work, and the user can see exactly which body will run before they press the key.

Locks per ADR-023:

- **Schema**: one new nullable `appVariants` JSON column on `prompts` (v0.14 migration).
- **Resolution**: `appVariants[bundleID] ?? content`. No glob, no inheritance, no OS-version axis.
- **Capture-side**: `SelectionCaptureService` reads `NSWorkspace.frontmostApplication.bundleIdentifier`; ships in a new `CaptureContext` value on `SelectionCaptureResult`.
- **Editor**: collapsible *Per-app overrides* section in `TransformEditorSheet`, with an NSWorkspace-driven running-apps picker + manual bundle-ID disclosure.
- **Seeded examples**: one pedagogical variant per built-in (Polish→Twitter, Distill→Slack, Decide→Mail.app). Reconciler never overwrites user edits or re-adds deleted seeds.
- **Telemetry**: `transform_executed` gains one property — `app_variant_used: bool`. No bundle IDs transmitted.
- **Feature flag**: ships under the existing `AppFeatures.transformsEnabled`. No second flag.

---

## Where Phase 2 got us

Foundation merged in PR #282:

| Layer | Status | Path |
|---|---|---|
| `Prompt.category == .transform` rows + reconciler | Built | `Sources/MacParakeetCore/Models/Prompt.swift`, `DatabaseManager.swift` |
| `KeyboardShortcut` model + JSON column | Built | `Sources/MacParakeetCore/Models/KeyboardShortcut.swift` |
| `TransformsHotkeyRegistry` (single tap, N transforms) | Built | `Sources/MacParakeet/Hotkey/TransformsHotkeyRegistry.swift` |
| `TransformsCoordinator` (cancel-then-restart, run-ID guarding) | Built | `Sources/MacParakeet/App/TransformsCoordinator.swift` |
| `TransformExecutor` (capture → LLM → replace) | Built (from spike) | `Sources/MacParakeetCore/Services/Transforms/TransformExecutor.swift` |
| `SelectionCaptureService` (AX + clipboard fallback) | Built (from spike) | `Sources/MacParakeetCore/Services/System/SelectionCaptureService.swift` |
| `PromptTemplateRenderer` ({{userNotes}}, {{transcript}}) | Built (ADR-020) | `Sources/MacParakeetCore/Models/PromptTemplateRenderer.swift` |
| Premium UI (tab + editor sheet) | Built | `Sources/MacParakeet/Views/Transforms/` |
| CLI surface (`transforms list/show/run/create/delete`) | Built | `Sources/CLI/Commands/TransformsCommand.swift` |
| Telemetry (`transform_executed`, `transform_failed`) | Built | `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` |
| Three built-in Transforms (Polish/Distill/Decide) | Built | `Prompt.builtInTransformPrompts(now:)` |

**Phase 3 touches a narrow surface** of that foundation. Every component above stays — the changes are additive.

---

## What we're building (the product surface)

### Editor sheet: collapsible *Per-app overrides* section

A fourth EditorCard appears below *Customize prompt*:

```
┌─ Per-app overrides ─────────────────────────── [▾ 0 apps ]┐
└───────────────────────────────────────────────────────────┘
```

Collapsed by default. The chip count (`0 apps`, `1 app`, `3 apps`) reflects the current `appVariants` keys. Click expands:

```
┌─ Per-app overrides ─────────────────────────── [▴ 2 apps ]┐
│                                                           │
│  ┌────────────────────────────────────────────────────┐   │
│  │  [icon]  Twitter / X                       [trash] │   │
│  │          com.atebits.Tweetie2                      │   │
│  │  ┌──────────────────────────────────────────────┐  │   │
│  │  │ Rewrite for Twitter — 280 chars, casual,    │  │   │
│  │  │ no hashtags unless they're load-bearing...  │  │   │
│  │  └──────────────────────────────────────────────┘  │   │
│  └────────────────────────────────────────────────────┘   │
│                                                           │
│  ┌────────────────────────────────────────────────────┐   │
│  │  [icon]  Slack                            [trash] │   │
│  │          com.tinyspeck.slackmacgap                 │   │
│  │  ┌──────────────────────────────────────────────┐  │   │
│  │  │ Rewrite for Slack — casual, allow markdown,│  │   │
│  │  │ preserve @mentions + links exactly...      │  │   │
│  │  └──────────────────────────────────────────────┘  │   │
│  └────────────────────────────────────────────────────┘   │
│                                                           │
│  [ + Add app ]                                            │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Add-app picker

A small popover anchored to the `+ Add app` button. Two paths:

- **From running apps** (default): scrollable list of `NSWorkspace.shared.runningApplications` filtered to those with a non-empty `localizedName`, shown with the app's `NSImage` icon + display name. Click selects + closes the popover and creates a new empty variant card focused on its body editor.
- **Advanced: enter bundle ID**: a disclosure-triangle reveal under the running-apps list. Text field accepts a reverse-DNS bundle identifier; the editor doesn't validate against existing apps so users can target unimported apps (e.g., team distribution).

### Resolution at trigger time — no UI

The user never sees "which variant is about to run." The contract is: *you wrote it for this app, it runs in this app.* If they want a preview, they edit the Transform.

### CLI surface (additive)

The existing `transforms create / show / run` commands gain optional per-app behavior:

```
macparakeet-cli transforms create \
    --name Polish \
    --prompt "default body" \
    --shortcut "opt+1" \
    --app-variant "com.atebits.Tweetie2=tweet polish body" \
    --app-variant "com.tinyspeck.slackmacgap=slack polish body"
```

```
macparakeet-cli transforms show Polish [--for-app com.atebits.Tweetie2] [--json]
    # --for-app prints the resolved body for that bundle ID; without it, prints
    # the default body + the variants list.

macparakeet-cli transforms run Polish --input - --for-app com.atebits.Tweetie2
    # Forces the variant lookup to a specific bundle ID, bypassing GUI capture.
    # Useful for agent operators provisioning a fresh device, or for CI smoke.
```

`--app-variant key=body` is repeatable. The `=` separator is unambiguous because bundle IDs never contain `=`. JSON envelope additions are minor — the existing `TransformDTO` grows an optional `app_variants: [String: String]?` field.

---

## Architecture

### `Prompt` model extension

```swift
public struct Prompt: Codable, Identifiable, Sendable {
    // ... existing fields ...
    public var appVariants: [String: String]?

    /// Returns the prompt body to run given the host app's bundle ID.
    /// Variant lookup → fall back to `content`. Trim is applied at edit
    /// time so callers can trust the stored body verbatim.
    public func resolvedContent(forBundleID bundleID: String?) -> String {
        guard let bundleID, let variants = appVariants,
              let variant = variants[bundleID], !variant.isEmpty else {
            return content
        }
        return variant
    }
}
```

The `Prompt.Columns` enum gains `appVariants`. Codable round-trip stores the dictionary as a JSON-encoded string in the column (mirrors the v0.13 `keyboardShortcut` pattern — explicit string-of-JSON to avoid GRDB Codable strangeness with nested dictionary types).

### Schema migration — v0.14

```swift
migrator.registerMigration("v0.14-prompt-app-variants") { db in
    let existingColumns = try db.columns(in: "prompts").map(\.name)
    if !existingColumns.contains("appVariants") {
        try db.alter(table: "prompts") { t in
            t.add(column: "appVariants", .text)
        }
    }
}
```

Additive, idempotent, mirrors v0.13. No data migration; existing rows keep NULL `appVariants`.

### `SelectionCaptureService` extension

```swift
public struct CaptureContext: Sendable {
    public let bundleID: String?
    public let displayName: String?
}

extension SelectionCaptureResult {
    /// Always non-nil for `.ax` and `.clipboard`; nil for `.empty` /
    /// `.failed`. Defaults to current frontmost app at capture time.
    public var context: CaptureContext? { ... }
}
```

The capture path takes a snapshot of `NSWorkspace.shared.frontmostApplication` at the moment the AX read happens. Result enum cases extend to carry the context. Existing call sites stay backward-compatible because `context` is an optional property accessor.

### `TransformsCoordinator` resolution

One change in `handleTrigger(promptID:)`:

```swift
let captured = await captureService.captureSelection()
// ... existing empty/failed handling ...
let promptBody = prompt.resolvedContent(
    forBundleID: captured.context?.bundleID
)
// ... pass `promptBody` to executor as before ...
```

Telemetry: `transform_executed` now carries `app_variant_used: Bool` derived from whether `resolvedContent` returned a variant.

### `PromptTemplateRenderer` extension — optional

Two new template variables, available inside any prompt body (default or variant):

- `{{currentApp}}` → `captureContext.displayName ?? ""`
- `{{currentAppBundle}}` → `captureContext.bundleID ?? ""`

Coordinator renders the body via `PromptTemplateRenderer.render(_:substitutions:)` after `resolvedContent(forBundleID:)`. Power users who write a default body referencing `{{currentApp}}` get adaptive behavior without authoring per-app variants; users who pin variants get the variant verbatim (still template-rendered, but with the same substitution map).

### Default-variant reconciler

The Phase-2 reconciler (`DatabaseManager.reconcileBuiltInPrompts`) updates only `name / content / category / isBuiltIn / sortOrder / updatedAt`. **It must NOT overwrite `appVariants`** — same contract as `keyboardShortcut` and `runningLabel`. Verification: a dedicated regression test mirrors `testReconcilerPreservesUserCustomizedShortcutOnBuiltInTransform` for `appVariants`.

When a built-in prompt row is *missing* (user deleted it, app reopens), the reconciler re-seeds with the canonical body + the canonical `appVariants` map. This is the only path that writes the pedagogical seed.

---

## Implementation phases

Single sprint, single branch (`feat/transforms-per-app-variants`), multiple logical commits.

### Phase 3A — Data layer (~2 hr)

1. Migration `v0.14-prompt-app-variants` in `DatabaseManager`.
2. `Prompt.appVariants: [String: String]?` field + `Codable` round-trip.
3. `Prompt.resolvedContent(forBundleID:)` accessor.
4. `Prompt.Columns.appVariants` entry.
5. Update `Prompt.builtInTransformPrompts(now:)` to seed one variant per built-in (Polish→Twitter, Distill→Slack, Decide→Mail.app).
6. Reconciler: confirm it does NOT touch `appVariants` on UPDATE; add inline comment.
7. Tests: Codable round-trip, resolvedContent precedence, fresh-DB seed verification, reconciler preserves user-customized appVariants.

### Phase 3B — Capture-side context (~1 hr)

1. New `CaptureContext` struct in `MacParakeetCore`.
2. Extend `SelectionCaptureResult` cases to carry it (or expose via a derived accessor — pick whichever causes fewer call-site touchpoints).
3. Read `NSWorkspace.shared.frontmostApplication.bundleIdentifier` + `localizedName` at capture time. Falls back to nil on the rare race where frontmost isn't available.
4. Tests: capture returns context on a synthetic AX-mocked path; capture returns nil context when no frontmost app.

### Phase 3C — Coordinator wiring (~1 hr)

1. `TransformsCoordinator.handleTrigger`: call `prompt.resolvedContent(forBundleID: captured.context?.bundleID)`.
2. Track `appVariantUsed` boolean for telemetry.
3. Render via `PromptTemplateRenderer` after resolution (adds `{{currentApp}}` / `{{currentAppBundle}}` substitutions).
4. Tests: coordinator end-to-end mocks an AX capture with bundle ID, verifies the executor receives the variant body when one exists, the default body when none exists.

### Phase 3D — Editor sheet UX (~3 hr)

1. `TransformEditorViewModel`: extend draft state with `variants: [String: String]` + add/remove/edit helpers.
2. `TransformEditorSheet`: new collapsible `EditorCard` ("Per-app overrides") with the chip-count header.
3. `AppPickerPopover` (new view): NSWorkspace running-apps list with icons + display names + bundle IDs in monospace; disclosure for manual bundle-ID entry.
4. `AppVariantCard` (new view): app icon + display name + bundle ID monospace label + TextEditor body + Delete button. Matches the visual cadence of the default-prompt card.
5. Save path: `buildSavable()` merges `variants` into the persisted `appVariants` (nil when empty so the column stays compact).
6. Validation: each variant body required non-empty when its row exists. No length cap.
7. Tests: ViewModel-level add/remove/empty-trim/save round-trip.

### Phase 3E — CLI + telemetry + spec/docs + tests (~2 hr)

1. CLI: `--app-variant key=body` flag on `transforms create`, `--for-app` flag on `transforms show` / `transforms run`. Add to `CHANGELOG.md` (semver 2.2.0 → 2.3.0).
2. `TransformDTO.app_variants: [String: String]?` for JSON envelopes.
3. `transform_executed` event: new `app_variant_used` property in `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` + the allowlist dict at the bottom of the file. **Two-repo coordination** with `macparakeet-website/functions/api/telemetry.ts`.
4. ADR-023 status: PROPOSAL → IMPLEMENTED.
5. CLAUDE.md ADR table gets the new entry.
6. Spec updates: `kernel/requirements.yaml`, `kernel/traceability.md`.
7. Full `swift test` green before commit.

### Phase 3F — Rollout (post-merge, owner-driven)

1. Deploy the website Worker `ALLOWED_EVENTS` update for the new `app_variant_used` property key.
2. No additional flag flip — Phase 3 ships under the same `AppFeatures.transformsEnabled` toggle as Phase 2.

---

## Test matrix

| Layer | Tests |
|---|---|
| Migration v0.14 | Adding `appVariants` is idempotent. Existing rows unaffected. NULL on fresh `.result` rows. |
| `Prompt.resolvedContent` | Returns variant when bundle ID matches. Returns default when no match. Returns default when bundle ID is nil. Returns default when variants dict is nil. Returns default when variant body is empty string. |
| `Prompt` Codable round-trip | Variants JSON encode/decode loss-free. NULL column persists as `nil` not `[:]`. |
| `Prompt.builtInTransformPrompts` | Three built-ins each carry exactly one pedagogical variant on the documented bundle IDs. |
| Reconciler | User-customized `appVariants` survive a fresh `DatabaseManager(path:)` open. Deleted built-in rows re-seed with canonical variants on next launch. |
| `SelectionCaptureService` | Captures bundle ID + display name when frontmost is set. Nil context tolerated. |
| `TransformsCoordinator` | End-to-end: a Transform with a Twitter variant + a captured Twitter bundle ID runs the variant body. With no variant and a Twitter bundle ID, runs the default body. With a variant and no bundle ID context, runs the default body. |
| `TransformEditorViewModel` | Add/remove/edit variants. Empty variant body fails validation. Variant dict normalizes to nil when empty. |
| CLI | `create --app-variant key=body` persists correctly. `show --for-app X` prints resolved body. `run --for-app X` invokes the variant. JSON envelope includes `app_variants`. |
| Telemetry | `transform_executed` carries `app_variant_used` boolean. Allowlist accepts the new property. NO bundle ID in the transmitted payload. |

All deterministic; no network; no real LLM.

---

## Open questions for the owner

1. **Default-seed bundle IDs.** Twitter/X's bundle ID has shifted across rebrands (`com.atebits.Tweetie2` → `com.X.X.x86` etc.). Pin to today's known bundle? Ship two seeds for Polish (one Twitter, one Slack)? **Lean: pin to current canonical bundle + add a comment in `Prompt.swift` noting the brittleness; users can override.**
2. **Empty variant on save.** If the user adds a Twitter variant card but leaves the body empty, do we save it (preserves intent) or silently drop it (avoids dead variants)? **Lean: refuse save with an inline error — preserves the "every saved variant runs" contract.**
3. **Browser detection upgrade path.** Worth opening a Phase 4 placeholder ADR for site-aware browser context (AX-walking the web view) now, or wait for user demand? **Lean: wait. Phase 4 ADR if/when telemetry shows browser bundles dominate variant lookups.**

---

## Out of scope

- Site-aware variants inside a browser (Phase 4 candidate).
- Per-window or per-document variants. Variants are per-bundle-ID. Cursor-on-Repo-A vs Cursor-on-Repo-B is the same variant.
- Variant *inheritance* (e.g., "use the Mail.app variant for any `com.apple.*` mail client"). One bundle ID, one variant body, no globs.
- Per-Transform LLM model override (this remains a Phase 4+ candidate as in ADR-022).
- Diff viewer, rule-toggle composition, writing samples (all Phase 4+).

---

## Rollout gates

1. **Merge gate**: `swift test` green, dev-build smoke pass (open Transforms tab → expand Per-app overrides → add a Twitter variant → trigger Polish in Twitter, verify variant body ran by checking pill label + result text), ADR-023 finalized, spec/kernel updated, plan archived to `plans/completed/`.
2. **Pre-ship gate (telemetry)**: `macparakeet-website` Worker `ALLOWED_EVENTS` accepts the new `app_variant_used` property key on `transform_executed`. Confirmed via curl.
3. **Ship**: rides on the existing `AppFeatures.transformsEnabled` toggle. If Phase 2 has shipped (flag is true), Phase 3 is live on first launch after the install.

---

## Stacks on PR #282

This branch (`feat/transforms-per-app-variants`) was created from `feat/transforms-premium` (the Phase 2 branch). When #282 merges to `main`, this branch rebases cleanly. The plan above intentionally references files that exist only on the Phase 2 branch — the Phase 3 PR should be opened only after #282 lands.
