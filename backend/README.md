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
sh start.sh
```

Set these **CodeTurtle-specific** environment variables:

The launcher records execution locally for Studio experiments. See
[execution tracing](STUDIO.md) for queries, volume provisioning, and the separate
full Studio server requirements. Set `BAML_TELEMETRY=off` to disable recording.

| Variable | Value |
| --- | --- |
| `CODETURTLE_API_URL` | Public HTTPS origin, also the OIDC audience |
| `CODETURTLE_SUPABASE_URL` | Dedicated Supabase HTTPS origin |
| `CODETURTLE_SUPABASE_KEY` | Legacy service-role JWT, server only |
| `CODETURTLE_GITHUB_APP_ID`, `CODETURTLE_GITHUB_BOT_ID` | App and numeric bot user IDs |
| `CODETURTLE_GITHUB_PRIVATE_KEY`, `CODETURTLE_GITHUB_WEBHOOK_SECRET` | App private key and signing secret |
| `CODETURTLE_GITHUB_CLIENT_ID`, `CODETURTLE_GITHUB_CLIENT_SECRET` | App user OAuth credentials |
| `CODETURTLE_WORKOS_ORGANIZATION_ID` | Optional organization to select during AuthKit login and require in the callback; set to Boundary for this staging deployment |
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
CODETURTLE_TEST_REVIEW_SQL=/absolute/path/to/codeturtle-review-signoffs.md \
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
CodeTurtle reviewer sign-offs require the separate additive reviewer SQL handoff
before deploying this version. GitHub approval submission and merge enforcement
are not implemented. Container execution, provider rate-limit behavior and backup/restore/key
rotation must be exercised in the chosen hosting environment before rollout.

Provider API references: [GitHub OIDC](https://docs.github.com/en/actions/reference/security/oidc),
[GitHub App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation),
[Slack OAuth](https://docs.slack.dev/authentication/installing-with-oauth/),
[WorkOS authentication](https://workos.com/docs/reference/authkit/authentication).

### Personal reviews

Apply `codeturtle-review-signoffs.md` from the operator handoff before deployment.
It adds private reviewer decisions, read-only reviewer linking, and outbox revision
tracking so concurrent sign-offs cannot lose comment updates. No startup migration runs.

Personal links preserve their destination through WorkOS and GitHub login. Repository
readers can link themselves to an existing enrollment without receiving setup/admin
rights. Mark/reopen actions require a current session, CSRF, live repository access,
verified GitHub identity and a matching assigned owner. GitHub head/base revisions
and database supersession are checked before every write. The URL's reviewer label
is only a view filter, never an identity or permission.

Individual `@login` rules work with the existing App permissions. Team rules use
live GitHub team membership checks and need organization Members read permission;
unverifiable membership never grants sign-off rights. Team rows represent a group
owner; any verified member can satisfy that owner's slot. A reviewer can only remove
their own decision. Diffs use immutable merge-base/head commits; binary/large or
GitHub-truncated comparisons link back to the PR. CodeTurtle submits a native GitHub approval after all required file sign-offs are satisfied.

### Refresh a stale review

When the base branch advances, old reviews remain blocked. A maintainer can apply the `codeturtle-refresh` label to the PR (remove and re-add it if already present) to create a new run against the current base and head. This uses the existing trusted `pull_request_target` path; rerunning an old Actions run retains its old event and is not sufficient. Existing installations must merge the updated workflow and verify setup again to trust its new blob. Refresh is explicit, not automatic on every base push.

### Native GitHub review

The GitHub delivery worker posts a review as the CodeTurtle app. It starts with a
non-approving comment and submits `APPROVE` for the report's exact head only when
all nonempty file requirements are satisfied by persisted CodeTurtle sign-offs.
`Any` means one eligible owner per requirement; `All` means every listed owner.
Incomplete evaluation, policy errors, setup failures and draft PRs cannot approve.
Native GitHub approvals alone do not create CodeTurtle per-file sign-offs.

Delivery retries reconcile reviews by bot identity and a run/head/base marker.
Later rejections dismiss the approval on the next delivery. Signed pull-request
webhooks compare the live head/base and dismiss obsolete approvals (including a
conversion to draft). Base changes need a pull-request notification or a new
report delivery to trigger reconciliation. GitHub's stale-approval dismissal
setting is recommended as an independent safeguard for new commits.
This review appears in GitHub's Reviewers list; it does not change branch rules.
