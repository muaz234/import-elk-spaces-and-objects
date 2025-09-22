#!/bin/sh
set -eu

# --- Config (edit if needed) ---
KIBANA_BASE="${KIBANA_BASE:-http://localhost:5601}"
BACKUP_DIR="${BACKUP_DIR:-/Users/muazahmed/Downloads/elk}"
INSECURE="${INSECURE:-0}"   # set to 1 if https with self-signed

[ "$INSECURE" = "1" ] && CURL_INSECURE="-k" || CURL_INSECURE=""

# --- Auth (basic, stored in a temp netrc so your password isn't on the process list) ---
printf "Kibana username: " 1>&2; read KUSER
printf "Kibana password: " 1>&2; stty -echo; read KPASS; stty echo; printf "\n" 1>&2
HOST="${KIBANA_BASE#*://}"; HOST="${HOST%%/*}"; HOST="${HOST%%:*}"

NETRC_FILE="$(mktemp -t kibana_netrc.XXXXXX)"; chmod 600 "$NETRC_FILE"
printf "machine %s login %s password %s\n" "$HOST" "$KUSER" "$KPASS" > "$NETRC_FILE"
trap 'rm -f "$NETRC_FILE"' EXIT INT TERM

slugify() {
  # to lower, non-alnum -> '-', trim leading/trailing '-'
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

create_space() {
  ID="$1"; NAME="$2"
  [ "$ID" = "default" ] && return 0
  STATUS=$(
    curl -sS $CURL_INSECURE --netrc-file "$NETRC_FILE" \
      -o /dev/null -w "%{http_code}" \
      -X POST "$KIBANA_BASE/api/spaces/space" \
      -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
      --data-binary @- <<JSON
{"id":"$ID","name":"$NAME","description":"$NAME","disabledFeatures":[]}
JSON
  ) || STATUS=000
  case "$STATUS" in
    200|201) echo "  - Space created";;
    409)     echo "  - Space exists";;
    *)       echo "  - WARN creating space (HTTP $STATUS)";;
  esac
}

import_ndjson() {
  ID="$1"; FILE="$2"
  [ "$ID" = "default" ] && SPACE_PATH="" || SPACE_PATH="/s/$ID"
  STATUS=$(
    curl -sS $CURL_INSECURE --netrc-file "$NETRC_FILE" \
      -o /dev/null -w "%{http_code}" \
      -X POST "$KIBANA_BASE$SPACE_PATH/api/saved_objects/_import?overwrite=true" \
      -H 'kbn-xsrf: true' \
      -F "file=@${FILE}"
  ) || STATUS=000
  case "$STATUS" in
    200) echo "  - Import OK";;
    *)   echo "  - IMPORT WARN (HTTP $STATUS)";;
  esac
}

echo "Scanning: $BACKUP_DIR"
# Iterate immediate subfolders with an export.ndjson (handles spaces in names)
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r DIR; do
  ND="$DIR/export.ndjson"
  [ -f "$ND" ] || { echo "Skip (no export.ndjson): $DIR"; continue; }
  NAME="$(basename "$DIR")"
  ID="$(slugify "$NAME")"
  [ "$NAME" = "default" ] && ID="default"

  echo "== Space: '$NAME'  (id: $ID)"
  create_space "$ID" "$NAME"
  import_ndjson "$ID" "$ND"
done

echo "Done."

