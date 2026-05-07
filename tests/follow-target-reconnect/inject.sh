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
# Simulate a target database connection drop. This terminates all active
# connections to the target database (except our own psql session), causing
# pgcopydb's replay process to receive an SSL EOF. The retry logic in
# follow_main_loop should detect the failure, back off, and reconnect.
#
psql -d ${PGCOPYDB_TARGET_PGURI} \
    -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE pid != pg_backend_pid()"

# Allow time for pgcopydb to detect the failure and complete its first retry
# backoff (FOLLOW_RETRY_BASE_SLEEP_SECS = 5s) plus reconnect overhead.
sleep 15

#
# Inject 2 more rounds of DML after the reconnect to verify that changes
# applied after the blip are also captured and replayed correctly.
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
