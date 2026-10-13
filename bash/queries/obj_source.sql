/* Module obj_source - contexte d'execution : la base comparee
   Colonnes : object_name, object_type, colid, text_hex
   Un bloc syscomments (255 octets) par ligne, en hexadecimal sans 0x. bintostr(convert(varbinary(255), c.text))
   valide sur ASE (sortie testee : 510 caracteres hexa maximum par ligne, d'ou isql -w 4096). */
select o.name, o.type, c.colid, bintostr(convert(varbinary(255), c.text))
from sysobjects o, syscomments c
where o.id = c.id and o.type in ('V', 'P', 'TR')
order by o.name, o.type, c.colid
