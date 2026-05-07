#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

pgcopydb ping

#
# Only start injecting DML traffic on the source database when the pagila
# schema and base data set has been deployed already. Our proxy to know that
# that's the case is the existence of the pgcopydb.sentinel table on the
# source database.
#
dbfile=${TMPDIR}/pgcopydb/schema/source.db

until [ -s ${dbfile} ]
do
    sleep 1
done

#
# Inject 3 rounds of DML with WAL switches to generate CDC traffic before
# simulating the connection failure.
#
for i in `seq 3`
do
    psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql
    sleep 1

    psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql
    sleep 1

    psql -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_switch_wal()'
    sleep 1
done

#
# Wait for CDC follow mode to be actively streaming to the target before
# simulating the failure. A non-zero flush_lsn means pgcopydb has begun
# applying changes to the target.
#
flushlsn="0/0"

until [ "${flushlsn}" != "0/0" ]
do
    flushlsn=$(pgcopydb stream sentinel get --flush-lsn 2>/dev/null || echo "0/0")
    sleep 2
done

#
# Simulate a target database outage by stopping the target container entirely.
# This causes pgcopydb's apply process to receive connection-refused errors on
# the next SQL execution, which propagates up to followDB() returning false,
# triggering the retry logic in follow_main_loop.
#
TARGET=$(docker ps -q --filter "label=com.docker.compose.service=target" | head -1)

if [ -z "${TARGET}" ]
then
    echo "ERROR: could not find target container via docker socket"
    exit 1
fi

docker stop "${TARGET}"

# Wait long enough for pgcopydb to detect the failure and begin its first
# retry backoff (FOLLOW_RETRY_BASE_SLEEP_SECS = 5s).
sleep 15

docker start "${TARGET}"

# Wait for target to accept connections again before injecting more DML.
until psql -d ${PGCOPYDB_TARGET_PGURI} -c "SELECT 1" >/dev/null 2>&1
do
    sleep 1
done

#
# Inject 2 more rounds of DML after the reconnect to verify that changes
# applied after the outage are also captured and replayed correctly.
#
for i in `seq 2`
do
    psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql
    sleep 1

    psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql
    sleep 1

    psql -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_switch_wal()'
    sleep 1
done

# grab the current LSN, it's going to be our streaming end position
lsn=`psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_current_wal_flush_lsn()'`

pgcopydb stream sentinel set endpos --current --debug
pgcopydb stream sentinel get

endpos=`pgcopydb stream sentinel get --endpos 2>/dev/null`

if [ ${endpos} = "0/0" ]
then
    echo "expected ${lsn} endpos, found ${endpos}"
    exit 1
fi

#
# Because we're using docker-compose --abort-on-container-exit make sure
# that the other process in the pgcopydb service is done before exiting
# here.
#
flushlsn="0/0"

while [ ${flushlsn} \< ${endpos} ]
do
    flushlsn=`pgcopydb stream sentinel get --flush-lsn 2>/dev/null`
    sleep 1
done

#
# Still give some time to the pgcopydb service to finish its processing,
# with the cleanup and all.
#
sleep 10
