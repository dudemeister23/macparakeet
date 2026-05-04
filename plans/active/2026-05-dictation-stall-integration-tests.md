# Dictation stall — integration tests against the real audio platform

> Status: **ACTIVE — Tier 1 shipped, Tier 2 deferred**
> Created: 2026-05-03
> Branch: `plan/dictation-stall-tests`
> Related: `journal/2026-05-03-dictation-silent-stall.md`, ADR-015, PR #189 (shared-mic-engine), PR #210 (diagnostic package)

## Status (2026-05-03)

- **Tier 1 shipped** — 5 tests in `Tests/MacParakeetTests/Audio/MicrophoneEngineRealPlatformTests.swift`. Run with `MACPARAKEET_HARDWARE_TESTS=1`. The 3-min idle test gates additionally on `MACPARAKEET_SLOW_HARDWARE_TESTS=1`.
- **Local results — ALL 5 tests pass on developer hardware**:
  - `testColdStartDeliversBuffers` ✓ 0.39 s
  - `testPostCycleDeliversBuffers` ✓ 0.61 s
  - `testPostVPIODeliversBuffers` ✓ 0.99 s
  - `testStressTenCycles` ✓ 2.94 s
  - `testIdleGapDeliversBuffers` ✓ 180.75 s (gated)
- **What this narrows the hypothesis to**: the bug is not triggered by any same-process scenario we can reach from a test — neither engine recreate, nor VPIO transition, nor 3-min idle. The remaining suspects are external triggers we haven't yet exercised:
  1. **HAL configuration change mid-session** (default-input device switch, sample-rate change, virtual-audio routing toggle). The user's reported-stall log shows 9+ `engine_configuration_changed` events, including one with `ch=9` (multichannel virtual-audio). The idle-gap test sits idle without inducing a config change, so it can't catch this.
  2. **Cross-process VPAU residue** (Tier 3 below).
  3. **System-level events** — sleep/wake, exclusive-access takeover by another process.
- **Tier 2 deferred** — needs a test seam that doesn't exist today.
- **Tier 3 not started** — feasible follow-up.
- **Tier 4 (new) — proposed**: HAL config-change injection. Programmatically toggle the default input device via `AudioObjectSetPropertyData(kAudioHardwarePropertyDefaultInputDevice)` mid-session and assert the platform survives + buffers continue. This is the most direct match for the bug signature seen in the field log.
- **Tier 1 earns its keep** as permanent regression coverage for the healthy paths even though it didn't reproduce the bug. Any future change that breaks the contract on these paths fails immediately.

## Context

The dictation silent stall (May 3, 2026) is a regression: dictation
worked before some recent change, doesn't always work now. PR #210
shipped passive instrumentation — watchdog, heartbeat,
configuration-change observer, HAL listener. That's "wait-and-watch."
We need an **active reproducer** so we can:

1. Trigger the bug deterministically (or at least, frequently)
2. Verify any candidate fix actually closes the gap
3. Catch future regressions before they reach users

The existing `MockMicrophonePlatform`-based unit tests (~150 of them
in `SharedMicrophoneStreamTests.swift`) cover orchestration. They
**mock away the bug** — `MockMicrophonePlatform.configureAndStart`
immediately marks the engine running and stores the tap handler.
The bug lives one layer below: in the real
`AVAudioEngineMicrophonePlatform`'s interaction with macOS HAL.

## The contract being tested

`SharedMicrophoneStream` invariant per ADR-015 and PR #189:

> **Subscribe → buffers arrive within deadline, regardless of prior
> state.**

Operationally:

- Regardless of: cold/warm process start, prior subscribe history,
  VPIO state of co-subscribers, idle duration since the last subscribe,
  prior process audio activity.
- "Within deadline" = first buffer within ~1 second on a healthy
  system. Real-world successful captures show 100–200 ms first-buffer
  latency; 1 s gives a 5× safety margin.

## Test design

### Tier 1 — invariant under varied state (real platform, real mic)

New file: `Tests/MacParakeetTests/Audio/MicrophoneEngineRealPlatformTests.swift`

Each test method:

1. Constructs a real `AVAudioEngineMicrophonePlatform` (no mocks).
2. Drives a specific scenario sequence.
3. Asserts a tap callback fires within 1 second of `configureAndStart`.

| Test method | Scenario |
|-------------|----------|
| `testColdStartDeliversBuffers` | Fresh process, single subscribe |
| `testPostCycleDeliversBuffers` | Subscribe → unsubscribe → resubscribe immediately |
| `testIdleGapDeliversBuffers` | Subscribe → unsubscribe → wait 3 min → subscribe |
| `testConcurrentVPIODeliversBuffers` | VPIO=true subscribe still active, then non-VPIO |
| `testPostVPIODeliversBuffers` | VPIO=true subscribe → unsubscribe → non-VPIO subscribe |
| `testStressTenCycles` | 10 back-to-back subscribe/unsubscribe pairs |

Each test uses `OSAllocatedUnfairLock` to count tap callbacks
thread-safely from the audio render thread. Assert `count > 0` after
the deadline.

### Tier 2 — watchdog unit test (mock platform, fast) — **deferred**

> Status: **DEFERRED** — needs a test seam that doesn't exist today.

Original intent: use the existing `MockMicrophonePlatform` to simulate
the bug shape ("configureAndStart succeeds but no buffers ever arrive")
and verify PR #210's diagnostic watchdog actually logs
`dictation_capture_no_buffers_within_timeout`. This catches *future
regressions in the diagnostic itself* — without it, we'd only know the
watchdog is broken when a stall happens and we get no log.

