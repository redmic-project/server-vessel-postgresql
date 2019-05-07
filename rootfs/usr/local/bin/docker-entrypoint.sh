#!/bin/sh

echo "work_mem=${POSTGRES_WORK_MEM}" >> /usr/local/share/postgresql/postgresql.conf.sample
echo "cron.database_name='${POSTGRES_DB}'" >> /usr/local/share/postgresql/postgresql.conf.sample

exec docker-entrypoint-origin.sh "$@"
