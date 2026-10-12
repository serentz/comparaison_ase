/* Module obj_code - contexte d'execution : la base comparee
   REQUETE DE DEPART reprise de Compare_instance_V3.sh : a remplacer par la version validee.
   Colonnes attendues : object_name, object_type (V, P ou TR) */
select name, type from sysobjects where type in ('V', 'P', 'TR') order by type, name
