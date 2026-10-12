# CodeTurtle cloud dashboard

`codeturtle.html` is the combined dashboard saved in hosted Boundary Studio under `codeturtle`.

- Recent PRs: author, head revision, report outcome, eligible reviewers, file counts and links.
- PR details: ownership by file and subsystem, plus the GitHub code diff.
- Reviewers: each owner’s assigned paths and individual CodeTurtle review links.
- Subsystems: path-based grouping of evaluated ownership assignments.
- Backend: recent request/database/provider calls, exception filter, search, per-stage latency, request p50/p95, process IDs and links to Studio spans and Fly console logs. This is a trace-based call log; raw stdout/stderr is not ingested into Studio. Handled HTTP failures can appear as normal function returns.

`backend/baml_src/review_telemetry.baml` emits identifier-only `record_review_event` spans after a report is accepted. No source code, report bodies, comments, or credentials are captured. These events describe evaluated ownership, not completed approvals or successful GitHub notification delivery. Live events currently cover policy-matched paths.

The four initial test PRs were imported from actual GitHub run metadata and CodeTurtle comments; the dashboard labels imported records and retains their original timestamps. Imported file records also include unassigned changed paths and line counts. Historical events are not presented as live application executions.

Queries use Studio’s `boundary.query` API, with no embedded credentials. Review events are limited to the latest 10,000; service spans to 2,000. Counts describe the loaded window and distinct run IDs. Subsystems are display labels inferred from paths, not extra ownership rules.

Upload `codeturtle.html` with **Upload a new version** on the existing cloud dashboard. Earlier individual HTML bundles remain local source references.

## Workflow failures

Review routing, evaluation exit status, and the GitHub job conclusion are separate.
Completed `workflow_job` webhooks populate job status and duration, even if installation
or reporting fails before a review report exists. Enable **Workflow job** under the
CodeTurtle GitHub App's Permissions & events (Actions read access). The receiver verifies
the signature and limits records to enrolled repositories and the `codeturtle` job.
Reports and job events join by repository, Actions run ID, and attempt. Missing job
events display **Not recorded**, never inferred success. Reports from the older CLI
with incomplete coverage are classified as failed evaluations. New reports carry
`cli_exit_code`; GitHub's independently observed job conclusion remains authoritative
for job failures after report acceptance. Webhooks require GitHub delivery; missed
events need redelivery or backfill. No automatic polling reconciler exists yet.
