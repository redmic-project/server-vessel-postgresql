FROM mdillon/postgis:11-alpine

LABEL maintainer="info@redmic.es"

ENV PG_CRON_VERSION="1.1.4" \
	PG_PARTMAN_VERSION="4.0.0" \
	POSTGRES_WORK_MEM="1GB"

RUN apk add --no-cache --virtual \
		.build-deps \
		build-base \
		ca-certificates \
		openssl \
		tar && \
	wget -O /pg_cron.tgz https://github.com/citusdata/pg_cron/archive/v${PG_CRON_VERSION}.tar.gz && \
	tar xvzf /pg_cron.tgz && \
	cd pg_cron-${PG_CRON_VERSION} && \
	sed -i.bak -e 's/-Werror//g' Makefile && \
	sed -i.bak -e 's/-Wno-implicit-fallthrough//g' Makefile && \
	make && \
	make install && \
	cd .. && \
	rm -rf pg_cron.tgz pg_cron-* && \
	wget -O /pg_partman.tgz https://github.com/pgpartman/pg_partman/archive/v${PG_PARTMAN_VERSION}.tar.gz && \
	tar xvzf /pg_partman.tgz && \
	cd pg_partman-${PG_PARTMAN_VERSION} && \
	make && \
	make NO_BGW=1 install && \
	cd .. && \
	rm -rf pg_partman.tgz pg_partman-* && \
	echo "shared_preload_libraries='pg_cron'" >> /usr/local/share/postgresql/postgresql.conf.sample && \
	echo "checkpoint_timeout = 30min" >> /usr/local/share/postgresql/postgresql.conf.sample && \
	echo "max_wal_size = 2GB" >> /usr/local/share/postgresql/postgresql.conf.sample && \
	mv /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint-origin.sh

COPY rootfs /
