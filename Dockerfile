ARG POSTGIS_IMAGE_TAG="11-3.2-alpine"
FROM postgis/postgis:${POSTGIS_IMAGE_TAG}

LABEL maintainer="info@redmic.es"

ARG PG_CRON_VERSION="1.4.1" \
	PG_PARTMAN_VERSION="4.6.0" \
	BUILD_BASE_VERSION="0.5-r2" \
	CLANG_VERSION="12.0.1-r1" \
	LLVM_VERSION="12.0.1-r0" \
	CA_CERTIFICATES_VERSION="20211220-r0" \
	OPENSSL_VERSION="1.1.1l-r8" \
	TAR_VERSION="1.34-r0"

# hadolint ignore=DL3003
RUN apk add --no-cache --virtual .build-deps \
		build-base="${BUILD_BASE_VERSION}" \
		clang="${CLANG_VERSION}" \
		llvm="${LLVM_VERSION}" \
		ca-certificates="${CA_CERTIFICATES_VERSION}" \
		openssl="${OPENSSL_VERSION}" \
		tar="${TAR_VERSION}" && \
# install pg_cron
	wget -q -O pg_cron.tar.gz "https://github.com/citusdata/pg_cron/archive/v${PG_CRON_VERSION}.tar.gz" && \
	tar -xzf pg_cron.tar.gz && \
	cd pg_cron-* && \
	sed -i.bak -e 's/-Werror//g' Makefile && \
	sed -i.bak -e 's/-Wno-implicit-fallthrough//g' Makefile && \
	make && \
	make install && \
	cd .. ; \
# install pg_partman
	wget -q -O pg_partman.tar.gz "https://github.com/pgpartman/pg_partman/archive/v${PG_PARTMAN_VERSION}.tar.gz" && \
	tar -xzf pg_partman.tar.gz && \
	cd pg_partman-* && \
	make && \
	make NO_BGW=1 install && \
	cd .. ; \
# clean
	rm -rf pg_cron* pg_partman* && \
	apk del .build-deps

COPY docker-entrypoint-initdb.d /docker-entrypoint-initdb.d
