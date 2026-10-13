/* Module db_size - contexte d'execution : master
   Colonnes : db_name, segmap, size_mb ; le libelle LOG/DATA/MIXED est deduit par compare.py depuis segmap.
   __DB__ est remplace par le nom de la base (valide par le script).
   sysusages.size est en pages logiques de @@maxpagesize octets (2, 4, 8 ou 16 Ko selon le serveur) :
   Mo = size * @@maxpagesize / 1048576. bigint evite le depassement d'entier. */
select d.name, u.segmap, sum(convert(bigint, u.size) * @@maxpagesize / 1048576)
from master..sysdatabases d, master..sysusages u
where d.name = '__DB__' and d.dbid = u.dbid
group by d.name, u.segmap
order by u.segmap
