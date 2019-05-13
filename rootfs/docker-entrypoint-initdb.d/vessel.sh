#!/bin/sh

set -e

INTERVAL=${INTERVAL:-hourly}
MAINTENANCE_INTERVAL_MINUTE=${MAINTENANCE_INTERVAL_MINUTE:-30}
MAINTENANCE_INTERVAL_HOUR=${MAINTENANCE_INTERVAL_HOUR:-*}
MAINTENANCE_INTERVAL_DAY_OF_MONTH=${MAINTENANCE_INTERVAL_DAY_OF_MONTH:-*}
MAINTENANCE_INTERVAL_MONTH=${MAINTENANCE_INTERVAL_MONTH:-*}
MAINTENANCE_INTERVAL_DAY_OF_WEEK=${MAINTENANCE_INTERVAL_DAY_OF_WEEK:-*}
RETENTION_TIME=${RETENTION_TIME:-7 days}

maintenanceInterval="$MAINTENANCE_INTERVAL_MINUTE $MAINTENANCE_INTERVAL_HOUR $MAINTENANCE_INTERVAL_DAY_OF_MONTH $MAINTENANCE_INTERVAL_MONTH $MAINTENANCE_INTERVAL_DAY_OF_WEEK"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE SCHEMA IF NOT EXISTS ais;

	CREATE USER "${EXPORTER_USER}" WITH PASSWORD '${EXPORTER_PASS}';
	GRANT pg_monitor, pg_read_all_settings, pg_read_all_stats, pg_stat_scan_tables TO "${EXPORTER_USER}";

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

	CREATE TABLE ais.location (
		uuid uuid NOT NULL DEFAULT uuid_generate_v4(),
		mmsi integer NOT NULL,
		shape geometry(Point,4326),
		longitude double precision NOT NULL,
		latitude double precision NOT NULL,
		tstamp timestamp without time zone NOT NULL,
		inserted timestamp with time zone NOT NULL DEFAULT now(),
		updated timestamp with time zone NOT NULL DEFAULT now(),
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

	CREATE INDEX IF NOT EXISTS sidx_location_tstamp_desc
	  ON ais.location (tstamp DESC);

	CREATE INDEX IF NOT EXISTS sidx_location_mmsi
	  ON ais.location (mmsi);

	CREATE INDEX IF NOT EXISTS sidx_location_tstamp_mmsi
	  ON ais.location (tstamp, mmsi);

	CREATE OR REPLACE FUNCTION ais.initialize_geom_and_dates()
	RETURNS TRIGGER
	LANGUAGE plpgsql
	AS \$\$
		BEGIN
			-- Make geometry
			IF NEW.longitude IS NOT NULL AND NEW.latitude IS NOT NULL THEN
				SELECT public.ST_SetSRID(public.ST_MakePoint(NEW.longitude, NEW.latitude), 4326) INTO NEW.shape;
			END IF;

			-- Generate UUID and initialize insert date
			IF TG_OP = 'INSERT' THEN
				NEW.inserted := now();
				NEW.uuid := public.uuid_generate_v4();
			END IF;

			NEW.updated := now();

			RETURN NEW;
		END;
	\$\$;

	CREATE OR REPLACE PROCEDURE ais.append_trigger(table_name text)
	LANGUAGE plpgsql
	AS \$\$
		DECLARE
			trigger_name text;
		BEGIN
			trigger_name := 'create_' || replace(table_name, '.', '_');

			EXECUTE format('CREATE TRIGGER %I '
			   'BEFORE INSERT OR UPDATE '
			   'ON %s '
			   'FOR EACH ROW EXECUTE PROCEDURE ais.initialize_geom_and_dates()', trigger_name, table_name);
		END;
	\$\$;

	CREATE OR REPLACE FUNCTION on_create_table_create_trigger()
	RETURNS event_trigger
	LANGUAGE plpgsql
	AS \$\$
		DECLARE
			obj RECORD;
		BEGIN
			FOR obj IN SELECT object_identity
						FROM pg_event_trigger_ddl_commands()
						WHERE object_type = 'table'
							AND object_identity LIKE 'ais.location_%'
			LOOP
				CALL ais.append_trigger(obj.object_identity);
				RAISE NOTICE 'Created trigger: %', obj.object_identity;
			END LOOP;
		END;
	\$\$;

	CREATE EVENT TRIGGER on_create_table ON ddl_command_end
	WHEN TAG IN ('CREATE TABLE')
	EXECUTE PROCEDURE on_create_table_create_trigger();

	SELECT partman.create_parent('ais.location', 'tstamp', 'native', '${INTERVAL}', p_premake := 3);

	UPDATE partman.part_config
	SET infinite_time_partitions = true,
	 retention = '${RETENTION_TIME}',
	 retention_keep_table = false;

	SELECT cron.schedule('${maintenanceInterval}', \$\$CALL partman.run_maintenance_proc(p_analyze := false)\$\$);
EOSQL
