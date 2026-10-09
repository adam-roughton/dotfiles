---
name: infra-triage
description: Triage a production incident with the read-only infra broker tools (Kubernetes, AWS, Azure, databases, Datadog). Use at the start of an infra-agent session or when investigating a production symptom.
---

# Infra triage

The `infra` MCP server is the only way to reach infrastructure. Its tools are
read-only and audited; tool names are `infra_<source>_<tool>`.

## 1. Frame the incident

Write down, in `/workspace/notes.md`:

- the symptom, in the reporter's words, and who or what is affected,
- when it started (ask if unknown) and whether it is ongoing,
- the services, regions, clusters and databases likely involved.

## 2. Orient

- `infra_aws_accounts` lists AWS accounts, regions and services;
  `infra_k8s_namespaces_list` and `infra_azure_subscription_list` show what
  else is reachable.
- Check what already fired: Datadog monitors and events
  (`infra_datadog_search_datadog_monitors`, `..._search_datadog_events`),
  CloudWatch alarms (`infra_aws_read` with `cloudwatch DescribeAlarms`
  `{"StateValue": "ALARM"}`), Azure activity log.
- Look for recent change near the start time: deployments and rollouts
  (`infra_k8s_events_list`, `infra_k8s_resources_list` for Deployments),
  CloudTrail `LookupEvents`, Azure activity log.

## 3. Narrow down

- Logs: Datadog log search or `infra_aws_logs_insights` with a tight time
  range and a filter on the service; Kubernetes `pods_log` for specific pods.
- Metrics: error rate, latency, saturation for the affected service and its
  dependencies, compared with the same window before the incident.
- Traces: follow a failing request across services in Datadog APM.
- Data: use `infra_db_search_objects*` to find tables, then bounded
  `infra_db_execute_sql*` queries to confirm a hypothesis.

Form one hypothesis at a time, state the evidence for and against it, and
record each step (tool, query, result summary) in `notes.md`.

## 4. Conclude

When the cause is identified (or you have exhausted the available access),
write the report with the `incident-report` skill. Recommend fixes and
follow-ups; do not attempt them.
