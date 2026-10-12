#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# Local files by default; Studio mode must explicitly name a same-host gateway.
case "${CODETURTLE_TRACE_MODE:-local}" in
  local)
    export BOUNDARY_API_KEY=local
    unset BOUNDARY_API_URL BOUNDARY_URL BOUNDARY_PROJECT ;;
  studio)
    if ! printf '%s\n' "${CODETURTLE_STUDIO_URL:-}" | grep -Eq '^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]{1,5}/?$'; then
      echo "Studio mode requires CODETURTLE_STUDIO_URL=http://127.0.0.1:<port> (same host)." >&2
      exit 1
    fi
    if [ -z "${BOUNDARY_API_KEY:-}" ] || [ "$BOUNDARY_API_KEY" = local ]; then
      echo "Studio mode requires the local Studio environment's BOUNDARY_API_KEY." >&2
      exit 1
    fi
    # Oct 2 runtime used BOUNDARY_URL; newer BCS runtimes use BOUNDARY_API_URL.
    export BOUNDARY_API_URL="$CODETURTLE_STUDIO_URL"
    export BOUNDARY_URL="$CODETURTLE_STUDIO_URL"
    unset BOUNDARY_PROJECT ;;
  *) echo "CODETURTLE_TRACE_MODE must be local or studio." >&2; exit 1 ;;
esac
export BAML_TELEMETRY="${BAML_TELEMETRY:-medium}"
umask 077
if [ "$BAML_TELEMETRY" != off ]; then
  mkdir -p .baml/btel
  if [ ! -w .baml/btel ]; then
    echo "Trace storage .baml/btel must be writable by the service user." >&2
    exit 1
  fi
fi
if [ "$#" = 0 ]; then
  set -- main -- --addr 0.0.0.0:8080
fi
exec baml --agent-skill-check off run "$@"
