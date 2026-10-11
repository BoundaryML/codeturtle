# CodeTurtle

Slow down! Read code.

CodeTurtle evaluates repository policies locally and publishes authenticated CI reports through a BAML service.

```text
frontend/  TypeScript UI
backend/   BAML HTTP service, auth, storage and provider integrations
           crypto.py: Python RS256 signing and verification helper
           tests/: service and crypto integration tests
cli/       BAML policy engine, Python Git adapter and reporting transport,
           fixtures, package metadata and GitHub Action
```

[CLI usage and policy reference](cli/README.md) · [Service configuration and deployment](backend/README.md)

[BAML execution tracing and Studio setup](backend/STUDIO.md): start the service
with `sh backend/start.sh`, then inspect same-machine recordings with
`sh backend/traces.sh`.

Install Python 3.10+, Git and BAML **0.20.2-nightly.20261004.a**, then:

```sh
python3 -m pip install ./cli
codeturtle help
npm --prefix frontend ci
npm --prefix frontend run build
```

## Test CodeTurtle on this repository

The setup owner and initial reviewer is [@ATX24](https://github.com/ATX24).
The root [CODETURTLE.md](CODETURTLE.md) assigns every changed file to `@ATX24`.

The [CodeTurtle workflow](.github/workflows/codeturtle.yml) is part of this
repository's [GitHub Actions suite](https://github.com/BoundaryML/codeturtle/actions/workflows/codeturtle.yml).
It runs when a pull request is opened, updated, reopened, edited, or marked ready
for review. It uses the policy from the PR's base revision and a pinned CLI.

To test the complete review flow:

1. Open a small PR against `main` in `BoundaryML/codeturtle` and wait for the
   **CodeTurtle** Actions run to finish.
2. Find the bot comment with the reviewer table. The `@ATX24` row should list the
   changed parts and a personal review link.
3. Open that link, sign in to [CodeTurtle](https://boundary-codeturtle-staging.fly.dev/),
   and use the linked GitHub identity `ATX24`.
4. Inspect each assigned file's diff. Choose **Approve** or **Reject** for every
   file; a rejection requires a reason. Optional inline comments stay private
   until submission.
5. Click **Submit review**, reload the review page, and confirm the published
   decisions persist and the PR comment updates your progress.

This setup PR provides a small documentation diff for that manual test. Review
submission is performed by `@ATX24`; it does not submit a native GitHub approval
or merge the PR.

The GitHub Action lives at `owner/repo/cli@full-commit-SHA`.
Build the service image from this directory using `backend/Dockerfile`.
The backend reads the shared report model from `cli/baml_src/models.baml`.

```sh
baml --agent-skill-check off test --directory cli
python3 -m unittest discover -s cli -p test_reporting.py -v
baml --agent-skill-check off test --directory backend
backend/.venv/bin/python -m unittest discover -s backend/tests -p test_crypto.py -v
CODETURTLE_TEST_SQL=/absolute/path/to/operator-handoff.md \
CODETURTLE_TEST_REVIEW_SQL=/absolute/path/to/codeturtle-review-signoffs.md \
CODETURTLE_TEST_PERFORMANCE_SQL=/absolute/path/to/codeturtle-workspace-performance-private.sql \
  backend/.venv/bin/python -m unittest discover -s backend/tests -p test_service.py -v
npm --prefix frontend run build
```

The service integration tests use a disposable local PostgreSQL cluster and mocked providers.
Secrets belong in the ignored `backend/.env` or deployment secret store.

Create `CODETURTLE.md` at the reviewed repository root; see the [policy syntax](cli/README.md).
The PR comment groups requirements by reviewer and links to personal review pages.
Reviewers sign in with the isolated WorkOS AuthKit, link their own GitHub identity,
and open the original CodeTurtle review workspace. Each owned file gets an explicit
Approve or Reject decision; rejections require a reason. Decisions and inline
comments remain private drafts until Submit review publishes them atomically.
Any/All ownership rules accumulate. Changed files need new decisions; unchanged
files retain approvals. Rejections survive new revisions until cleared by their
reviewer or a repository administrator with an audited reason. Overrides do not
supply approvals.

The frontend ports the existing `tools/shep` website to TypeScript, preserving its
CSS, fonts, turtle artwork, Monaco split/unified diff editor, file tree, comment
controls, per-file decisions and review progress. The demonstration identities,
fictional PR and simulated-commit controls are replaced by authenticated API data.
The ownership tab shows evaluated rule provenance rather than fictional policy.

The CLI evaluator is the original `tools/codeturtle` engine: `contracts.baml`,
`engine.baml`, `help.baml`, `lint.baml`, `main.baml`, `models.baml` and
`ownership.baml` are byte-identical to the source port. Changes surround it:
independent packaging/runtime pinning, trusted Git input, root `CODETURTLE.md`
loading, and authenticated CI reporting.

These are CodeTurtle decisions and comments stored in the database. They do not
submit native GitHub approvals or enforce branch protection. Slack remains
unconfigured. Binary files, files over 1 MB and files outside GitHub's comparison
response limit provide a GitHub fallback instead of an incomplete inline diff.
Team owners require GitHub API access to verify team membership; individual
GitHub handles work without that additional permission.

The additive reviewer database migration must be applied before deploying this
workspace. It is supplied separately as the operator SQL handoff. Deployment and
publishing the updated GitHub Action are separate from local build/test success.

## Public release status

See [public setup and remaining release prerequisites](backend/PUBLIC_SETUP.md).
Source CI requires no app credentials. The full app still requires the private
database handoff; it is not independently reproducible from a public clone yet.
The `heal/` experiment cannot execute candidates until isolated testing is implemented.
