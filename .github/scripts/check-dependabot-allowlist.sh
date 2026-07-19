#!/usr/bin/env bash
# Usage: check-dependabot-allowlist.sh <comma-separated dependency names> <allowlist file>
# Prints exactly one line "approved=true|false" to stdout; per-dependency
# verdicts go to stderr so they reach the log without polluting the output
# contract (the caller appends stdout to $GITHUB_OUTPUT).
set -euo pipefail

deps_input="${1:-}"
allowlist_file="${2:-}"

approved=true
seen=false
IFS=',' read -ra deps <<< "$deps_input"
for dep in "${deps[@]}"; do
  dep="$(echo "$dep" | xargs)"
  [[ -z "$dep" ]] && continue
  seen=true
  if grep -Fxq "$dep" <(sed 's/\s*$//;/^\s*#/d;/^$/d' "$allowlist_file"); then
    echo "allowed: $dep" >&2
  else
    echo "not allowlisted: $dep" >&2
    approved=false
  fi
done

# Fail closed: nothing to approve means nothing is approved.
if [[ "$seen" == false ]]; then
  approved=false
fi

echo "approved=$approved"
