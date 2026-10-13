/* Module db_options - contexte d'execution : master
   Colonnes : db_name, status, status2, status3, status4 (une seule ligne).
   Les valeurs brutes sont livrees ; le decodage (bits valides en production : status 4, 8, 16, 512, 1024,
   2048, 4096 ; status2 1, 4, 8, 16, 64, 128, 1024 ; status3 2) est fait par compare.py. */
select name, status, status2, status3, status4
from master..sysdatabases
where name = '__DB__'
