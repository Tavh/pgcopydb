#!/bin/bash

set -x
set -e

# Disable pager for psql to avoid hanging in non-interactive environments
export PAGER=cat

# make sure source and target databases are ready
pgcopydb ping

# Setup source database with multiple schemas and data
psql -o /tmp/ddl.out -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/ddl.sql

# create the replication slot that captures all the changes
coproc ( pgcopydb snapshot --follow )

sleep 1

# now setup the replication origin (target) and the pgcopydb.sentinel (source)
pgcopydb stream setup

# pgcopydb clone uses the environment variables
pgcopydb clone --filters /usr/src/pgcopydb/filters.ini

kill -TERM ${COPROC_PID}
wait ${COPROC_PID}

# now that the copying is done, inject CDC changes to BOTH included and excluded schemas
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql

# grab the current LSN, it's going to be our streaming end position
lsn=`psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_current_wal_lsn()'`

# prefetch the changes captured in our replication slot
pgcopydb stream prefetch --resume --endpos "${lsn}" -vv

# test_decoding emits changes for every source table. Filtered relations must
# be removed during transform, before their SQL can reach the apply process.
cdc_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/pgcopydb"

if ! ls "${cdc_dir}"/*.sql >/dev/null 2>&1
then
    echo "FAIL: no transformed CDC SQL files found in ${cdc_dir}"
    exit 1
fi

if grep -nE 'cron|excluded_schema' "${cdc_dir}"/*.sql
then
    echo "FAIL: filtered table found in transformed CDC SQL"
    exit 1
fi

if ! grep -q '^-- SWITCH WAL ' "${cdc_dir}"/*.sql
then
    echo "FAIL: regression did not cross a WAL boundary"
    exit 1
fi

if ! awk '
    /^BEGIN; -- / { depth++ }
    /^COMMIT; -- / { depth--; if (depth < 0) exit 1 }
    END { if (depth != 0) exit 1 }
' "${cdc_dir}"/*.sql
then
    echo "FAIL: transformed CDC SQL has unbalanced transaction framing"
    exit 1
fi

# now allow for replaying/catching-up changes
pgcopydb stream sentinel set apply

# now apply the CDC changes to the target database
# (filters are already stored in the catalog from the clone step)
pgcopydb stream catchup --resume --endpos "${lsn}" -vv

# Verify that excluded schemas do not exist and included data is correct
psql -d ${PGCOPYDB_TARGET_PGURI} -f /usr/src/pgcopydb/verify.sql

assert_query()
{
    expected="$1"
    query="$2"
    description="$3"
    actual="$(psql -Atq -d ${PGCOPYDB_TARGET_PGURI} -c "${query}")"

    if [ "${actual}" != "${expected}" ]
    then
        echo "FAIL: ${description}: expected ${expected}, got ${actual}"
        exit 1
    fi
}

assert_query 5 "select count(*) from public.users" "included INSERTs"
assert_query alice.new@example.com \
    "select email from public.users where username = 'alice'" \
    "included UPDATE"
assert_query charlie.boundary@example.com \
    "select email from public.users where username = 'charlie'" \
    "included UPDATE after WAL switch"
assert_query 2 "select count(*) from public.orders" "included INSERT/DELETE"
assert_query 0 \
    "select count(*) from information_schema.schemata where schema_name = 'cron'" \
    "excluded cron schema"
assert_query 0 \
    "select count(*) from information_schema.schemata where schema_name = 'excluded_schema'" \
    "excluded test schema"

# cleanup
pgcopydb stream cleanup
