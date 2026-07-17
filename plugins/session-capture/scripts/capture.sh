#!/bin/sh
# session-capture hook.
#
# Copies the session bundle — transcript + optional sidecar dir — into
# .swiki/captures/<session_id>__<utc_ts>__<seq>/ and makes ONE git commit
# path-scoped to .swiki/. POSIX shell + git/cp/jq only.
# Never runs a model, never pushes.
#
# Fires on SessionEnd only, which covers both session end and pre-/clear. Any
# other event falls through to the unexpected-event failure below.
#
# Exit 0 on no-op (project not opted in, or refusal during rebase/merge/etc —
# the next capture event picks the session up again). Failures append to
# .swiki/logs/capture-errors.log, surfaced by surface-errors.sh on the next
# SessionStart.
#
# SWIKI_CAPTURE_EPOCH (float unix epoch) overrides the clock — test seam only.
set -eu

payload=$(cat)

project_dir="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$payload" | jq -r '.cwd')}"

# Opted in = the project directory carries .swiki/. The boundary is the Claude
# Code project dir, not the git repo, so one repo can hold several.
[ -d "$project_dir/.swiki" ] || exit 0

log_dir="$project_dir/.swiki/logs"
error_log="$log_dir/capture-errors.log"

log_error() {
  mkdir -p "$log_dir"
  printf '%s session-capture: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$error_log"
  printf 'session-capture: %s\n' "$1" >&2
}

fail() {
  log_error "$1"
  exit 1
}

session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')
hook_event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty')

[ -n "$session_id" ] || fail "hook payload has no session_id"
[ -n "$transcript_path" ] || fail "hook payload has no transcript_path"
[ -f "$transcript_path" ] || fail "transcript not found: $transcript_path"

# Capture moment -> capture_event; not recoverable from the transcript.
case "$hook_event" in
  SessionEnd)
    reason=$(printf '%s' "$payload" | jq -r '.reason // empty')
    if [ "$reason" = "clear" ]; then capture_event="clear"; else capture_event="session_end"; fi
    ;;
  *) fail "unexpected hook event: ${hook_event:-<none>}" ;;
esac

# Refusal: never touch the index while a git operation is in flight.
git_dir=$(git -C "$project_dir" rev-parse --git-dir 2>/dev/null) \
  || fail "not inside a git repository: $project_dir"
case "$git_dir" in /*) ;; *) git_dir="$project_dir/$git_dir" ;; esac
for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD BISECT_LOG rebase-merge rebase-apply; do
  if [ -e "$git_dir/$marker" ]; then
    log_error "refusing to capture: git operation in progress ($marker present); next capture event will retry"
    exit 0
  fi
done

# Timestamps are UTC ISO 8601: the item name gets the filename-safe
# second-granularity form; accept-event-since carries milliseconds so
# consecutive same-second captures still describe disjoint event windows.
epoch="${SWIKI_CAPTURE_EPOCH:-$(jq -n 'now')}"
item_ts=$(jq -rn --argjson t "$epoch" '$t | floor | gmtime | strftime("%Y%m%dT%H%M%SZ")')
accept_since=$(jq -rn --argjson t "$epoch" \
  '($t | floor | gmtime | strftime("%Y-%m-%dT%H:%M:%S"))
   + "." + ((($t - ($t | floor)) * 1000 | floor | tostring | ("00" + .)[-3:])) + "Z"')

# <seq> disambiguates same-second captures: count existing bundles for this
# session+second across both queue states.
prefix="${session_id}__${item_ts}__"
count=0
for existing in "$project_dir/.swiki/captures/$prefix"* "$project_dir/.swiki/done/$prefix"*; do
  if [ -d "$existing" ]; then count=$((count + 1)); fi
done
seq=$(printf '%03d' $((count + 1)))

item="${prefix}${seq}"
bundle="$project_dir/.swiki/captures/$item"
mkdir -p "$project_dir/.swiki/captures"
mkdir "$bundle" || fail "bundle already exists: $item"

# Bundle contents, bytes verbatim — never rewritten or filtered.
cp "$transcript_path" "$bundle/transcript.jsonl" || fail "failed to copy transcript"

# Optional sidecar: the session-id directory beside the transcript.
sidecar_src="${transcript_path%.jsonl}"
if [ -d "$sidecar_src" ]; then
  cp -R "$sidecar_src" "$bundle/sidecar" || fail "failed to copy sidecar"
  source_sidecar_json=$(printf '%s' "$sidecar_src" | jq -R '.')
else
  source_sidecar_json="null"
fi

jq -n \
  --arg session_id "$session_id" \
  --arg capture_event "$capture_event" \
  --arg captured_at "$accept_since" \
  --arg accept_event_since "$accept_since" \
  --arg source_transcript "$transcript_path" \
  --argjson source_sidecar "$source_sidecar_json" \
  '{
    session_id: $session_id,
    capture_event: $capture_event,
    captured_at: $captured_at,
    "accept-event-since": $accept_event_since,
    source_transcript: $source_transcript,
    source_sidecar: $source_sidecar
  }' > "$bundle/capture.json" || fail "failed to write capture.json"

# Path-scoped commit: only .swiki/ is ever staged or committed; the
# developer's staged files stay staged and stay out of this commit.
git -C "$project_dir" add -- .swiki/ || fail "git add -- .swiki/ failed"
git -C "$project_dir" commit -q -m "chore(swiki): capture $item" -- .swiki/ \
  || fail "git commit -- .swiki/ failed"

exit 0
