/* Module obj_tables - contexte d'execution : la base comparee
   Requete validee en production (jointure syscolumns.usertype = systypes.usertype).
   Colonnes : table_name, column_name, type_name, length, prec, scale, status */
select o.name, c.name, t.name, c.length, c.prec, c.scale, c.status
from sysobjects o, syscolumns c, systypes t
where o.type = 'U' and o.id = c.id and c.usertype = t.usertype
order by o.name, c.colid