Why deferred: the watchdog has no observable signal short of writing
to the user's log file. `AudioCaptureDiagnostics.append` writes via a
private static `FileHandle` to the path computed in
`AppPaths.logsDir`; there is no injection point, and the firing-decision
state (`captureDiagnosticsTimers` in `AudioRecorder`) is private and
unreachable even via `@testable import`.

Two routes available, each requiring source changes outside the
test-only scope of this plan:

1. **Extract the firing decision to a pure function.** Pull the
   "should this timer fire?" logic out of
   `AudioRecorder.scheduleFirstBufferTimeout` into a small testable
   helper (`WatchdogTimerDecision.shouldFire(armed:firstBufferSeen:current:for:)`).
   Tiny extraction, comprehensive test coverage, no behavior change.
   **Recommended.**

2. **Inject a logger sink into `AudioCaptureDiagnostics`.** Make the
   `append` destination overridable for tests. Broader API change with
   blast radius across all callers; not justified for one watchdog.

Pick (1) when we're willing to take a small source change. Until then,
the watchdog is verified by code review and field signal only.

### Tier 3 — cross-process VPAU residue (optional, if Tier 1 misses)

If Tier 1 doesn't reproduce, the bug needs cross-process state.
A scripted sequence:

1. Process A engages VPIO via `AVAudioEngineMicrophonePlatform`,
   exits cleanly.
2. Process B, within ~200 ms, subscribes non-VPIO; assert buffers
   arrive within 1 s.

Implement as two test fixtures + a shell harness that runs them in
sequence. Slow, but the only way to falsify the cross-process
hypothesis.

## Gating

These tests require real microphone access. They can't run in CI
without infrastructure that grants TCC microphone access to the test
runner and provides a real or emulated input device. For now:

- Gated via `XCTSkipIf` on a `MACPARAKEET_HARDWARE_TESTS=1` environment
  variable.
- `swift test` skips them by default.
- Developers run locally:
  `MACPARAKEET_HARDWARE_TESTS=1 swift test --filter MicrophoneEngineRealPlatform`
- Document the variable in `docs/cli-testing.md` and AGENTS.md once
  the pattern is proven.

## Out of scope

- **WAV-via-virtual-loopback** (BlackHole, Loopback). Useful for
  content-correctness tests; this bug is "any buffers at all," so
  unnecessary. If we need content-deterministic tests later, that's a
  separate plan.
- **CGEvent / accessibility-based keyboard simulation.**
  `FnKeyStateMachine` is directly testable; reaching the OS event
  layer adds fragility for no diagnostic gain.
- **System-level event injection** (sleep/wake, default-input device
  toggle via `AudioObjectSetPropertyData`). Hard to make reliable.
  Keep as manual repro.
- **Codifying the new test tier in `spec/09-testing.md`.** Premature
  until the pattern proves out. Revisit once tests land.

## Success criteria

- At least one Tier 1 test reliably reproduces the stall on a
  developer machine that has hit the bug in the wild.
  - **If yes:** we have a deterministic reproducer. Pre-write the
    candidate fix (HAL probe + retry in `startEngineLocked`),
    guard with `AppFeatures.dictationStallRecovery`, ship in
    v0.5.8, flip flag and verify test goes green.
  - **If no:** bug needs cross-process state or system-level events.
    Tier 3 + manual repro carry forward.
- All non-idle Tier 1 tests pass on a healthy system within total
  wall-clock < 60 s. The idle-gap test intentionally sleeps 3 min and
  is the only slow one.
- Watchdog unit test (Tier 2) deterministically passes / fails based
  on whether `AudioRecorder` arms the watchdog correctly.

## Estimated effort

| Step | Effort |
|------|--------|
| Tier 1 scaffolding + first scenario | 1 hour |
| All Tier 1 scenarios | 2–3 hours |
| Watchdog unit test (Tier 2) | 30 min |
| Doc updates (AGENTS.md, cli-testing.md, spec/09 if proven) | 30 min |
| Tier 3 cross-process (if needed) | 1–2 hours |

**Total: half a day to a day.**

## Open questions

- Should the idle-gap test really wait 3 minutes? Could we artificially
  trigger the engine teardown that idle would cause (force the shared
  stream to release, then resubscribe immediately)? Faster test, but
  narrower coverage — the real bug may need real wall-clock idle for
  coreaudiod to enter the failure window.
- Should we also add a HAL probe in `AVAudioEngineMicrophonePlatform`
  unconditionally — call `inputNode.outputFormat(forBus: 0)` again
  after `start()` returns, log if it changed? Defensive and low-cost.
- Where does the "Hardware integration" tier fit in
  `spec/09-testing.md` long-term? Add an entry once this pattern proves
  out across at least two investigations.

## Why this is also generally valuable

This investment isn't only for this bug. The audio capture layer is:

- **Opaque** — bugs manifest as silence, not exceptions.
- **OS-dependent** — the same code can succeed or fail based on
  HAL state we don't control.
- **Regression-prone** — every refactor that touches
  `MicrophoneEnginePlatform` or `SharedMicrophoneStream` has the
  potential to silently break the contract.

Once a real-platform integration test target exists with the gating
convention established, future audio investigations get a 30-minute
on-ramp instead of a 4-hour one. That said, the real-mic constraint
makes this a developer-machine tool, not a CI safety net — the trick
is to keep the harness thin enough that maintenance is cheap.
