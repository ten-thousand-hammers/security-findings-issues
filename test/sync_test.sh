#!/usr/bin/env bash
# Drives sync-findings.sh against a fake gh CLI through a full lifecycle.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PATH="$ROOT/test/bin:$PATH"
export PATH

pass=0; fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  ok   %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}
contains() { case "$2" in *"$1"*) echo yes;; *) echo no;; esac; }
states()     { python3 "$ROOT/test/inspect.py" states; }
open_count() { python3 "$ROOT/test/inspect.py" open-count; }
edits()      { python3 "$ROOT/test/inspect.py" edit-calls; }
body()       { python3 "$ROOT/test/inspect.py" body "$1"; }
out()        { local v; v="$(grep "^$1=" "$GITHUB_OUTPUT" 2>/dev/null | cut -d= -f2)"; echo "${v:-unset}"; }

setup() {
  WORK="$(mktemp -d)"
  export GH_STATE="$WORK/state.json"
  export GITHUB_OUTPUT="$WORK/output"
  export LABEL=security MAX_NEW=25 RETIRE_TITLE="" RUN_URL="https://run/1" CLOSE_RESOLVED=true
  printf '{"issues": [], "calls": []}' > "$GH_STATE"
  : > "$GITHUB_OUTPUT"
}
finding() { printf '{"key":"%s","title":"%s","body":"%s"}\n' "$1" "$2" "$3"; }
run_sync() {
  export FINDINGS="$1"
  : > "$GITHUB_OUTPUT"
  OUT="$(bash "$ROOT/sync-findings.sh" 2>&1)"; RC=$?
}

echo "== one issue per finding =="
setup
{ finding "gem/rack/CVE-1" "rack 2.0: CVE-1" "Upgrade rack."
  finding "gem/nokogiri/CVE-2" "nokogiri 1.0: CVE-2" "Upgrade nokogiri."
  finding "brakeman/abc123" "SQL injection in app/models/user.rb" "Sanitise it."; } > "$WORK/f.jsonl"
run_sync "$WORK/f.jsonl"
check "exit 0" "0" "$RC"
check "three opened" "3" "$(out created)"
check "outstanding counted" "3" "$(out outstanding)"
check "three open" "3" "$(open_count)"
check "body carries its key marker" "yes" "$(contains '<!-- security-finding: gem/rack/CVE-1 -->' "$(body 1)")"

echo "== a second run with the same findings changes nothing =="
run_sync "$WORK/f.jsonl"
check "nothing created" "0" "$(out created)"
check "nothing updated" "0" "$(out updated)"
check "no edit calls at all" "0" "$(edits)"
check "still three open" "3" "$(open_count)"

echo "== a changed finding updates only its own issue =="
{ finding "gem/rack/CVE-1" "rack 2.0: CVE-1" "Upgrade rack to 2.0.9."
  finding "gem/nokogiri/CVE-2" "nokogiri 1.0: CVE-2" "Upgrade nokogiri."
  finding "brakeman/abc123" "SQL injection in app/models/user.rb" "Sanitise it."; } > "$WORK/f2.jsonl"
run_sync "$WORK/f2.jsonl"
check "one updated" "1" "$(out updated)"
check "none created" "0" "$(out created)"
check "exactly one edit call" "1" "$(edits)"
check "new text landed" "yes" "$(contains 'Upgrade rack to 2.0.9.' "$(body 1)")"

echo "== a resolved finding closes just its issue =="
{ finding "gem/rack/CVE-1" "rack 2.0: CVE-1" "Upgrade rack to 2.0.9."
  finding "brakeman/abc123" "SQL injection in app/models/user.rb" "Sanitise it."; } > "$WORK/f3.jsonl"
run_sync "$WORK/f3.jsonl"
check "one closed" "1" "$(out closed)"
check "two left open" "2" "$(open_count)"
check "the nokogiri one closed" "1:open 2:closed 3:open" "$(states)"

echo "== a clean repository closes everything =="
: > "$WORK/empty.jsonl"
run_sync "$WORK/empty.jsonl"
check "two closed" "2" "$(out closed)"
check "none left open" "0" "$(open_count)"
check "outstanding is zero" "0" "$(out outstanding)"

