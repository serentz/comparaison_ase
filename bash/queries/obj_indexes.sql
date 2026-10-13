/* Module obj_indexes - contexte d'execution : la base comparee
   Base : requete validee en production (statstamp = max(sysstatistics.moddate) de la table, comme le script client).
   Ajouts : i.status et la liste ordonnee des colonnes de l'index (index_col, 31 colonnes maximum), a valider sur ASE.
   Colonnes : table_name, index_name, status, columns, statstamp (voir docs/format_csv.md) */
select o.name, i.name, i.status,
       index_col(o.name, i.indid, 1)
       + isnull(',' + index_col(o.name, i.indid, 2), '')
       + isnull(',' + index_col(o.name, i.indid, 3), '')
       + isnull(',' + index_col(o.name, i.indid, 4), '')
       + isnull(',' + index_col(o.name, i.indid, 5), '')
       + isnull(',' + index_col(o.name, i.indid, 6), '')
       + isnull(',' + index_col(o.name, i.indid, 7), '')
       + isnull(',' + index_col(o.name, i.indid, 8), '')
       + isnull(',' + index_col(o.name, i.indid, 9), '')
       + isnull(',' + index_col(o.name, i.indid, 10), '')
       + isnull(',' + index_col(o.name, i.indid, 11), '')
       + isnull(',' + index_col(o.name, i.indid, 12), '')
       + isnull(',' + index_col(o.name, i.indid, 13), '')
       + isnull(',' + index_col(o.name, i.indid, 14), '')
       + isnull(',' + index_col(o.name, i.indid, 15), '')
       + isnull(',' + index_col(o.name, i.indid, 16), '')
       + isnull(',' + index_col(o.name, i.indid, 17), '')
       + isnull(',' + index_col(o.name, i.indid, 18), '')
       + isnull(',' + index_col(o.name, i.indid, 19), '')
       + isnull(',' + index_col(o.name, i.indid, 20), '')
       + isnull(',' + index_col(o.name, i.indid, 21), '')
       + isnull(',' + index_col(o.name, i.indid, 22), '')
       + isnull(',' + index_col(o.name, i.indid, 23), '')
       + isnull(',' + index_col(o.name, i.indid, 24), '')
       + isnull(',' + index_col(o.name, i.indid, 25), '')
       + isnull(',' + index_col(o.name, i.indid, 26), '')
       + isnull(',' + index_col(o.name, i.indid, 27), '')
       + isnull(',' + index_col(o.name, i.indid, 28), '')
       + isnull(',' + index_col(o.name, i.indid, 29), '')
       + isnull(',' + index_col(o.name, i.indid, 30), '')
       + isnull(',' + index_col(o.name, i.indid, 31), ''),
       max(s.moddate)
from sysobjects o, sysindexes i, sysstatistics s
where o.id = i.id and i.indid > 0 and o.type = 'U' and i.id = s.id
group by o.name, i.name, i.status, i.indid
order by o.name, i.name
