#!/usr/bin/env bash
# Verify the RevMap migrations and test suites against a real PostgreSQL.
#
# The container is created fresh and destroyed at the end: restarting a postgis
# container re-runs its init scripts, which fail against a data directory that
# has already been initialised. One session, no restarts.
#
#   ./tool/verify_db.sh
#
# Needs Docker. Nothing here touches the hosted project.
set -uo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
NAME=revamp-verify
DB=revamp

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "==> starting PostgreSQL 16 + PostGIS"
# The postgis image intermittently fails its own initdb script on a fresh volume
# ("type geometry does not exist" while creating postgis_topology), which kills
# the container before any of our SQL runs. That is an image bug, not a schema
# problem, so start it again until the server is genuinely up.
started=0
for attempt in 1 2 3 4; do
  cleanup
  docker run -d --name "$NAME" \
    -e POSTGRES_PASSWORD=revamptest -e POSTGRES_DB="$DB" \
    postgis/postgis:16-3.4 >/dev/null 2>&1
  for _ in $(seq 1 45); do
    if docker exec "$NAME" pg_isready -U postgres -d "$DB" >/dev/null 2>&1; then
      # Confirm the postgis init finished rather than erroring out.
      if docker exec "$NAME" psql -U postgres -d "$DB" -tAc \
           "select 1 from pg_extension where extname='postgis'" 2>/dev/null | grep -q 1; then
        started=1; break
      fi
    fi
    docker inspect "$NAME" >/dev/null 2>&1 || break   # container died during init
    sleep 1
  done
  [ "$started" -eq 1 ] && break
  echo "    init attempt $attempt failed, retrying"
done
[ "$started" -eq 1 ] || { echo "could not start a healthy container"; exit 1; }

psql_run() { docker exec -i "$NAME" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 "$@"; }

# Supabase provides auth.users and auth.uid(); the tests need them to exist.
psql_run -q < "$PROJ/.toolchain/auth_stub.sql" >/dev/null 2>&1

echo "==> applying migrations"
for f in 0001_init 0002_trust_and_rls 0003_seed 0004_owner_flow; do
  if out=$(psql_run -q -f - < "$PROJ/supabase/migrations/$f.sql" 2>&1); then
    echo "    ok    $f"
  else
    echo "    FAIL  $f"
    echo "$out" | grep -E "ERROR|FATAL" | head -3 | sed 's/^/          /'
    exit 1
  fi
done

echo "==> seeded state"
psql_run -tAc "select '    ' || (select count(*) from places) || ' places, '
                        || (select count(*) from place_seed_stats) || ' display rows, '
                        || (select count(*) from trust_config) || ' config rows';"

total_fail=0
for t in 001_weight_formula 002_security 003_owner_flow; do
  echo
  echo "==> $t"
  out=$(psql_run -f - < "$PROJ/supabase/tests/$t.sql" 2>&1)
  echo "$out" | sed 's/^NOTICE:  //; s/^ERROR:  //' \
    | grep -E "^(PASS|FAIL|WARN)" | sed 's/^/    /'
  fails=$(echo "$out" | grep -cE "^(NOTICE|ERROR):? *FAIL|^ERROR:" || true)
  echo "$out" | grep -E "^ERROR:" | head -3 | sed 's/^/    /'
  total_fail=$((total_fail + fails))
done

echo
if [ "$total_fail" -eq 0 ]; then
  echo "==> no failures"
else
  echo "==> $total_fail failure(s)"
fi
