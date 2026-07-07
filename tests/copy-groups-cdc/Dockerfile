FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./ddl.sql ddl.sql
COPY ./seed.sql seed.sql
COPY ./run-background-traffic.sh run-background-traffic.sh
COPY ./wal-nudger.sh wal-nudger.sh

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
