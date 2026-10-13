/* Module obj_code - contexte d'execution : la base comparee
   Requete validee en production. Colonnes : object_name, object_type (V, P ou TR) */
select name, type from sysobjects where type in ('V', 'P', 'TR') order by type, name
