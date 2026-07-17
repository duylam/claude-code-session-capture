#!/bin/sh
# session-capture SessionStart hook: surface capture errors from earlier sessions.
# A capture hook has no user in front of it when it fails, so the next session
# start is the failure surface. Prints the pending error log, then truncates it
# so each error is surfaced once.
set -eu

payload=$(cat)
project_dir="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$payload" | jq -r '.cwd')}"

error_log="$project_dir/.swiki/logs/capture-errors.log"

if [ -s "$error_log" ]; then
  {
    echo "session-capture: earlier capture attempts failed:"
    cat "$error_log"
  } | tee /dev/stderr
  : > "$error_log"
fi

exit 0
