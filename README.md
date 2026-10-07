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

Install Python 3.10+, Git and BAML **0.20.2-nightly.20261004.a**, then:

```sh
python3 -m pip install ./cli
codeturtle help
npm --prefix frontend ci
npm --prefix frontend run build
```

The GitHub Action lives at `owner/repo/cli@full-commit-SHA`.
Build the service image from this directory using `backend/Dockerfile`.
The backend reads the shared report model from `cli/baml_src/models.baml`.

```sh
baml --agent-skill-check off test --directory cli
python3 -m unittest discover -s cli -p test_reporting.py -v
baml --agent-skill-check off test --directory backend
backend/.venv/bin/python -m unittest discover -s backend/tests -p test_crypto.py -v
CODETURTLE_TEST_SQL=/absolute/path/to/operator-handoff.md \
  backend/.venv/bin/python -m unittest discover -s backend/tests -p test_service.py -v
npm --prefix frontend run build
```

The service integration tests use a disposable local PostgreSQL cluster and mocked providers.
Secrets belong in the ignored `backend/.env` or deployment secret store.
