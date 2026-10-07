# CodeTurtle service

Commands below run from the project root unless stated otherwise.

This directory is an independent project. The CLI evaluates trusted base-branch
policy locally; the BAML backend receives reports and publishes them. The
TypeScript UI reads the backend. A complete evaluation is never human approval.
The original engine and Apache-2.0 license were ported from BoundaryML BAML's
`tools/codeturtle`; no sibling tool is a dependency.

Install Python 3.10+, Git and BAML **0.20.2-nightly.20261004.a**, then:

```sh
python3 -m pip install ./cli
codeturtle help
```

In a trusted `pull_request_target` workflow with `contents: read`, `id-token: write`,
base checkout and fetched PR history, the command is:

```sh
CODETURTLE_API_URL=https://your-service.example codeturtle check --report
```

The CLI discovers PR/run context, requests OIDC, registers, evaluates, uploads,
and prints the durable receipt URL. No provider bot secret goes into CI. Exit
codes: 0 evaluation complete; 1 incomplete evaluation; 2 local setup failure;
3 registration/upload failure. Local report output is preserved on upload failure.
Reporting rejects local policy, fixture and revision overrides. Fork configurations
without a verifiable Actions run-to-PR association fail closed.

`cli/action.yml` installs the CLI from its own trusted action checkout plus a
checksum-verified BAML runtime. Pin the Action to a full commit SHA. Its runtime URL
must identify a binary or official tar.gz archive for the runner platform, at the pinned version;
its expected SHA-256 is mandatory. Release assets and a Homebrew tap have not
been published. There is no assumed production service origin or repository name.

### Backend configuration

Install `backend/requirements.txt` in a Python virtual environment. Build the UI
with `npm ci && npm run build` inside `frontend/`. Start from `backend/`:

```sh
baml --agent-skill-check off run main -- --addr 0.0.0.0:8080
```

Set these **CodeTurtle-specific** environment variables:

| Variable | Value |
| --- | --- |
| `CODETURTLE_API_URL` | Public HTTPS origin, also the OIDC audience |
| `CODETURTLE_SUPABASE_URL` | Dedicated Supabase HTTPS origin |
| `CODETURTLE_SUPABASE_KEY` | Legacy service-role JWT, server only |
| `CODETURTLE_GITHUB_APP_ID`, `CODETURTLE_GITHUB_BOT_ID` | App and numeric bot user IDs |
| `CODETURTLE_GITHUB_PRIVATE_KEY`, `CODETURTLE_GITHUB_WEBHOOK_SECRET` | App private key and signing secret |
| `CODETURTLE_GITHUB_CLIENT_ID`, `CODETURTLE_GITHUB_CLIENT_SECRET` | App user OAuth credentials |
| `CODETURTLE_WORKOS_CLIENT_ID`, `CODETURTLE_WORKOS_API_KEY` | AuthKit organization login credentials |
| `CODETURTLE_SLACK_CLIENT_ID`, `CODETURTLE_SLACK_CLIENT_SECRET` | Optional Slack App OAuth credentials |
| `CODETURTLE_ENCRYPTION_KEY` | 32 random bytes as 64 hex characters; held outside the database |
| `CODETURTLE_PYTHON` | Crypto virtualenv Python executable (defaults to python3) |
| `CODETURTLE_CRYPTO_PATH` | Absolute path to backend/crypto.py |
| `CODETURTLE_MODELS_PATH` | Absolute path to cli/baml_src/models.baml |
| `CODETURTLE_FRONTEND_DIR` | Absolute path to frontend/dist |
| `CODETURTLE_ACTION_REF` | Published owner/repo/cli@full-commit-SHA for setup workflows |
| `CODETURTLE_RUNTIME_URL`, `CODETURTLE_RUNTIME_SHA256` | Pinned Linux BAML archive and digest for setup workflows |

Only the small RS256 helper uses Python on the service; authentication policy,
HTTP serving, database access, onboarding and provider clients are BAML.

The separately supplied Supabase SQL handoff creates private tables and
service-role-only RPCs. Apply it explicitly in a dedicated Supabase project;
startup never changes the schema. Configure WorkOS `/auth/callback`, GitHub App
`/auth/github/callback`, Slack `/auth/slack/callback`, and GitHub webhook
`/webhooks/github` on the HTTPS service origin. Subscribe the GitHub App to
installation, installation_repositories and pull_request events. GitHub login
checks installation access and repository administrator authority, then binds
that repository to the signed-in WorkOS organization. Read access is rechecked
with GitHub for each report; setup mutations also require CSRF and admin access.

Grant GitHub Contents/Actions read and Pull requests write for normal operation.
Setup-PR writing additionally needs Contents/Workflows write; these are requested
only when the user clicks Create setup PR. Restricted Apps can use the previewed
workflow/policy files for a manual maintainer PR. Existing workflows and policy
files are preserved. After merge, verify setup to trust the exact workflow blob,
then open/update a subsequent PR. Reinstall/revocation requires re-linking access.
Slack needs chat:write, channels:history, groups:history and users:read. Invite the
bot to the chosen channel and configure explicit GitHub-owner → Slack-ID mappings.
Reports/evidence stay out of Slack; later updates reuse the original message.

Acceptance atomically persists the report and delivery outbox. Identical uploads
reuse receipts; conflicting bytes fail. Worker leases last 30 minutes and survive
process restarts; expired leases recover. Provider failures retry with bounded
backoff up to eight attempts and then remain visibly failed. Reconciliation reads
bot-owned GitHub comments and Slack message metadata before creating anything.
Unreported runs time out after two hours. `/healthz` is liveness; `/readyz` checks
the database. Supabase outages return a retryable error rather than a false receipt.

### Verification and deployment boundary

```sh
baml --agent-skill-check off test --directory cli
python3 -m unittest discover -s cli -p test_reporting.py -v
baml --agent-skill-check off test --directory backend
backend/.venv/bin/python -m unittest discover -s backend/tests -p test_crypto.py -v
CODETURTLE_TEST_SQL=/absolute/path/to/operator-handoff.md \
  backend/.venv/bin/python -m unittest discover -s backend/tests -p test_service.py -v
npm --prefix frontend run typecheck
npm --prefix frontend run build
```

The integration suite creates and destroys its own PostgreSQL cluster; set
`PG_BIN` to your PostgreSQL 17 bin directory when needed. It uses real RSA keys,
a real BAML listener and real SQL transactions. GitHub/OIDC provider HTTP responses
are injected only into a temporary test project, never through production flags.
Tests make no live provider writes. The local HTTP opt-in in the Python CLI is
restricted to numeric loopback addresses for that suite.

From the project root, build `backend/Dockerfile` with the Linux runtime URL and
SHA build arguments. Set the Fly app/region explicitly per environment in a local
configuration before deploying; keep secrets in Fly. The image runs as a nonroot
user, and Fly configuration keeps one machine running. Deployment, remote creation,
release publication, hosted database setup, real App/OAuth callbacks and live
messages require the corresponding accounts/authorization and staging validation.
Human-approval writes and enforcement remain unimplemented pending that product
choice. Container execution, provider rate-limit behavior and backup/restore/key
rotation must be exercised in the chosen hosting environment before rollout.

Provider API references: [GitHub OIDC](https://docs.github.com/en/actions/reference/security/oidc),
[GitHub App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation),
[Slack OAuth](https://docs.slack.dev/authentication/installing-with-oauth/),
[WorkOS authentication](https://workos.com/docs/reference/authkit/authentication).