echo "== a finding that comes back opens a fresh issue =="
run_sync "$WORK/f3.jsonl"
check "two filed again" "2" "$(out created)"
check "two open" "2" "$(open_count)"

echo "== duplicate keys fail loudly =="
setup
{ finding "gem/rack/CVE-1" "a" "b"; finding "gem/rack/CVE-1" "c" "d"; } > "$WORK/dup.jsonl"
run_sync "$WORK/dup.jsonl"
check "exit 1" "1" "$RC"
check "names the duplicate" "yes" "$(contains 'Duplicate finding keys: gem/rack/CVE-1' "$OUT")"
check "filed nothing" "0" "$(open_count)"

echo "== a finding missing its key fails loudly =="
setup
printf '{"title":"no key","body":"x"}\n' > "$WORK/bad.jsonl"
run_sync "$WORK/bad.jsonl"
check "exit 1" "1" "$RC"
check "filed nothing" "0" "$(open_count)"

echo "== a missing findings file is treated as clean, with a warning =="
setup
run_sync "$WORK/does-not-exist.jsonl"
check "exit 0" "0" "$RC"
check "warns" "yes" "$(contains '::warning::No findings file' "$OUT")"
check "outstanding is zero" "0" "$(out outstanding)"

echo "== max-new-issues defers the overflow =="
setup
export MAX_NEW=2
{ finding "a" "A" "x"; finding "b" "B" "x"; finding "c" "C" "x"; } > "$WORK/three.jsonl"
run_sync "$WORK/three.jsonl"
check "two created" "2" "$(out created)"
check "one deferred" "1" "$(out deferred)"
check "warns about the cap" "yes" "$(contains '::warning::1 new finding' "$OUT")"
check "the deferred one is not closed" "0" "$(out closed)"
export MAX_NEW=25
run_sync "$WORK/three.jsonl"
check "next run files the rest" "1" "$(out created)"
check "all three open" "3" "$(open_count)"

echo "== close-resolved=false keeps issues while a scan is broken =="
setup
{ finding "gem/rack/CVE-1" "rack: CVE-1" "Upgrade rack."
  finding "gem/nokogiri/CVE-2" "nokogiri: CVE-2" "Upgrade nokogiri."; } > "$WORK/two.jsonl"
run_sync "$WORK/two.jsonl"
check "two opened" "2" "$(out created)"
# The gem scan broke, so it reports only its own failure. Both gem findings
# are missing, but they are missing because nothing looked, not because the
# advisories were fixed.
{ finding "scan/bundler-audit" "bundler-audit could not complete" "It exited 1."; } > "$WORK/broken.jsonl"
export CLOSE_RESOLVED=false
run_sync "$WORK/broken.jsonl"
check "exit 0" "0" "$RC"
check "scan failure filed" "1" "$(out created)"
check "nothing closed" "0" "$(out closed)"
check "both gem issues still open" "3" "$(open_count)"
check "warns that it withheld closing" "yes" "$(contains '::warning::Not closing anything' "$OUT")"
# The next healthy run closes what is genuinely fixed.
export CLOSE_RESOLVED=true
run_sync "$WORK/two.jsonl"
check "scan issue closed once the scan works" "1" "$(out closed)"
check "two gem issues remain" "2" "$(open_count)"
unset CLOSE_RESOLVED

echo "== retire-title closes a previous aggregate issue =="
setup
cat > "$GH_STATE" <<'JSON'
{"issues": [{"number": 1, "title": "Security: outstanding dependency and code advisories",
             "state": "open", "body": "### 2 gem advisory(s)\n- old rollup", "comments": []}],
 "calls": []}
JSON
export RETIRE_TITLE="Security: outstanding dependency and code advisories"
{ finding "gem/rack/CVE-1" "rack: CVE-1" "Upgrade rack."; } > "$WORK/f4.jsonl"
run_sync "$WORK/f4.jsonl"
check "aggregate closed" "1:closed 2:open" "$(states)"
check "per-finding issue opened" "1" "$(out created)"
check "aggregate not counted as a finding" "0" "$(out closed)"
run_sync "$WORK/f4.jsonl"
check "retiring is idempotent" "1:closed 2:open" "$(states)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
