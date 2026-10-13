/* Module inst_config - contexte d'execution : master
   Requete validee en production (script client). Le fichier ne contient pas de "go" : le script l'ajoute.
   Colonnes (docs/format_csv.md) : name, value, value_in_use */
select c.name, c.value, cur.value
from sysconfigures c, syscurconfigs cur
where c.config = cur.config
order by c.name
