/* Module db_options - contexte d'execution : master
   REQUETE DE DEPART reprise de Compare_instance_V3.sh (colonne name ajoutee) : a remplacer par la version validee.
   Colonnes attendues : db_name, status, status2, status3, status4 (une seule ligne) */
select name, status, status2, status3, status4
from sysdatabases
where name = '__DB__'
