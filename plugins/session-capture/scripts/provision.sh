#!/bin/sh
# session-capture SessionStart hook: provision the .swiki/ scaffold.
#
# Idempotent — each required path is created only if it is missing, so this is
# safe to run on every session start. Auto-provisioning means enabling the
# plugin for a git project is enough to start capturing; no manual `mkdir
# .swiki` is needed.
#
# Preconditions the capture hook (capture.sh) depends on, and how each is
# handled here:
#   - jq on PATH        -> warn if missing (capture parses its payload with it)
#   - .swiki/           -> the opt-in gate; created here if absent
#   - .swiki/captures/  -> capture bundles land here
#   - .swiki/logs/      -> capture-errors.log lives here
#   - .swiki/done/      -> globbed for same-second sequence counting
#
# git is intentionally NOT required: capture.sh writes the bundle regardless and
# only commits it when a git repo is available, so .swiki/ is provisioned in
# every project, git repo or not.
set -eu

payload=$(cat)

# project_dir: prefer the harness-provided var; fall back to the payload cwd.
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ] && command -v jq >/dev/null 2>&1; then
  project_dir=$(printf '%s' "$payload" | jq -r '.cwd // empty')
fi
[ -n "$project_dir" ] || exit 0

warn() { printf 'session-capture: %s\n' "$1" >&2; }

# jq is needed by the capture hook to parse its payload and write capture.json.
command -v jq >/dev/null 2>&1 || warn "jq not found on PATH; captures will fail until jq is installed"

# Idempotent provisioning: create each required directory only if missing.
for dir in .swiki .swiki/captures .swiki/logs .swiki/done; do
  target="$project_dir/$dir"
  [ -d "$target" ] || mkdir -p "$target" || warn "failed to create $dir"
done

exit 0
