# AIS Postgres

Base de datos PostgreSQL para almacenar datos AIS.

La tabla principal está particionada por tiempo, para agilizar las consultas por fecha.

## Cálculos

* Capacidad del disco 51200 MB
* 5% de espacio reservado 2560 MB
* Espacio reservado para ficheros WAL 2048 MB
* Espacio para almacenar 2 horas de datos de todo el mundo 1200 MB
* Espacio para un día después de limpiar 100 MB
