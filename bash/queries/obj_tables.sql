/* Module obj_tables - contexte d'execution : la base comparee
   REQUETE DE DEPART reprise de Compare_instance_V3.sh : a remplacer par la version validee.
   Colonnes attendues : table_name, column_name, type_name, length, prec, scale, status */
select o.name, c.name, t.name, c.length, c.prec, c.scale, c.status
from sysobjects o, syscolumns c, systypes t
where o.type = 'U' and o.id = c.id and c.utype = t.utype
order by o.name, c.colid
