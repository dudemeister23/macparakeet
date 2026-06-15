# Speaker Diarization Quality — Implementation Handoff

> Status: **ACTIVE HANDOFF** · Date: 2026-06-14
> Branch: `speaker-diarization-quality` ·
> Worktree: `/Users/dmoon/code/macparakeet-worktrees/speaker-diarization-quality`
> Base: rebased onto `origin/main` @ `e95cd9e68` on 2026-06-14
> Orchestration: Claude orchestrates + verifies; **Codex GPT-5.5 xhigh implements**.
> This doc is a working artifact — delete it before the PR merges.

## TL;DR for the next agent

We are improving speaker-diarization **quality** (not the FluidAudio engine — that
part is already good). The authoritative spec is the refreshed plan in this same
folder: `2026-05-speaker-diarization-quality.md` (read it first — it was
re-grounded against FluidAudio 0.15.2 on 2026-06-14). Work ships in dependency-
ordered slices. **Slices 1–2 are committed and verified. Slice 3 is NEXT and has
not started.** Continue from Slice 3.

The improvement thesis (from the review that kicked this off): the diarization
*engine* is SOTA-competitive, but value is left on the floor in three layers —
the word→speaker **merge/attribution** (62-line strict-overlap, drops words on
drift), **integration** (no speaker-count hints reach meetings; calendar attendee
count is captured then discarded; no eval harness), and **trust/UX** (shipped
default-off with hedged copy). FluidAudio 0.15.2 newly exposes per-segment
`qualityScore`, speaker embeddings, and streaming diarizers — which changes the
design (qualityScore is a real confidence gate) and opens two ADR-gated bets
(cross-meeting identity, live labels).

## Running mode — read this first

This doc supports two flows. Decide which you are:

**(A) You are a Codex agent implementing directly.** You ARE the implementer.
- **Ignore** the "⚠️ CRITICAL tooling gotcha" and "Orchestration recipe" sections
  below — those describe a *Claude* orchestrator driving you via `codex exec`; the
  `/tmp/...spec` paths and `-c mcp_servers` flags do not apply to you.
- Work one slice at a time, in order (3 → 4 → 5 → 6). For each slice: read the
  authoritative plan (`2026-05-speaker-diarization-quality.md`) + this doc's slice
  spec → implement → `swift build` → full `swift test` (must report **0 failures**)
  → **self-review your own diff**, especially any *existing* test expectation you
  changed (it must reflect correct behavior, not merely pass) → **commit it
  yourself** using the rich format in `docs/commit-guidelines.md` with the trailer
  below → next slice.
- **Slice 7 is ADR drafts only** — write the proposals at `PROPOSAL` status; do
  NOT implement cross-meeting identity or live labels; stop and surface for a user
  decision.
- When all code slices are done: re-run full `swift test`, update
  `spec/README.md` / `spec/02-features.md` if user-visible behavior changed, and
  **delete this handoff doc**.
- Commit trailer (mode A):
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

**(B) Claude is orchestrating Codex via `codex exec`.** Use the whole doc as
written, including the MCP gotcha and orchestration recipe; Codex leaves changes
uncommitted and Claude verifies + commits.

**Guardrails (both modes):** meetings diarize with default options until Slice 6;
keep the public CLI flag names `--speaker-count` / `--speaker-min` /
`--speaker-max`; `SpeakerMerger` stays intact (production routes through the new
assigner); the default-off doc-drift is already fixed by PR #532 — do not redo it.

## ⚠️ CRITICAL tooling gotcha — Codex MCP startup hang

Running `codex exec` here **hangs indefinitely at startup** (3+ hours, zero output,
zero files written) because the account's Codex config has **claude.ai MCP servers**
(Slack/Gmail/Google/Atlassian) that require interactive OAuth and block the MCP
init phase headlessly. Symptom in the log:
`ERROR rmcp::transport::worker: worker quit ... AuthRequired ... mcp.slack.com`
followed by silence.

**FIX (verified by smoke test):** add `-c mcp_servers="{}"` to every `codex exec`
invocation. With it, Codex proceeds past MCP init to the model turn and completes
normally. (The MCP error line may still print — it is now non-blocking.)

**Also:** do NOT fire-and-forget a long Codex run for hours. Monitor
`/tmp/codex-sliceN.log` for growth and `git -C <worktree> status --short` for files
appearing. If there's no log growth AND no file writes for ~5–10 min, it's hung:
`pkill -9 -f "codex exec --cd /Users/dmoon/code/macparakeet-worktrees/speaker-diarization-quality"`,
confirm the worktree is clean, and relaunch. Consider `model_reasoning_effort="high"`
instead of `xhigh`, and/or splitting a big slice into smaller Codex runs, if hangs recur.

