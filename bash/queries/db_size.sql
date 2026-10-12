/* Module db_size - contexte d'execution : master
   REQUETE DE DEPART reprise de Compare_instance_V3.sh : a remplacer par la version validee.
   Colonnes attendues : db_name, segmap, size_mb
   __DB__ est remplace par le nom de la base (valide par le script). */
select d.name, u.segmap, sum(u.size) * 2 / 1024
from sysdatabases d, sysusages u
where d.name = '__DB__' and d.dbid = u.dbid
group by d.name, u.segmap
order by u.segmap
