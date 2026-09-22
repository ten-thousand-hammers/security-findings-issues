# security-findings-issues

Track each outstanding security finding as its own issue.

A CVE against one gem is one unit of work, so it gets one issue. Three findings
get three issues, each of which can be closed as it is actually fixed. That is
the whole point: a single rolled-up "outstanding advisories" issue cannot be
closed until everything on it is done, so it stays open indefinitely and stops
being read.

This action takes a JSONL file of findings, so any scanner can feed it —
bundler-audit, npm audit, Brakeman, importmap, or something bespoke.

## Behaviour

For every run:

- a finding with no issue gets one opened
- a finding whose issue already exists is left alone, unless its content
  changed, in which case the body is refreshed
- an issue whose finding is gone is closed with a comment

Issues are matched by a stable key written into the body as an HTML comment,
not by title, so a title that moves with a version or a severity does not
orphan its issue.

Nothing is rewritten when nothing changed. A quiet day produces no issue
activity at all, which is what keeps the label worth reading.

## Usage

```yaml
- uses: ten-thousand-hammers/security-findings-issues@v1
  with:
    findings: ${{ runner.temp }}/findings.jsonl
    token: ${{ secrets.GITHUB_TOKEN }}
```

The job needs `issues: write`.

### Inputs

| input | default | description |
| --- | --- | --- |
| `findings` | required | Path to the JSONL file. |
| `token` | required | Needs `issues: write`. |
| `label` | `security` | Applied to, and used to find, every issue this action manages. |
| `max-new-issues` | `25` | Most issues to open in one run. The rest wait for the next run. |
| `retire-title` | none | Title of a previous aggregate issue to close on the run that replaces it. |

### Outputs

`outstanding`, `created`, `updated`, `closed`, `deferred`.

Use `outstanding` to decide whether the job should go red:

```yaml
- if: steps.issues.outputs.outstanding != '0'
  run: |
    echo "::error::${{ steps.issues.outputs.outstanding }} outstanding finding(s)."
    exit 1
```

## The findings file

One JSON object per line:

```json
{"key":"gem/rack/CVE-2025-1234","title":"rack 2.2.3: CVE-2025-1234 (high)","body":"**Gem:** `rack` 2.2.3\n..."}
```

| field | description |
| --- | --- |
| `key` | Stable identity. Must not change between runs for the same finding, and must be unique within a run. |
| `title` | Issue title. Free to change; matching does not depend on it. |
| `body` | Markdown. The action appends its own marker and footer. |

Choosing a key is the only part that needs care, because it is what makes an
issue persist rather than churn:

| source | key |
| --- | --- |
| bundler-audit | `gem/<name>/<advisory id>` |
| npm audit | `npm/<package>/<advisory id>` |
| Brakeman | `brakeman/<fingerprint>` |
| a scan that failed to run | `scan/<name>` |

Brakeman's `fingerprint` is designed for exactly this and survives the line
moving. Do not put a line number in a key.

Duplicate keys, or a finding missing `key`, `title`, or `body`, fail the run
rather than mistracking every run after it.

## Safety valve

`max-new-issues` caps how many issues a single run opens. A mistake in key
generation would otherwise file one issue per finding per run. The overflow is
deferred with a warning and picked up by the next run.

## Tests

```bash
bash test/sync_test.sh
```

They run the real script against a fake `gh` CLI (`test/bin/gh`) that keeps
issues in a state file, covering the create, update, close, recurrence, cap,
validation, and retirement paths.
