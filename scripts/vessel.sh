#!/bin/sh

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

	-- Importante callSign y navStat en camelcase para coincidir con el esquema

	CREATE TABLE last_position
	(
	  mmsi integer PRIMARY KEY,
	  shape geometry(Point,4326),
	  longitude double precision NOT NULL,
	  latitude double precision NOT NULL,
	  updated timestamp with time zone NOT NULL DEFAULT now(),
	  tstamp timestamp with time zone NOT NULL,
	  uuid uuid NOT NULL DEFAULT uuid_generate_v4(),
	  inserted timestamp with time zone NOT NULL,
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
	  CONSTRAINT "mmsi_date_last_position" UNIQUE ("mmsi", "tstamp")
	)
	WITH (
	  OIDS=FALSE
	);

	CREATE INDEX sidx_last_position_shape
	  ON last_position
	  USING gist (shape);

	CREATE FUNCTION before_insert_or_update_save_change_date()
	RETURNS trigger
    LANGUAGE plpgsql
    AS \$\$
		BEGIN
			IF TG_OP = 'INSERT' THEN
				NEW.inserted := now();
			END IF;
			IF TG_OP = 'UPDATE' THEN
				NEW.inserted := OLD.inserted;
			END IF;
			NEW.updated := now();
			RETURN NEW;
		END;
	\$\$;

	CREATE TRIGGER tracking_before_insert_or_update_save_change_date
	  BEFORE INSERT OR UPDATE
	  ON last_position
	  FOR EACH ROW
	  EXECUTE PROCEDURE before_insert_or_update_save_change_date();

	CREATE OR REPLACE FUNCTION create_shape()
	RETURNS TRIGGER
	LANGUAGE plpgsql
	AS \$\$
		BEGIN
			IF NEW.longitude IS NOT NULL AND NEW.latitude IS NOT NULL THEN
				SELECT ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 4326) INTO NEW.shape;
			END IF;
			RETURN NEW;
		END;
	\$\$;

	CREATE TRIGGER create_shape_last_position
		BEFORE INSERT OR UPDATE
		ON last_position
		FOR EACH ROW EXECUTE PROCEDURE create_shape();

	-- Last Week

	CREATE TABLE last_week
	(
	  uuid uuid NOT NULL DEFAULT uuid_generate_v4(),
	  mmsi integer NOT NULL,
	  shape geometry(Point,4326),
	  longitude double precision NOT NULL,
	  latitude double precision NOT NULL,
	  updated timestamp with time zone NOT NULL DEFAULT now(),
	  tstamp timestamp with time zone NOT NULL,
	  inserted timestamp with time zone NOT NULL,
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
	  CONSTRAINT "mmsi_date_last_position" UNIQUE ("mmsi", "tstamp")
	)
	WITH (
	  OIDS=FALSE
	);

	CREATE INDEX sidx_last_week_shape
	  ON last_week
	  USING gist (shape);


	CREATE TRIGGER tracking_before_insert_or_update_save_change_date
	  BEFORE INSERT OR UPDATE
	  ON last_week
	  FOR EACH ROW
	  EXECUTE PROCEDURE before_insert_or_update_save_change_date();


	CREATE TRIGGER create_shape_last_week
		BEFORE INSERT OR UPDATE
		ON last_week
		FOR EACH ROW EXECUTE PROCEDURE create_shape();
EOSQL