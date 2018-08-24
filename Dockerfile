FROM mdillon/postgis:10-alpine

COPY /scripts/ /docker-entrypoint-initdb.d/
