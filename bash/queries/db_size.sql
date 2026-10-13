/* Module db_size - contexte d'execution : master
   Requete validee en production (script client), le libelle LOG/DATA/MIXED est deduit par compare.py depuis segmap.
   Colonnes : db_name, segmap, size_mb
   __DB__ est remplace par le nom de la base (valide par le script).
   Taille : u.size * 2 / 1024, comme la requete validee (pages de 2 Ko). */
select d.name, u.segmap, sum(u.size * 2 / 1024)
from master..sysdatabases d, master..sysusages u
where d.name = '__DB__' and d.dbid = u.dbid
group by d.name, u.segmap
order by u.segmap
