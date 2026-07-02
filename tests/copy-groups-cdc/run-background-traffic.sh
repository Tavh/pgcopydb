#! /bin/bash

set -e

# Phase 1: a bounded burst of mixed-group, cross-group transactions, run
# concurrently with the start of the clone --follow --copy-groups 2 copy phase.
# Each transaction touches tables in BOTH copy groups (customers in group 1,
# orders in group 0) and creates a cross-group parent/child pair, so the
# common-LSN barrier has to converge both groups before the orders -> customers
# FK can be validated.
#
# The burst is short (and the orders table is bulk-seeded so its COPY outlasts
# it), so every one of these transactions is committed BEFORE the parent picks
# the common cutover LSN (after both group copies finish). They are therefore
# all <= LSN_C and all applied, so the target ends up equal to the source.

rounds=${1:-12}

for i in $(seq ${rounds})
do
    psql -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" <<'SQL'
begin;
with c as (
    insert into customers(name, notes)
    values ('live ' || clock_timestamp()::text, repeat('y', 100))
    returning id
)
insert into orders(customer_id, amount, payload)
select c.id, (random() * 500)::numeric(12,2), repeat('p', 200)
  from c, generate_series(1, 1 + (random() * 5)::int);

-- also update / delete existing rows to exercise UPDATE/DELETE apply
update orders set amount = amount + 1
 where id in (select id from orders order by id desc limit 3);
commit;
SQL

    sleep 0.1
done

echo "background data traffic complete after ${rounds} rounds"
