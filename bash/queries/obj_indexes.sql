/* Module obj_indexes - contexte d'execution : la base comparee
   Base : requete validee en production (statstamp = max(sysstatistics.moddate) de la table, comme le script client).
   Ajouts : i.status et la liste ordonnee des colonnes de l'index (index_col, 31 colonnes maximum).
   Sur ASE ',' + NULL donne ',' (NULL = chaine vide) : d'ou le case, pas isnull.
   La concatenation est convertie en varchar(255) : sans cela ASE la type en tres large et isql coupe la ligne.
   Colonnes : table_name, index_name, status, columns, statstamp (voir docs/format_csv.md) */
select o.name, i.name, i.status,
       convert(varchar(255), index_col(o.name, i.indid, 1)
       + case when index_col(o.name, i.indid, 2) is null then '' else ',' + index_col(o.name, i.indid, 2) end
       + case when index_col(o.name, i.indid, 3) is null then '' else ',' + index_col(o.name, i.indid, 3) end
       + case when index_col(o.name, i.indid, 4) is null then '' else ',' + index_col(o.name, i.indid, 4) end
       + case when index_col(o.name, i.indid, 5) is null then '' else ',' + index_col(o.name, i.indid, 5) end
       + case when index_col(o.name, i.indid, 6) is null then '' else ',' + index_col(o.name, i.indid, 6) end
       + case when index_col(o.name, i.indid, 7) is null then '' else ',' + index_col(o.name, i.indid, 7) end
       + case when index_col(o.name, i.indid, 8) is null then '' else ',' + index_col(o.name, i.indid, 8) end
       + case when index_col(o.name, i.indid, 9) is null then '' else ',' + index_col(o.name, i.indid, 9) end
       + case when index_col(o.name, i.indid, 10) is null then '' else ',' + index_col(o.name, i.indid, 10) end
       + case when index_col(o.name, i.indid, 11) is null then '' else ',' + index_col(o.name, i.indid, 11) end
       + case when index_col(o.name, i.indid, 12) is null then '' else ',' + index_col(o.name, i.indid, 12) end
       + case when index_col(o.name, i.indid, 13) is null then '' else ',' + index_col(o.name, i.indid, 13) end
       + case when index_col(o.name, i.indid, 14) is null then '' else ',' + index_col(o.name, i.indid, 14) end
       + case when index_col(o.name, i.indid, 15) is null then '' else ',' + index_col(o.name, i.indid, 15) end
       + case when index_col(o.name, i.indid, 16) is null then '' else ',' + index_col(o.name, i.indid, 16) end
       + case when index_col(o.name, i.indid, 17) is null then '' else ',' + index_col(o.name, i.indid, 17) end
       + case when index_col(o.name, i.indid, 18) is null then '' else ',' + index_col(o.name, i.indid, 18) end
       + case when index_col(o.name, i.indid, 19) is null then '' else ',' + index_col(o.name, i.indid, 19) end
       + case when index_col(o.name, i.indid, 20) is null then '' else ',' + index_col(o.name, i.indid, 20) end
       + case when index_col(o.name, i.indid, 21) is null then '' else ',' + index_col(o.name, i.indid, 21) end
       + case when index_col(o.name, i.indid, 22) is null then '' else ',' + index_col(o.name, i.indid, 22) end
       + case when index_col(o.name, i.indid, 23) is null then '' else ',' + index_col(o.name, i.indid, 23) end
       + case when index_col(o.name, i.indid, 24) is null then '' else ',' + index_col(o.name, i.indid, 24) end
       + case when index_col(o.name, i.indid, 25) is null then '' else ',' + index_col(o.name, i.indid, 25) end
       + case when index_col(o.name, i.indid, 26) is null then '' else ',' + index_col(o.name, i.indid, 26) end
       + case when index_col(o.name, i.indid, 27) is null then '' else ',' + index_col(o.name, i.indid, 27) end
       + case when index_col(o.name, i.indid, 28) is null then '' else ',' + index_col(o.name, i.indid, 28) end
       + case when index_col(o.name, i.indid, 29) is null then '' else ',' + index_col(o.name, i.indid, 29) end
       + case when index_col(o.name, i.indid, 30) is null then '' else ',' + index_col(o.name, i.indid, 30) end
       + case when index_col(o.name, i.indid, 31) is null then '' else ',' + index_col(o.name, i.indid, 31) end),
       max(s.moddate)
from sysobjects o, sysindexes i, sysstatistics s
where o.id = i.id and i.indid > 0 and o.type = 'U' and i.id = s.id
group by o.name, i.name, i.status, i.indid
order by o.name, i.name
