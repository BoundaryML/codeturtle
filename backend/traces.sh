#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export BOUNDARY_API_KEY=local
unset BOUNDARY_API_URL BOUNDARY_URL BOUNDARY_PROJECT
umask 077
if [ "$#" = 0 ]; then
  set -- "SELECT span_name, status, duration, context_metadata FROM spans ORDER BY start_time DESC LIMIT 50"
fi
exec baml --agent-skill-check off query --from . --max-rows 200 --max-wall 5s "$@"
