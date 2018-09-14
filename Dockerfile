FROM mdillon/postgis:10-alpine

LABEL maintainer="info@redmic.es"

COPY /scripts/ /docker-entrypoint-initdb.d/
