/* Module obj_source - contexte d'execution : la base comparee
   REQUETE DE DEPART adaptee de Compare_instance_V3.sh : a remplacer par la version validee.
   Colonnes attendues : object_name, object_type, colid, text_hex
   Un bloc syscomments par ligne, texte en hexadecimal (sans 0x) pour eviter retours a la ligne et
   separateurs dans le CSV. bintostr(convert(varbinary(255), ...)) est une piste a valider sur ASE. */
select o.name, o.type, c.colid, bintostr(convert(varbinary(255), c.text))
from sysobjects o, syscomments c
where o.id = c.id and o.type in ('V', 'P', 'TR')
order by o.name, o.type, c.colid
