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


	CREATE TABLE ais.location (
		uuid uuid NOT NULL DEFAULT uuid_generate_v4(),
		mmsi integer NOT NULL,
		shape geometry(Point,4326),
		longitude double precision NOT NULL,
		latitude double precision NOT NULL,
		datetime timestamp without time zone NOT NULL,
		inserted timestamp with time zone NOT NULL DEFAULT now(),
		updated timestamp with time zone NOT NULL DEFAULT now(),
		"courseOverGroundInDegrees" double precision,
		"speedOverGroundInKnots" double precision,
		"draughtInMeters" double precision,
		"vesselType" integer,
		"distanceFromDeviceToBowInMeters" double precision,
		"distanceFromDeviceToSternInMeters" double precision,
		"distanceFromDeviceToPortInMeters" double precision,
		"distanceFromDeviceToStarboardInMeters" double precision,
		imo integer,
		"headingInDegrees" integer,
		"navigationalStatus" integer,
		name text,
		"destination" text,
		"vesselCallSign" text,
		"estimatedTimeOfArrival" text,
		PRIMARY KEY ("mmsi", "datetime"),
		CONSTRAINT "mmsi_date_location" UNIQUE ("mmsi", "datetime")
	) PARTITION BY RANGE (datetime)
	WITH (
		OIDS=FALSE
	);

	CREATE INDEX IF NOT EXISTS sidx_location_shape
	  ON ais.location
	  USING gist (shape);

	CREATE INDEX IF NOT EXISTS sidx_location_datetime_desc
	  ON ais.location (datetime DESC);

	CREATE INDEX IF NOT EXISTS sidx_location_mmsi
	  ON ais.location (mmsi);

	CREATE INDEX IF NOT EXISTS sidx_location_datetime_mmsi
	  ON ais.location (datetime, mmsi);

	CREATE OR REPLACE FUNCTION ais.initialize_geom_and_dates()
	RETURNS TRIGGER
	LANGUAGE plpgsql
	AS \$\$
		BEGIN
			-- Make geometry
			IF NEW.longitude IS NOT NULL AND NEW.latitude IS NOT NULL THEN
				SELECT public.ST_SetSRID(public.ST_MakePoint(NEW.longitude, NEW.latitude), 4326) INTO NEW.shape;
			END IF;

			SELECT coalesce(NEW.inserted, now()) INTO NEW.inserted;
			SELECT coalesce(NEW.updated, now()) INTO NEW.updated;
			SELECT coalesce(NEW.uuid, public.uuid_generate_v4()) INTO NEW.uuid;

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

	SELECT partman.create_parent('ais.location', 'datetime', 'native', '${INTERVAL}', p_premake := 3);

	UPDATE partman.part_config
	SET infinite_time_partitions = true,
		retention = '${RETENTION_TIME}',
		retention_keep_table = false;

	SELECT cron.schedule('${maintenanceInterval}', \$\$CALL partman.run_maintenance_proc(p_analyze := false)\$\$);

	-- Limpieza de datos que no sean de Canarias

	CREATE TABLE ais.limits (
		id serial PRIMARY KEY,
		shape geometry(Polygon,4326) NOT NULL,
		note text
	)
	WITH (
		OIDS=FALSE
	);

	CREATE INDEX IF NOT EXISTS sidx_limits_shape
		ON ais.limits
		USING gist (shape);

	-- -------------------------------------------------------------------------
	-- Elimina registros que no interseccionan con la geometría pasada
	-- de todas las particiones, salvo las últimas. Por defecto 2
	-- -------------------------------------------------------------------------

	CREATE OR REPLACE FUNCTION ais.clean_position(parent_table_in text, geom geometry, offset_p int default 2)
	RETURNS void AS \$\$
		DECLARE
			obj RECORD;
			offset_partition int;
		BEGIN
			-- Número de particiones a saltar
			SELECT premake + offset_p INTO offset_partition
			FROM partman.part_config
			WHERE parent_table = parent_table_in;

			-- Limpia todas las tablas que no se hayan borrado datos,
			-- se excluyen las últimas 2 horas por defecto
			FOR obj IN SELECT concat(schemaname, '.', relname) AS "tablename"
							FROM pg_stat_user_tables
							WHERE relname IN (SELECT partition_tablename
											FROM partman.show_partitions(parent_table_in, 'DESC')
											OFFSET offset_partition)
			LOOP
				EXECUTE 'DELETE FROM ' || obj.tablename || ' WHERE NOT ST_Intersects(shape, $1)' USING geom;
				RAISE NOTICE 'Cleaned table: %', obj.tablename;
			END LOOP;
		END;
	\$\$ LANGUAGE plpgsql;

	INSERT INTO ais.limits (shape, note)
	VALUES ('SRID=4326;POLYGON((-18.4166666666667 27.3833333333333,-18.4166666666667 29.6166666666667,-13.1 29.6166666666667,-13.1 27.3833333333333,-18.4166666666667 27.3833333333333))',
		'Bbox de CANREP. Todos los barcos que caen fuera de esta zona son eliminados pasado 1 hora');

	SELECT cron.schedule('* */2 * * *', \$\$SELECT ais.clean_position('ais.location', shape) FROM ais.limits WHERE id = 1\$\$);

	-- -------------------------------------------------------------------------
	-- Libera el espacio en disco de los registros eliminados, para ello
	-- se usa la función clúster que reescribe los datos en el disco,
	-- utilizando un índice
	-- -------------------------------------------------------------------------

	CREATE OR REPLACE PROCEDURE ais.vacuum_partitions()
	LANGUAGE plpgsql
	AS \$\$
		DECLARE
			obj RECORD;
		BEGIN
			FOR obj IN SELECT concat(schemaname, '.', relname) AS "tablename",
							concat(relname, '_shape_idx') as "index"
						FROM pg_stat_user_tables
						WHERE relname LIKE 'location_p%' AND n_tup_del > 0
			LOOP
				EXECUTE 'CLUSTER ' || obj.tablename || ' USING ' || obj.index;
				RAISE NOTICE 'Vacuumed table: %', obj.tablename;
			END LOOP;
		END;
	\$\$;

	COMMENT ON PROCEDURE ais.vacuum_partitions()
	IS 'Libera el espacio en disco de los registros eliminados para ello se usa la función clúster que reescribe los datos en el disco, utilizando un índice';

	SELECT cron.schedule('20 */2 * * *', \$\$CALL ais.vacuum_partitions()\$\$);

	-- -------------------------------------------------------------------------
	-- Agrupa las particiones en nuevas particiones mayores
	-- -------------------------------------------------------------------------

	CREATE OR REPLACE FUNCTION ais.aggs_partitions(p_parent_table text, p_grounp_by interval,
		clean_partition boolean default true, p_conjunction text default '_p',
		p_datetime_pattern text default null)
	RETURNS void AS \$\$
		declare table_name text;
		declare partition_name text;
		declare detach_partition_name text;
		declare d RECORD;
		declare g RECORD;
		declare start_interval timestamp;
		declare end_interval timestamp;
		declare datetime_pattern text;
		declare partition_name_length int;
		declare partition_preffix text;
		declare template_table_struct text;
		declare control_field text;
	BEGIN
		SELECT control, coalesce(p_datetime_pattern, datetime_string) as datetime_string, template_table
			INTO control_field, datetime_pattern, template_table_struct
		FROM partman.part_config
		WHERE parent_table = p_parent_table;

		SELECT regexp_replace(p_parent_table, '\w+\.(.*)', '\1')
			INTO table_name;

		SELECT concat(table_name, p_conjunction)
			INTO partition_preffix;

		SELECT length(concat(partition_preffix, regexp_replace(datetime_pattern, '\d', '', 'g')))
			INTO partition_name_length;

		FOR d IN SELECT inter FROM (
					SELECT to_date(replace(partition_tablename, partition_preffix, ''), datetime_pattern) as inter
					FROM partman.show_partitions(p_parent_table)
					WHERE partition_tablename LIKE (partition_preffix || '%')
						AND length(partition_tablename) = partition_name_length
				) AS intervals
				WHERE inter < NOW() - p_grounp_by * 2
				GROUP BY inter
				ORDER BY inter
		LOOP
			start_interval:=d.inter;
			end_interval:=d.inter + p_grounp_by;

			SELECT concat(p_parent_table, p_conjunction, replace(d.inter::text, '-', '_'))
				INTO partition_name;

			EXECUTE 'CREATE TABLE IF NOT EXISTS ' || partition_name || ' (LIKE ' || template_table_struct || ')';
			EXECUTE 'INSERT INTO ' || partition_name || ' SELECT * FROM ' ||
					 p_parent_table || ' WHERE ' || control_field || ' >= $1 AND ' || control_field || ' < $2' USING start_interval, end_interval;

			--
			-- Find partitions with data in the interval and detach it from parent table
			--
			FOR g IN SELECT inter
					FROM (
						SELECT to_timestamp(replace(partition_tablename, partition_preffix, ''), datetime_pattern) as inter
						FROM partman.show_partitions(p_parent_table)
						WHERE partition_tablename LIKE (partition_preffix || '%')
							AND length(partition_tablename) = partition_name_length
					) AS intervals
					WHERE inter >= start_interval AND inter < end_interval
			LOOP
				SELECT concat(p_parent_table, p_conjunction, to_char(g.inter, datetime_pattern))
					INTO detach_partition_name;

				IF clean_partition THEN
					EXECUTE 'DROP TABLE ' || detach_partition_name;
					RAISE NOTICE 'Dropped partition: %', detach_partition_name;
				ELSE
					EXECUTE 'ALTER TABLE ' || p_parent_table || ' DETACH PARTITION ' || detach_partition_name;
					RAISE NOTICE 'Detached partition: %', detach_partition_name;
				END IF;
			END LOOP;

			--
			-- The new partition attaches to parent table
			--
			EXECUTE 'ALTER TABLE ' || p_parent_table || ' ATTACH PARTITION ' || partition_name ||
					' FOR VALUES FROM (''' || start_interval || ''') TO (''' || end_interval || ''')';
		END LOOP;
	END;
	\$\$ LANGUAGE plpgsql;

	SELECT cron.schedule('5 0 * * *', \$\$SELECT ais.aggs_partitions('ais.location', interval '1 day')\$\$);

EOSQL
