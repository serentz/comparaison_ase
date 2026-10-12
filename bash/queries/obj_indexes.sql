/* Module obj_indexes - contexte d'execution : la base comparee
   REQUETE DE DEPART reprise de Compare_instance_V3.sh : a remplacer par la version validee.
   Colonnes attendues : table_name, index_name, status, statstamp
   (statstamp : format ISO ou format par defaut d'ASE, ex. Oct 12 2026 11:00AM, ou NULL) */
select o.name, i.name, i.status, dateadd(ss, i.statstamp, '1970-01-01')
from sysobjects o, sysindexes i
where o.type = 'U' and o.id = i.id and i.indid > 0 and i.name not like '_sys_tabstats%'
order by o.name, i.name
