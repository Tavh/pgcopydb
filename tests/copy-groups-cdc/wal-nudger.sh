#! /bin/bash

set -e

# WAL nudger: once the bounded data traffic is done and the parent has picked
# the common cutover LSN, the source is otherwise idle. With an idle source the
# replication slots never flush THROUGH the endpos, so the receive/transform
# never finalize the SQL file for the segment that contains LSN_C, and apply
# blocks waiting for it.
#
# Force WAL to advance and rotate WITHOUT writing any table data: pg_switch_wal
# emits only a SWITCH record (not data), so it lets the slots flush past LSN_C
# and the segment rotate (so transform emits its SQL up to endpos) while leaving
# the migrated data unchanged. This is the same trick the standard follow tests
# use via the inject service. Runs until killed by the caller.

while true
do
    psql -At -d "${PGCOPYDB_SOURCE_PGURI}" -c "select pg_switch_wal()" \
        >/dev/null 2>&1 || true
    sleep 0.5
done
