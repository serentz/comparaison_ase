/* Module inst_config - contexte d'execution : master
   REQUETE DE DEPART reprise de Compare_instance_V3.sh : a remplacer par la version validee.
   Colonnes attendues (docs/format_csv.md) : name, value, value_in_use
   Le fichier ne contient pas de "go" : le script l'ajoute. */
select name, value, value_in_use from sysconfigures order by name
