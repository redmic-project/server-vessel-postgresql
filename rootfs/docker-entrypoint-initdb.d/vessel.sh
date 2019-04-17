#!/bin/sh

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE SCHEMA IF NOT EXISTS ais;

	-- Install extensions
	CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
	CREATE EXTENSION IF NOT EXISTS pg_cron;
	CREATE SCHEMA IF NOT EXISTS partman;
	CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

	CREATE ROLE partman WITH LOGIN;
	GRANT ALL ON ALL TABLES IN SCHEMA partman TO partman;
	GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA partman TO partman;
	GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA partman TO partman;
	GRANT ALL ON SCHEMA ais TO partman;

	-- Importante callSign y navStat en camelcase para coincidir con el esquema

	CREATE TABLE ais.location
	(
	  uuid uuid NOT NULL DEFAULT uuid_generate_v4(),
	  mmsi integer NOT NULL,
	  shape geometry(Point,4326),
	  longitude double precision NOT NULL,
	  latitude double precision NOT NULL,
	  tstamp timestamp without time zone NOT NULL,
	  inserted timestamp with time zone NOT NULL DEFAULT now(),
	  cog double precision,
	  sog double precision,
	  draught double precision,
	  type integer,
	  a double precision,
	  b double precision,
	  c double precision,
	  d double precision,
	  imo integer,
	  heading integer,
	  "navStat" integer,
	  name text,
	  dest text,
	  "callSign" text,
	  eta text,
	  PRIMARY KEY ("mmsi", "tstamp"),
	  CONSTRAINT "mmsi_date_location" UNIQUE ("mmsi", "tstamp")
	) PARTITION BY RANGE (tstamp)
	WITH (
	  OIDS=FALSE
	);

	CREATE INDEX IF NOT EXISTS sidx_location_shape
	  ON ais.location
	  USING gist (shape);

	CREATE OR REPLACE FUNCTION ais.create_shape()
	RETURNS TRIGGER
	LANGUAGE plpgsql
	AS \$\$
		BEGIN
			-- Make geometry
			IF NEW.longitude IS NOT NULL AND NEW.latitude IS NOT NULL THEN
				UPDATE ais.location
				SET shape = (SELECT public.ST_SetSRID(public.ST_MakePoint(NEW.longitude, NEW.latitude), 4326))
				WHERE uuid = NEW.uuid;
			END IF;
			RETURN NEW;
		END;
	\$\$;

	CREATE TRIGGER location_create_shape_location
		AFTER INSERT
		ON ais.location
		FOR EACH ROW EXECUTE PROCEDURE ais.create_shape();

	SELECT partman.create_parent('ais.location', 'tstamp', 'native', '${INTERVAL}');
	UPDATE partman.part_config SET infinite_time_partitions = true;
	SELECT cron.schedule('@${INTERVAL}', \$\$CALL partman.run_maintenance_proc(p_analyze := false)\$\$)

	CREATE VIEW ais.last_20m AS SELECT DISTINCT ON (mmsi) *
	FROM ais.location
	WHERE tstamp > current_timestamp - interval '20 minutes'
	ORDER BY mmsi, tstamp DESC;

EOSQL