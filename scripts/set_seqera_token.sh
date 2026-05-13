#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.awsbatch.env"

if [[ -n "${1:-}" ]]; then
    TOKEN="$1"
else
    read -rsp "Seqera access token: " TOKEN
    printf '\n'
fi

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Seqera access token cannot be empty" >&2
    exit 1
fi

touch "$ENV_FILE"
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

grep -v '^export TOWER_ACCESS_TOKEN=' "$ENV_FILE" > "$TMP_FILE" || true
printf "export TOWER_ACCESS_TOKEN='%s'\n" "$TOKEN" >> "$TMP_FILE"
mv "$TMP_FILE" "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true

echo "Saved Seqera token to $ENV_FILE"
