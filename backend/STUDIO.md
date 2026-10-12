# CodeTurtle execution tracing

CodeTurtle uses the pinned BAML runtime's BTEL recorder. Data stays on the service
machine. By default there is no Boundary upload and no new public tracing endpoint.

## Run and inspect

From the repository root:

```sh
sh backend/start.sh                       # real service, normal credentials required
sh backend/start.sh studio_probe          # safe probe, no credentials or providers
sh backend/traces.sh                      # latest completed spans
sh backend/traces.sh --schema --table spans
sh backend/traces.sh --format json \
  "SELECT span_name, status, duration, context_metadata FROM spans ORDER BY start_time DESC LIMIT 50"
```

In the default `CODETURTLE_TRACE_MODE=local`, the launcher forces `BOUNDARY_API_KEY=local` and clears cloud endpoint/project
variables, including when credentials are inherited from the host. Recording
uses `BAML_TELEMETRY=medium` unless explicitly overridden; `off` disables it.
Explicit spans mark request, database and provider boundaries with `service` and
`stage` metadata. Their arguments, return values and error values are not captured.
This is not a blanket redaction guarantee for the runtime's own network/error
recording: keep all trace storage operator-only, especially with real credentials.
The runtime also provides profiler aggregates and source metadata.

Each project's `.baml/btel/` contains recordings, CAS blobs and `query.sqlite`.
The SQLite index is derived from recordings, not an application schema migration.
The entire `.baml/` directory remains ignored by Git. No SQL migration is added.
The query helper limits results to 200 rows and SQL execution to five seconds;
initial indexing is additional work, so large stores can take longer.

## Same-machine Fly storage

The Docker image starts `backend/start.sh` as uid 10001. `backend/fly.toml` mounts
`codeturtle_traces` at `/app/backend/.baml`, retaining traces across deployments.
Before deploying this configuration:

1. Create a `codeturtle_traces` Fly volume in the app's region (`ord`).
2. Initialize that volume's root with owner `10001:10001` and permissions `0700`
   using an operator/root maintenance machine with the volume attached. Stop the
   maintenance machine before attaching the volume to the CodeTurtle machine.
3. Deploy with one service machine attached to the volume. A missing or unwritable
   volume is a rollout prerequisite, not something the nonroot service can repair.
4. Through an authenticated Fly SSH console, run
   `sh /app/backend/traces.sh` or the probe above to verify recording/querying.

Do not publish the recording directory through CodeTurtle's static file routes.
For an experiment, monitor disk use (`du -sh /app/backend/.baml/btel`). There is no
retention worker yet. Stop the service before clearing a whole recording store;
keep recordings and their shared CAS together rather than deleting arbitrary CAS
blobs. Provisioning, deployment and volume creation have not been performed by
this scaffold. The existing machine does not change until deployment.

## Which Studio features this exercises

Local recording/querying supports spans, timing, context metadata, source lookup
and the profiler. The local BAML playground can inspect the project's recordings:
run `baml --agent-skill-check off playground --no-open` from `backend/` on a
trusted development host. It is a developer tool, not a public production route.

The new **BCS Studio web application** is a separate stack. Recent upstream work:

- [BAML #4986](https://github.com/BoundaryML/baml/pull/4986): local SQL queries and
  playground execution inspection.
- [BAML #5084](https://github.com/BoundaryML/baml/pull/5084): runtime delivery to a
  configured data plane.
- [BAML #5199](https://github.com/BoundaryML/baml/pull/5199): proposed documentation
  for local/cloud trace selection and dashboard queries (open when inspected).
- [BCS #128](https://github.com/BoundaryML/bcs/pull/128): Studio onboarding and
  local data-plane lifecycle fixes.

Full Studio requires the BCS control plane, Postgres, Studio, and an Alien-managed
local data plane (gateway, coordinator and workers). Its local bucket lives under
`data-plane/.alien/`; it does not directly open this app's BTEL directory. Follow
[BCS local development](https://github.com/BoundaryML/bcs/blob/main/docs/development.md)
in a separate checkout, with isolated Studio auth. Do not reuse or modify the
CodeTurtle WorkOS configuration. Use the BAML revision pinned by BCS for that
experiment; this change does not upgrade CodeTurtle's runtime.

Once that stack is provisioned on the same host, select the opt-in gateway mode:

```sh
export CODETURTLE_TRACE_MODE=studio
export CODETURTLE_STUDIO_URL=http://127.0.0.1:YOUR_GATEWAY_PORT
# Set BOUNDARY_API_KEY securely to that local environment's write-capable key.
sh backend/start.sh studio_probe
# Confirm the probe in Studio Query before starting the real service:
sh backend/start.sh
```

The launcher rejects non-loopback endpoints and a missing/local key. It sets both
`BOUNDARY_URL` (the earlier runtime spelling) and `BOUNDARY_API_URL` for the local
gateway. The gateway's generated upload URLs must also be reachable from the
service process; loopback means the same network namespace, not another container.
Queries in `traces.sh` always read local files; in gateway mode use Studio Query
instead. Gateway mode is not a local-file backup or a dual-write mode.

This scaffold does not provision BCS or claim full Studio ingestion/dashboard
compatibility has been tested. The current 1 GB Fly machine is not qualified for
the additional BCS stack. Keep the default local-file mode until the Studio stack
and a matching runtime have passed an end-to-end probe.
