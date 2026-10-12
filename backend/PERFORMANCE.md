# Workspace performance

This release keeps the TypeScript frontend, BAML service and CLI, and Python crypto helper. No new hosted service is required.

## Release order

1. Apply `backend/migrations/003_workspace_performance.sql` to the existing CodeTurtle database **before** deploying. It follows the original setup and review-signoffs SQL. It is rerunnable, keeps review history, and grants its RPCs only to `service_role`. The integration suite applies it twice.
2. Build frontend assets and deploy the backend image containing them together. Existing clients can still use the legacy draft endpoint; its writes increment the same draft version so new clients detect conflicts.
3. Smoke-test sign-in, a personal review link, a private comment/reload, two-tab conflicts, and final submission on a test PR. Confirm outbox delivery and GitHub's current-head check. Do not publish a real review just to measure performance.

The migration has only been applied to disposable local databases during implementation. No production migration, push, or deployment is included in this change.

## Implemented behavior

- A small dashboard entry loads the review module and Monaco separately. Review bootstrap and the editor import start together. Metadata renders before file content; only the next assigned file is prefetched, with two client fetch slots and in-flight deduplication.
- One Monaco editor survives navigation, comment saves and layout changes. A 12-pair / 12 MiB LRU retains text models **and computed diff view models**, including scroll/folding state. Eviction disposes both; teardown terminates workers. Diff computation is capped at 1.5 seconds and 2 MB, unchanged lines can expand, and a GitHub fallback remains available. Accessibility stays enabled.
- Client content is limited to 12 files / 8 MiB. Comment requests fetch 50 events per page and retain up to 12 inactive file histories. A selected file can load further pages explicitly. Private drafts are never evicted. Header/tree/progress updates skip unchanged DOM; personal decisions and file statuses are indexed/cached per state update.
- Workspace bootstrap returns CSRF and authenticated context together. Warm bootstrap uses two DB RPCs and three provider requests for an individual owner. Draft operations use two DB RPCs and two provider requests, avoiding per-save installation-token minting and live-head fetching. Teams require additional membership checks.
- BAML caches immutable blobs by tenant/repository/commit/path (16 MiB) and installation tokens by tenant/installation/repository/permissions (256 KiB; 50-minute TTL with expiry guard). Cache misses coalesce, loaders have four slots, and metadata changes serialize. Entries also have a 128-entry bound. Authorization is checked on **every** content request, including hits. Provider errors and validated installation webhooks invalidate token caching. Private code is never put into public/CDN caching.
- The delivery worker prepares the snapshot and first two files before publishing a link; failure to warm optional content does not prevent delivery.
- Comment/decision operations render locally immediately, then show durable save status. A serial queue retains failed edits for Retry. UUID receipts make retries idempotent; expected versions detect conflicting tabs. Retrying a conflict reloads server state before replaying local operations. Final publication waits for the queue and checks its acknowledged version under the same database locks as draft writes.
- Private operations validate session, CSRF, tenant/repository access, identity, assignment, immutable revision, and whether the stored run is superseded. They intentionally do **not** fetch GitHub's current PR head per save. Final submission rechecks the live GitHub head and ownership. A draft saved in the interval before a superseding webhook cannot bypass submission validation.
- Bootstrap projects latest decisions/overrides instead of sending all historical comments. Append-only audit history remains intact. New indexes support PR/run history and user drafts. Operation receipts remain for the run's lifetime so a delayed retry cannot apply twice.

## Diagnostics and reproduction

`?run=...&performance=1` enables a local diagnostics panel. It records timings/counts, never source, comment bodies, identities or tokens; it sends no telemetry. Metrics include bootstrap, shell, content, file switch, first diff, diff paint, long tasks and durable drafts. File-switch time ends at model attachment; diff-paint is reported separately. Server responses expose `Server-Timing` for total, DB and provider calls. Parallel stage durations are summed and can exceed wall time.

Run from the repository root with the original operator SQL handoffs:

```sh
export CODETURTLE_TEST_SQL=/absolute/path/codeturtle-supabase-setup.md
export CODETURTLE_TEST_REVIEW_SQL=/absolute/path/codeturtle-review-signoffs.md
npm --prefix frontend test
npm --prefix frontend run build
backend/.venv/bin/python -m unittest discover -s backend/tests -p test_service.py -v
CODETURTLE_SOAK_ROUNDS=20 backend/.venv/bin/python backend/tests/benchmark_workspace.py
backend/.venv/bin/python backend/tests/workspace_harness.py
```

The UI harness prints a loopback-only URL backed by disposable PostgreSQL, real BAML HTTP and fake provider responses. The special fixture login exists only in the generated temporary test project, never the service source. Set `CODETURTLE_FIXTURE_FILES`, `CODETURTLE_FIXTURE_LINES`, and `CODETURTLE_FIXTURE_COMMENTS` to exercise 3/50/300 files, 200/2,000/20,000 lines and 0/200/2,000 comments. Stop it with Ctrl-C to clean up. No production credentials are needed.

## Measured locally, 2026-10-09

The local benchmark output is excluded from Git. The measurements below came from an isolated API benchmark: 30 samples per endpoint/concurrency level; one-file API fixture, real local BAML/Postgres and loopback GitHub transport. These are **not Fly/Supabase production latency measurements**.

| Warm endpoint | p95, 1 concurrent | p95, 5 concurrent | p95, 20 concurrent |
|---|---:|---:|---:|
| Bootstrap | 37.6 ms | 54.5 ms | 711.9 ms |
| Cached content | 20.5 ms | 28.2 ms | 92.0 ms |
| Comment page | 39.1 ms | 43.3 ms | 173.4 ms |

Thirty serialized draft operations had p95 47.3 ms. The process-tree RSS peak was 243,104 KiB and the final sample 194,672 KiB after 2,000 additional cached reads, with memory returning below the peak. The PR lookup on 10,001 seeded runs used `ct_runs_pr_created`, one matching row, 0.037 ms execution; this is one plan sample, not an endpoint latency claim.

Browser smoke testing used 50 files × 2,000 lines and 200 published comments. It verified save/reload and pagination, and 100 file switches retained one editor and at most 24 text models. A saved comment created no new editor or text models. After caching computed diff view models, a 30-switch two-file run measured 90 ms p95 through model attachment and 136 ms p95 from attachment to paint; its first diff was 923 ms. These intervals are distinct and the full click-to-painted-diff budget is not yet established. Browser observations use the everyday Chrome profile, not an extension-free controlled CPU trace.

## Deployment validation still required

Measure production-region DB/provider RTT, first diff on constrained CPU/network, and p75 INP after release. Targets remain warm shell/comments <=500 ms p95, first diff <=1 s warm / <=2 s constrained, cached switch <=100 ms, local feedback <=50 ms, durable save <=500 ms, and INP <=200 ms. Local samples do not establish those production SLOs; even the local 20-request bootstrap burst exceeded 500 ms.

No region move, extra memory/CPU, CDN, mutable authorization cache or runtime HTTP-pooling replacement is justified by these local results. Fly already compresses assets. Conditional GitHub metadata requests still require the same authorization round trip, so they are deferred until response-byte/rate-limit traces show a benefit. A frontend framework or diff-library replacement is unnecessary for these changes. More aggressive list virtualization and CI-uploaded blobs remain optional follow-ups if the larger fixture profiles show a need.
