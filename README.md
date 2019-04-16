# AIS Postgres
Base de datos PostgreSQL para almacenar datos AIS.

La tabla principal está particionada por tiempo, de esta forma sólo se accede agiliza las búsquedas que impliquen consultas por fechas.
