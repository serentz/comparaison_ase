/* Module inst_config - contexte d'execution : master
   Requete validee en production (script client), adaptee : regroupement par nom.
   Raison : sur ASE 16 certains noms sont repetes (ex. "default data cache" : une ligne par
   taille de pool dans sysconfigures, plusieurs lignes dans syscurconfigs). Le nom est la cle
   de comparaison, il doit etre unique : on garde la valeur maximale par nom.
   Le fichier ne contient pas de "go" : le script l'ajoute.
   Colonnes (docs/format_csv.md) : name, value, value_in_use */
select c.name, max(c.value), max(cur.value)
from sysconfigures c, syscurconfigs cur
where c.config = cur.config
group by c.name
order by c.name
