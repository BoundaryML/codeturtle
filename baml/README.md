# CodeTurtle (BAML)

CLI + backend. The CLI computes who must review which changed files
and why; in GitHub Actions it registers with OIDC, evaluates
backend-issued inputs, and uploads an immutable report. The backend
stores requirements, signs reviewers in with GitHub, records explicit
per-file approve/reject decisions, computes collective satisfaction,
and publishes the check run, bot review, and PR summary. Implemented
from `codeturtle-cli.md` / `codeturtle-backend.md` on BAML
0.20.2-nightly. No frontend yet; the review workspace will be a
client-side app over the JSON API.

## Run the CLI

```sh
BAML_TELEMETRY=off baml run main -- help
BAML_TELEMETRY=off baml run main -- check --base main
BAML_TELEMETRY=off baml run main -- lint
baml pack main --output ./codeturtle
./codeturtle check --backend https://reviews.example.com   # in Actions
```

## Run the backend

```sh
baml pack server.serve --output ./codeturtle-server
CODETURTLE_DB=./codeturtle-db.json PORT=8787 ./codeturtle-server
```

Environment: `CODETURTLE_DB` (JSON state file), `PORT` /
`CODETURTLE_BIND`, `CODETURTLE_TLS_CERT` + `CODETURTLE_TLS_KEY`
(HTTPS), `CODETURTLE_PUBLIC_URL`, `GITHUB_CLIENT_ID` +
`GITHUB_CLIENT_SECRET` (OAuth login), `CODETURTLE_GITHUB_TOKEN`
(App installation token for publishing and PR input lookup),
`CODETURTLE_WEBHOOK_SECRET`, `CODETURTLE_ADMIN_TOKEN` (enrollment
admin fallback), `CODETURTLE_ALLOW_CLIENT_INPUTS=1` (dev only: trust
registration payload SHAs when the GitHub API cannot resolve them).

API: all spec endpoints under `/v1/` (auth, webhooks, enrollment,
evaluation attempts, workload, pull requests, evaluation files/diff,
decisions, objection resolutions, comments, activity,
reevaluations). `GET /` returns service info JSON for health checks.

## Layout

| File | Role |
| --- | --- |
| `baml_src/main.baml` | CLI entry (root): dispatch glue, typed errors, exit codes |
| `baml_src/errors.baml` | `CliError` + `ErrorCode` enum (stdlib csv-style); `ToString`/`ToJson` give spec wire names |
| `baml_src/types.baml` | Shared domain/wire contracts: report, policy, registration payloads, versions |
| `baml_src/ns_engine/policy.baml` | CODETURTLE.md block + rule parsing, all errors collected |
| `baml_src/ns_engine/conditions.baml` | Typed check registry (`FileCheck`/`FilesCheck`/`PrCheck`), invocation, scope validation |
| `baml_src/ns_engine/git.baml` | `Git` class: one exec path, typed verbs, diff inventory |
| `baml_src/ns_engine/evaluate.baml` | Match -> invoke -> normalize, report build/serialize/save |
| `baml_src/ns_cli/cli.baml` | Arg parsing (exact spec surface), local/hosted flows |
| `baml_src/ns_cli/backend_client.baml` | CLI-side backend client: OIDC, registration, idempotent upload, renewal |
| `baml_src/ns_cli/render.baml` | Human-readable terminal output |
| `baml_src/ns_cli/help.baml` | Offline help text |
| `baml_src/ns_lib/ns_*/` | One namespace per util under `root.lib`: `url` (rust-url model), `paths`, `digest`, `text`, `limits`, `hmac`, `base64`, `env`, `owners` |
| `baml_src/ns_lib/ns_clap/clap.baml` + `errors.baml` | Clap-style argument parser: builder spec, typed `Matches`, closed-union `ParseError`, help rendering; stdlib-only, no app dependencies |
| `baml_src/ns_server/types.baml` | Backend records, `HttpError`, spec error body |
| `baml_src/ns_server/store.baml` | JSON-file store, atomic saves, lookups, audit |
| `baml_src/ns_server/aggregate.baml` | Decision projection, eligibility, collective state |
| `baml_src/ns_server/github.baml` | GitHub API: PR inputs, team membership, publisher |
| `baml_src/ns_server/http.baml` | Router, handlers, OAuth, webhooks, `serve()` |

Namespaces are `ns_*` directories, kept flat like Go packages:
`root` holds only the shared contracts and CLI entry, `root.engine`
is the pure evaluation engine, `root.cli` is the command-line
product, `root.server` is the backend, and `root.lib.*` nests one
generic helper per namespace (`root.lib.url.Url`,
`root.lib.clap.parse`, and so on). Same-namespace files share scope; cross-namespace
references are absolute (`root.utils.Url`, `root.engine.evaluate`,
`root.Report`). CLI and backend share one project so the backend
decodes the CLI's exact `Report` type.

## Scope notes

- Conditions: policy names are dynamic text, resolved once at the
  parse boundary into typed `Condition` values. The registry is
  compiled in behind the spec contracts; loading arbitrary
  `.codeturtle/functions` packages needs a BAML dynamic-loading
  mechanism that does not exist yet.
- Backend payloads follow the spec endpoint table (no `openapi.json`
  was present); responses decode tolerantly.
- OIDC tokens are claim-checked (repository, run, enrollment, trusted
  workflow) but not signature-verified: JWKS/RS256 is not exposed by
  the BAML stdlib yet. Add verification before public deployment.
- The publisher uses a pre-minted App installation token from the
  environment for the same reason. Without it, publication stays
  visibly `pending`.
- Reports carry diff digests, not patches, so the diff endpoint
  returns `available: false` until artifacts are added to the report.
- Storage is a single-process JSON file with atomic rewrites.
- Evaluation is sequential; persisted order is rule line, then path.
- Terminal output uses ASCII `-` where spec examples show an em dash.
- Verified locally: full backend API flow (enroll, register, upload,
  idempotent replay, conflict, preview rejection), CLI hosted flow up
  to TLS trust (self-signed localhost cert rejected by the client,
  exit 3 with no fallback, as specified). A trusted-cert deployment
  or real Actions run is needed for the last hop.

## Verify

```sh
BAML_TELEMETRY=off baml check
BAML_TELEMETRY=off baml test
baml fmt baml_src/*.baml baml_src/ns_*/*.baml baml_src/ns_lib/ns_*/*.baml
```
