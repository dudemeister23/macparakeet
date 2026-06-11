#!/usr/bin/env bash
# Cross-repo telemetry allowlist guard.
#
# Every TelemetryEventName case the app can emit must be present in
# ALLOWED_EVENTS in macparakeet-website/functions/api/telemetry.ts. The
# Worker rejects an entire batch when ANY event in it is unknown, so one
# missing allowlist entry silently destroys all co-batched telemetry from
# every affected user. This has bitten three times (AUDIT-073 being the
# third); this guard closes the class.
#
# The website repo is private, so the allowlist is resolved in this order:
#   1. $MACPARAKEET_WEBSITE_TELEMETRY_TS — explicit path to telemetry.ts
#   2. ../macparakeet-website/functions/api/telemetry.ts — sibling checkout
#   3. `gh api` against moona3k/macparakeet-website (honors GH_TOKEN; in CI
#      provide a PAT with read access via the WEBSITE_REPO_TOKEN secret)
# If none is available (e.g. a fork PR without secrets) the check SKIPS
# with a warning rather than failing — but a resolved allowlist with a
# missing event is a hard failure.
#
# Extra events on the website side are informational only: stale entries
# are deliberately retained so old shipped builds keep batching cleanly
# (AUDIT-081).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWIFT_ENUM_FILE="$REPO_ROOT/Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift"
WEBSITE_FILE_PATH="functions/api/telemetry.ts"
WEBSITE_REPO="moona3k/macparakeet-website"

# --- Extract Swift event names -------------------------------------------

enum_block="$(awk '/public enum TelemetryEventName/,/^}/' "$SWIFT_ENUM_FILE")"
if [[ -z "$enum_block" ]]; then
    echo "ERROR: could not locate 'public enum TelemetryEventName' in $SWIFT_ENUM_FILE" >&2
    exit 1
fi

# String enums may omit raw values (case name becomes the value). All
# current cases are explicit; fail loudly if that ever changes so this
# script gets taught the new shape instead of silently missing events.
bare_cases="$(grep -E '^[[:space:]]*case ' <<<"$enum_block" | grep -cv '= "' || true)"
if [[ "$bare_cases" -ne 0 ]]; then
    echo "ERROR: TelemetryEventName has $bare_cases case(s) without explicit raw values; update this script's extraction" >&2
    exit 1
fi

swift_events="$(grep -E '^[[:space:]]*case ' <<<"$enum_block" \
    | sed -E 's/.*= *"([^"]+)".*/\1/' | sort -u)"
swift_count="$(wc -l <<<"$swift_events" | tr -d ' ')"

# --- Resolve the website allowlist ----------------------------------------

allowlist_ts=""
source_used=""

if [[ -n "${MACPARAKEET_WEBSITE_TELEMETRY_TS:-}" && -r "${MACPARAKEET_WEBSITE_TELEMETRY_TS:-}" ]]; then
    allowlist_ts="$(cat "$MACPARAKEET_WEBSITE_TELEMETRY_TS")"
    source_used="\$MACPARAKEET_WEBSITE_TELEMETRY_TS"
elif [[ -r "$REPO_ROOT/../macparakeet-website/$WEBSITE_FILE_PATH" ]]; then
    allowlist_ts="$(cat "$REPO_ROOT/../macparakeet-website/$WEBSITE_FILE_PATH")"
    source_used="sibling checkout"
elif command -v gh >/dev/null 2>&1; then
    if allowlist_ts="$(gh api "repos/$WEBSITE_REPO/contents/$WEBSITE_FILE_PATH" --jq '.content' 2>/dev/null | base64 -d)"; then
        source_used="gh api ($WEBSITE_REPO)"
    fi
fi

if [[ -z "$allowlist_ts" ]]; then
    echo "WARNING: telemetry allowlist check SKIPPED — could not read $WEBSITE_REPO/$WEBSITE_FILE_PATH" >&2
    echo "         (no local checkout and no authenticated gh; in CI set the WEBSITE_REPO_TOKEN secret)" >&2
    exit 0
fi

# First block only: ALLOWED_EVENTS is also referenced later in the file
# (the .has() check), so a sed range would re-open and sweep up unrelated
# string literals.
allowed_events="$(awk '/const ALLOWED_EVENTS/{found=1} found{print} found && /\]\)/{exit}' <<<"$allowlist_ts" \
    | grep -oE '"[^"]+"' | tr -d '"' | sort -u)"
if [[ -z "$allowed_events" ]]; then
    echo "ERROR: found $WEBSITE_FILE_PATH (via $source_used) but could not parse ALLOWED_EVENTS from it" >&2
    exit 1
fi
allowed_count="$(wc -l <<<"$allowed_events" | tr -d ' ')"

# --- Compare ---------------------------------------------------------------

missing="$(comm -23 <(printf '%s\n' "$swift_events") <(printf '%s\n' "$allowed_events"))"
extra="$(comm -13 <(printf '%s\n' "$swift_events") <(printf '%s\n' "$allowed_events"))"

echo "Telemetry allowlist check: $swift_count Swift events vs $allowed_count allowlisted (source: $source_used)"
if [[ -n "$extra" ]]; then
    echo "Note: allowlist entries with no current Swift case (retained on purpose, see AUDIT-081):"
    sed 's/^/  - /' <<<"$extra"
fi

if [[ -n "$missing" ]]; then
    echo "" >&2
    echo "FAIL: Swift emits event(s) the website Worker will REJECT — and a rejected" >&2
    echo "event destroys the entire telemetry batch it ships in:" >&2
    sed 's/^/  - /' <<<"$missing" >&2
    echo "" >&2
    echo "Fix: add the event(s) to ALLOWED_EVENTS in $WEBSITE_REPO/$WEBSITE_FILE_PATH" >&2
    echo "and DEPLOY the website BEFORE merging this change (established process:" >&2
    echo "website allowlist first, app second)." >&2
    exit 1
fi

echo "OK: every Swift telemetry event is allowlisted."
