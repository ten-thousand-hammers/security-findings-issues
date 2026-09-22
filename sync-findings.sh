#!/usr/bin/env bash
# Reconcile a set of security findings against the issues that track them.
#
# Each finding carries a stable key, written into the issue body as an HTML
# comment. That marker is what lets a later run recognise its own issues
# without depending on titles, which move as versions and severities change.
set -euo pipefail

LABEL="${LABEL:-security}"
MAX_NEW="${MAX_NEW:-25}"
RETIRE_TITLE="${RETIRE_TITLE:-}"
RUN_URL="${RUN_URL:-}"
MARKER_PREFIX='<!-- security-finding:'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Everything from the timestamp down is rewritten on every run. Comparing
# without it keeps a quiet day from bumping every issue each morning, which is
# the fastest way to train everyone to ignore the label.
canonical() { sed '/^Still outstanding as of /,$d'; }

findings="$work/findings.jsonl"
if [ -n "${FINDINGS:-}" ] && [ -f "$FINDINGS" ]; then
  # Callers concatenate per-scan files, so blank lines are expected.
  grep -v '^[[:space:]]*$' "$FINDINGS" > "$findings" || :
else
  echo "::warning::No findings file at '${FINDINGS:-}'; treating the repository as clean."
  : > "$findings"
fi

# A malformed or duplicated key mistracks every later run, so both are hard
# failures rather than something to paper over.
if [ -s "$findings" ]; then
  if ! jq -e 'has("key") and has("title") and has("body")
              and (.key | type == "string") and (.key | length > 0)' "$findings" >/dev/null; then
    echo '::error::Every finding needs a non-empty string "key", plus "title" and "body".'
    exit 1
  fi
  duplicates="$(jq -r '.key' "$findings" | sort | uniq -d)"
  if [ -n "$duplicates" ]; then
    echo "::error::Duplicate finding keys: $(printf '%s' "$duplicates" | tr '\n' ' ')"
    exit 1
  fi
fi
total="$(grep -c '' "$findings" || true)"

# The label has to exist before it can be applied or filtered on.
gh label create "$LABEL" --color B60205 \
  --description "Outstanding security findings" >/dev/null 2>&1 || true

gh issue list --state open --label "$LABEL" --limit 500 \
  --json number,title,body > "$work/open.json"

# number -> key, for the issues this action owns.
: > "$work/managed.tsv"
jq -r --arg p "$MARKER_PREFIX" '
  .[] | . as $i
  | ($i.body // "")
  | split("\n")[]
  | select(startswith($p))
  | "\($i.number)\t\(ltrimstr($p) | rtrimstr("-->") | gsub("^\\s+|\\s+$"; ""))"
' "$work/open.json" > "$work/managed.tsv" || :

created=0; updated=0; closed=0; deferred=0; unchanged=0

while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  key="$(printf '%s' "$finding" | jq -r '.key')"
  title="$(printf '%s' "$finding" | jq -r '.title')"

  {
    printf '%s %s -->\n\n' "$MARKER_PREFIX" "$key"
    printf '%s\n' "$finding" | jq -r '.body'
    printf '\n---\nStill outstanding as of %s' "$(date -u '+%Y-%m-%d %H:%M UTC')"
    if [ -n "$RUN_URL" ]; then printf ', per [this run](%s)' "$RUN_URL"; fi
    printf '.\nThis issue closes automatically once the finding no longer appears.\n'
  } > "$work/body.md"

  number="$(awk -F'\t' -v k="$key" '$2 == k { print $1; exit }' "$work/managed.tsv")"

  if [ -n "$number" ]; then
    jq -r --argjson n "$number" '.[] | select(.number == $n) | .body // ""' \
      "$work/open.json" > "$work/current.md"
    if diff -q <(canonical < "$work/current.md") <(canonical < "$work/body.md") >/dev/null; then
      echo "unchanged  #$number  $key"
      unchanged=$((unchanged + 1))
    else
      gh issue edit "$number" --body-file "$work/body.md" </dev/null >/dev/null
      echo "updated    #$number  $key"
      updated=$((updated + 1))
    fi
  elif [ "$created" -ge "$MAX_NEW" ]; then
    echo "deferred   (cap $MAX_NEW)  $key"
    deferred=$((deferred + 1))
  else
    url="$(gh issue create --title "$title" --label "$LABEL" --body-file "$work/body.md" </dev/null)"
    echo "opened     $url  $key"
    created=$((created + 1))
  fi
done < "$findings"

# Anything this action owns without a matching finding has been fixed.
while IFS=$'\t' read -r number key; do
  [ -n "$key" ] || continue
  if ! jq -e --arg k "$key" 'select(.key == $k)' "$findings" >/dev/null 2>&1; then
    comment="No longer reported as of $(date -u '+%Y-%m-%d')."
    if [ -n "$RUN_URL" ]; then comment="$comment Closed by [this run]($RUN_URL)."; fi
    gh issue close "$number" --comment "$comment" </dev/null >/dev/null
    echo "closed     #$number  $key"
    closed=$((closed + 1))
  fi
done < "$work/managed.tsv"

# Retire a previous roll-up issue, once, on the run that replaces it.
if [ -n "$RETIRE_TITLE" ]; then
  legacy="$(jq -r --arg t "$RETIRE_TITLE" --arg p "$MARKER_PREFIX" '
    .[] | select(.title == $t) | select((.body // "") | contains($p) | not) | .number
  ' "$work/open.json" | head -1)"
  if [ -n "$legacy" ]; then
    gh issue close "$legacy" --comment \
      "Superseded. Each finding is now tracked on its own issue under the \`$LABEL\` label, so it can be closed as it is fixed." </dev/null >/dev/null
    echo "retired    #$legacy  (aggregate issue)"
  fi
fi

{
  echo "outstanding=$total"
  echo "created=$created"
  echo "updated=$updated"
  echo "closed=$closed"
  echo "deferred=$deferred"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$deferred" -gt 0 ]; then
  echo "::warning::$deferred new finding(s) held back by max-new-issues=$MAX_NEW; the next run files them."
fi

echo "$total outstanding; opened $created, updated $updated, unchanged $unchanged, closed $closed."
