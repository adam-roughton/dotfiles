---
name: incident-report
description: Write or update the incident triage report in /workspace/report.md, with evidence and minimal customer data. Use when concluding an infra-agent investigation or when asked for a summary.
---

# Incident report

Write `/workspace/report.md` (overwrite it with the current state each time):

```markdown
# <incident> — <one-line summary>

Environment: <env>   Status: <investigating | cause identified | mitigated?>
Time window: <start – end, UTC>

## Impact
Who and what is affected, how much, since when. Use counts and internal IDs.

## Timeline (UTC)
- hh:mm  event (source)

## Cause
The most likely cause and the confidence in it. Alternatives ruled out, and why.

## Evidence
- <tool and query or filter> → <key result, summarized>

## Recommended actions
Mitigations and fixes for a human (or a code-agent task) to carry out, most
urgent first. Note risks and how to verify each.

## Open questions
What could not be checked (missing access, unreachable sources) and what to
look at next.
```

Rules:

- Summarize results; do not paste raw tool output. Quote at most the few rows
  or log lines that prove a point, with customer identifiers reduced to
  internal IDs and any personal data (names, emails, addresses, payment data)
  removed.
- Mark anything inferred rather than observed.
- The report stays in this incident's workspace. If a fix needs code changes,
  describe them so they can become a separate code-agent task without
  customer data.
