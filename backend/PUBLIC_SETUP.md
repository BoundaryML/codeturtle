# Running from a public clone

The policy engine, frontend build, cryptographic helpers and source tests run
without Boundary credentials. `.github/workflows/quality.yml` runs those checks
on pull requests with read-only repository access and no service secrets.
Use the commands in the root README locally. The BAML runtime is pinned and
checksum verified. Its release asset must be publicly accessible before this
repository is advertised as a reproducible public example.

The complete hosted app is **not yet independently reproducible**. It requires a
separate, private database provisioning handoff. We intentionally do not publish
that schema here. A public clone cannot create the database solely from this repo.
Source CI does not stand in for database integration tests.

An operator must provision a dedicated Supabase project using the base schema,
review-signoff update, workspace performance update and GitHub token-refresh
update, in that order. All `ct_*` RPCs are service-role-only; browser clients
never receive the service-role credential. Configure the isolated GitHub App and
WorkOS application and the environment variables in `backend/README.md`.

For integration tests, provide the private handoffs through local paths:

```sh
CODETURTLE_TEST_SQL=/private/operator-handoff.md \
CODETURTLE_TEST_REVIEW_SQL=/private/review-signoffs.md \
CODETURTLE_TEST_REFRESH_SQL=/private/github-refresh.md \
  backend/.venv/bin/python -m unittest discover -s backend/tests -p test_service.py -v
```

Tests create and remove a disposable local PostgreSQL database and mock provider
requests. They must not use a production database. PostgreSQL 17 binaries are
selected with `PG_BIN`. Do not supply private handoffs or credentials to fork PRs.

To make the full app independently reproducible, a distributable database setup
is still required. That is a release blocker pending a decision to publish a
sanitized schema/provisioner; it is not hidden by skipping tests.

## GitHub token refresh rollout

Apply the private refresh update before deploying this code. Newly connected
GitHub accounts store both access and refresh tokens in authenticated encryption.
Existing access-only tokens require one reconnection. Concurrent refresh attempts
are serialized in the database. An uncertain provider response requires reconnecting
rather than replaying a potentially consumed refresh token. No WorkOS settings
or unrelated applications are modified.

## Review workflow update

Merge the generated workflow changes and verify setup again to authorize the
new workflow blob. The `codeturtle-refresh` label starts a replacement evaluation
when the base branch advances. It does not reuse an old Actions event. Native
GitHub reviewer requests require the existing Pull requests write permission.
The app skips the PR author, draft PRs and already requested/reviewed users.
