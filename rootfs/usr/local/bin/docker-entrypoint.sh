#!/bin/sh

echo "cron.database_name='${POSTGRES_DB}'" >> /usr/local/share/postgresql/postgresql.conf.sample

exec docker-entrypoint-origin.sh "$@"