## Orchestration recipe (how to run a slice)

1. Write a precise, self-contained spec to `/tmp/codex-sliceN-spec.md`. Anchor it
   on the plan's phase; spell out scope, what to DEFER, guardrails (what must not
   change), and the verify commands. Tell Codex: **do NOT commit; leave changes in
   the working tree; final message must list files changed, design decisions, every
   existing test expectation changed + why, and exact build/test results.**
2. Run Codex (foreground; the harness may auto-background a long run — that's fine):

   ```bash
   codex exec --cd /Users/dmoon/code/macparakeet-worktrees/speaker-diarization-quality \
     --dangerously-bypass-approvals-and-sandbox \
     -m gpt-5.5 -c model_reasoning_effort="xhigh" \
     -c mcp_servers="{}" \
     -o /tmp/codex-sliceN-last.md - < /tmp/codex-sliceN-spec.md \
     > /tmp/codex-sliceN.log 2>&1
   ```
   Codex output buffers to the log; the harness task-output file stays empty until
   the whole command exits. Watch `/tmp/codex-sliceN.log` (it does grow) + `git status`.
3. **VERIFY before committing — do not trust green tests alone.** Codex writes impl
   AND tests, so green only proves self-consistency. Read the diffs
   (`git -C <worktree> diff`), confirm the logic is correct by hand, confirm scope/
   guardrails (e.g. meeting path unchanged when it should be), and independently
   re-run the touched test areas (`swift test --filter ...`). For any changed
   existing test expectation, confirm the new value is *correct*, not just green.
4. Commit in the worktree with a rich message (see `docs/commit-guidelines.md`),
   trailer `Implemented by Codex (GPT-5.5, xhigh); reviewed + verified by Claude.`
   and `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

Memory pointer: this matches the user's "Codex-orchestrator mode" preference —
Claude orchestrates, Codex executes, **Claude verifies Codex's work/commits.**

## Worktree & branch state

- Worktree clean after rebase onto `origin/main` @ `e95cd9e68`.
- Build is warm (`.build` populated); incremental `swift build` is fast.
- Full suite at last green run: **3,809 XCTest tests, 0 failures** (after Slice 2).

## Commits landed (newest last)

| SHA | Slice | Summary |
|-----|-------|---------|
| `31cade072` | Plan refresh | Re-grounded the quality plan to FluidAudio 0.15.2: corrected "Verified Current State", added the 0.15.2 capability delta (qualityScore, embeddings, streaming), promoted the eval harness to step 0, folded qualityScore into Phase 2. |
| `b51b8ef12` | **Slice 1 — eval baseline** | `DiarizationMetrics` (DER via greedy 1:1 speaker mapping + coverage + speaker-count delta; JER deliberately deferred), `RTTMParser`, `diarization-eval <fixtures-dir>` dev CLI, gitignored `fixtures/private/`, CHANGELOG entry, unit tests w/ hand-computed values. Purely additive. **Verified:** DER math traced by hand (confusion case → 0.5, coverage → 0.3); 11 focused tests re-run green. |
| `f7cc4d917` | **Slice 2 — options protocol (Phase 0+1)** | `SpeakerID` helper; `DiarizationOptions`/`SpeakerCountHint` + Core validation; `DiarizationServiceProtocol` reshaped so `diarize(audioURL:options:)` is required (`diarize(audioURL:)` is a `.default` convenience); `DiarizationService` refactored to `baseConfig` + manager factory applying hints per call; CLI `--speaker-count/--speaker-min/--speaker-max` kept (public names) but re-routed through the single options path via a stored `diarizationOptions` closure on `TranscriptionService`; `MeetingTranscriptFinalizer` switched to `SpeakerID` (pure refactor). **Verified:** all 5 ID cases traced through `SpeakerID`; meeting `diarize` call confirmed unchanged (no hint — deferred to Slice 6); 177 touched-area tests re-run green. |

## Slice status

- ✅ Slice 1 — committed (`b51b8ef12`)
- ✅ Slice 2 — committed (`f7cc4d917`)
- ⏭️ **Slice 3 — NEXT, not started** (a prior run hung on the MCP bug and was killed; worktree clean). Full spec below.
- ⬜ Slice 4 — Fresh-run diarization report (plan Phase 3)
- ⬜ Slice 5 — Speaker label provenance + meeting adapter (plan Phase 4)
- ⬜ Slice 6 — Calendar attendee count → meeting speaker-count hint (Tier 2)
- ⬜ Slice 7 — ADR drafts: cross-meeting identity + live labels (proposal-only; needs user decision)

## Design decisions already locked (do NOT relitigate)

- **Doc-drift is already fixed upstream** by PR #532 (off-by-default reconciled
  across ADR-010 / 02-features / 06-stt-engine). Do not redo it. This worktree is
  off the post-#532 `origin/main`.
- **Keep the existing public CLI flag names** `--speaker-count` / `--speaker-min` /
  `--speaker-max` (shipped). The plan's proposed `--speakers/--min-speakers/...`
  names are obsolete — do not add them.
- **`SpeakerMerger` stays intact** as a compatibility shim (its tie rule differs
  from the new assigner); production routes through the new `SpeakerWordAssigner`.
- **Interim:** file/URL hints currently ride a stored `diarizationOptions` closure
  on `TranscriptionService` (mirrors `shouldDiarize`). Slice 4 should migrate this
  to the plan's explicit per-call `TranscriptionRunOptions`/`TranscriptionRunResult`
  and drop the stashed closure.
- **Meetings still diarize with default options** until Slice 6 wires the calendar
  hint. Keep it that way through Slices 3–5.
- **ADR-gated bets are proposal-only** (Slice 7): cross-meeting speaker identity
  (biometric voiceprints — needs opt-in privacy ADR) and live streaming labels.
  Do not implement them without explicit user sign-off.

---

## Slice 3 — NEXT — full spec (paste to `/tmp/codex-slice3-spec.md`)

Implements **Phase 2** of the plan (Conservative Word-to-Speaker Assignment) +
surfacing `qualityScore`. This is the core quality win: stop dropping words on
small ASR/diarizer timestamp drift, without introducing confident-but-wrong
assignments. Behavior-affecting — scrutinize changed test expectations.

Deliverables:
1. **Surface `qualityScore`**: add `qualityScore: Double` to `SpeakerSegment`
   (default e.g. 1.0 in the memberwise init so existing constructors compile);
   populate it in `DiarizationService.diarize` from FluidAudio
   `TimedSpeakerSegment.qualityScore` (Float→Double), keeping the existing
   chronological-sort + stable-ID mapping otherwise unchanged.
2. **`SpeakerWordAssigner`** (Core), exactly per the plan's Phase 2:
   `SpeakerWordAssignmentResult { words, summary }`;
   `WordSpeakerAssignmentSummary { totalWords, directOverlapWords,
   fallbackNearestWords, sourceOnlyWords, unassignedWords, fallbackToleranceMs,
   ambiguityMarginMs }`; `WordSpeakerAssignmentMethod { directOverlap,
   fallbackNearest, sourceOnly, unassigned }` (track method separately — never
   infer quality from `speakerId != nil`). Algorithm: direct max-overlap wins;
   else interval boundary-gap nearest-segment fallback ONLY IF best gap ≤
   fallbackTolerance AND unambiguous (runner-up speaker differs by > ambiguityMargin)
   AND it does not cross source boundaries AND the candidate segment `qualityScore`
   ≥ a conservative `minFallbackQualityScore` (gate the fallback path only, never
   direct overlap); else source-only (meeting) / unassigned (file). Direct-overlap
   ties between different speakers → ambiguous → source-only/unassigned (no
   array-order tie-break). Source-scoped API `assign(words:segments:sourceOnlySpeakerId:)`.
   Injectable defaults: fallbackToleranceMs 250, ambiguityMarginMs 150,
   minFallbackQualityScore 0.60. The 0.60 gate is provisional: FluidAudio
   normalizes segment quality to 0...1, and fallback should start moderately
   conservative until private fixtures justify a different threshold.
3. **Route production** through the assigner: file/URL → `sourceOnlySpeakerId: nil`;
   meeting system → `sourceOnlySpeakerId: AudioSource.system.rawValue` (mic words
   never passed to system assignment). Keep `SpeakerMerger` unchanged; just stop
   using it in production.
4. **Finalizer safety**: fix `MeetingTranscriptFinalizer.buildDiarizationSegments`
   so a leading source-only/unassigned word doesn't drop later segments (start from
   first word with a displayable speaker/source ID).
5. **Tests**: full Phase-2 matrix from the plan + a test that fallback is refused
   when candidate `qualityScore` < threshold. Update any existing expectation that
   changes ONLY to the correct value; keep assertions strong; list every change.

Verify: `swift build`; `swift test --filter Diarization`; `swift test --filter Meeting`;
`swift test --filter Transcribe`; then full `swift test` (0 failures). Mode A (Codex
direct): self-review the diff, then commit. Mode B (Claude orchestrating): leave
uncommitted for review.

**Verification focus for the orchestrator:** read every changed existing test
expectation and confirm it reflects correct conservative behavior (more words
assigned via bounded fallback; ambiguous ties now left unassigned) — not a
weakened assertion. Confirm the meeting source-only semantics and that mic words
are never assigned from system diarization.

---

## Slices 4–7 — specs (summaries; expand from the plan when you reach them)

**Slice 4 — Fresh-run diarization report (plan Phase 3).** Add
`DiarizationQualityReport` + structured `DiarizationQualityWarning` with explicit
denominators (per the plan's exact definitions); thread the
`WordSpeakerAssignmentSummary` from Slice 3 through the fresh-run path; add CLI
`transcribe ... --diarization-report <path>`. Content-free (no transcript text,
paths, URLs, or names). Fresh-run only — DEFER stored-meeting reports. Also do the
deferred Slice-2 cleanup: introduce `TranscriptionRunOptions`/`TranscriptionRunResult`
per-call path and drop the stored `diarizationOptions` closure.

**Slice 5 — Speaker label provenance + meeting adapter (plan Phase 4).** Extend
`SpeakerInfo` with optional `source` / `rawProviderSpeakerId` / `labelSource`
(`modelDefault` | `user`) — backward-compatible JSON. Model-created speakers get
`.modelDefault`; user rename sets `.user`. Add an explicit meeting
system-diarization adapter (`S1` → `system:S1`) that preserves the raw FluidAudio
ID (e.g. `speaker_0`). Backward-compat tests for existing rows.

**Slice 6 — Calendar attendee count → meeting hint (Tier 2; unique to MacParakeet).**
`CalendarEvent.attendeeCount` exists but is discarded —
`MeetingAutoStartCoordinator` currently passes only `event.title`. Important
correction: `CalendarEvent.participants` already excludes the current user, so
`attendeeCount` is the remote/system-side count. Do **not** subtract 1. Plumb an
optional calendar context through auto-start, store it on the meeting recording
metadata/output, and pass a **soft `maxSpeakers = attendeeCount`** hint into the
meeting diarization path via the Slice-2 options protocol. Suggested shape:
optional `MeetingRecordingCalendarContext(attendeeCount: Int?)` on
`MeetingRecordingMetadata` and `MeetingRecordingOutput`, and an auto-start
callback that passes title + context together. Per the plan's Non-Goals:
attendees ≠ active speakers — soft ceiling only, never exact.

**Slice 7 — ADR drafts (proposal-only, NO implementation).** Draft two ADRs at
`PROPOSAL` status: (a) cross-meeting speaker identity via persisted embeddings
(now feasible: `DiarizationResult.speakerDatabase` / `chunkEmbeddings` /
`initializeKnownSpeakers`) — biometric, so opt-in / local-only / deletable;
(b) live streaming speaker labels via `LSEENDDiarizer`. Surface to the user for a
decision; do not build.

## Reference — key files

- Plan (authoritative): `plans/active/2026-05-speaker-diarization-quality.md`
- Diarization: `Sources/MacParakeetCore/Services/Diarization/` —
  `DiarizationService.swift`, `SpeakerMerger.swift`, `DiarizationMetrics.swift` (S1),
  `RTTMParser.swift` (S1), `DiarizationOptions.swift` (S2)
- `Sources/MacParakeetCore/Models/SpeakerID.swift` (S2)
- Meeting merge: `Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift`
- Transcription pipeline: `Sources/MacParakeetCore/Services/TranscriptionService.swift`
  (file/URL diarize call + meeting `diarizeMeetingSystemIfNeeded`)
- CLI: `Sources/CLI/Commands/TranscribeCommand.swift`, `DiarizationEvalCommand.swift` (S1)
- FluidAudio 0.15.2 source (for the real API): `.build/checkouts/FluidAudio/` —
  `Sources/FluidAudio/Diarizer/` (`TimedSpeakerSegment.qualityScore`,
  `DiarizationResult.speakerDatabase`/`chunkEmbeddings`, `DiarizationDER.compute`).
- ADR-010: `spec/adr/010-speaker-diarization.md`
