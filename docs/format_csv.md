# Format des CSV d'extraction (contrat bash → Python)

Ce document définit ce que le script bash d'extraction doit produire et ce que `compare.py` lit.
Les requêtes ASE peuvent être celles de ton choix (par exemple celles validées chez le client) tant que les **fichiers et colonnes ci-dessous sont respectés**.

## 1. Appel de `compare.py`

```
python compare.py --csv-dir <dossier> --run-id <run_id> --refid <refid> \
                  -H <hote_pg> -p <port_pg> -n <base_pg> -U <login_pg> [-P <mot_de_passe_pg>]
```

- `run_id` et `refid` sont créés **avant** l'extraction par le bash, avec les fonctions du schéma :
  `SELECT compa_ase.get_or_create_refid(:instance1, :base1, :instance2, :base2);` puis `SELECT compa_ase.start_run(:refid);`
- À la fin, `compare.py` appelle `compa_ase.end_run(run_id, 'TERMINE')`, ou `'ERREUR'` avec un message en cas d'échec.
- Le mot de passe PostgreSQL peut aussi venir de `PGPASSWORD` ou de `.pgpass`.

| Code retour | Signification |
|---|---|
| 0 | Comparaison terminée (avec ou sans écart) |
| 2 | CSV manquant, vide ou invalide |
| 3 | Erreur PostgreSQL |

## 2. Fichiers attendus

Un dossier de travail par exécution, contenant **14 fichiers** : un par module et par côté.
`r1_` = instance 1 / base 1, `r2_` = instance 2 / base 2.

```
<dossier>/r1_inst_config.csv     <dossier>/r2_inst_config.csv
<dossier>/r1_db_size.csv         <dossier>/r2_db_size.csv
<dossier>/r1_db_options.csv      <dossier>/r2_db_options.csv
<dossier>/r1_obj_tables.csv      <dossier>/r2_obj_tables.csv
<dossier>/r1_obj_indexes.csv     <dossier>/r2_obj_indexes.csv
<dossier>/r1_obj_code.csv        <dossier>/r2_obj_code.csv
<dossier>/r1_obj_source.csv      <dossier>/r2_obj_source.csv
```

## 3. Règles générales

| Règle | Détail |
|---|---|
| Encodage | UTF-8, fins de ligne LF (convertir avec `iconv` si le charset ASE est différent) |
| Séparateur | `\|` (pipe), sans guillemets : aucune valeur ne doit contenir `\|` ni retour à la ligne |
| En-tête | Première ligne obligatoire, noms de colonnes exactement comme ci-dessous, en minuscules. `isql -b` supprime les en-têtes : le bash les ajoute |
| Espaces | Valeurs sans espaces de début ni de fin (le remplissage d'`isql` est retiré par le bash, `compare.py` re-nettoie par sécurité) |
| NULL | Écrit `NULL`, comme `isql` l'affiche nativement. `compare.py` le convertit en valeur nulle |
| Lignes vides | Ignorées. Aucune ligne de bruit (`(n rows affected)`, tirets) ne doit rester |
| Fichier sans donnée | Autorisé (en-tête seul) : il signifie « aucune ligne ». Un fichier **absent ou entièrement vide, sans en-tête**, est une erreur d'extraction (code retour 2) |
| Ordre des lignes | Sans importance, `compare.py` joint par clé |
| Doublons de clé | Erreur (code retour 2) |
| Contrôle de structure | Une ligne dont le nombre de colonnes diffère de l'en-tête est une erreur (code retour 2) |

Limite connue du POC : le propriétaire des objets n'est pas extrait, les objets sont supposés appartenir à `dbo`.

## 4. Contenu par module

### 4.1 `inst_config`

| Colonne | Contenu |
|---|---|
| `name` | Nom du paramètre (**clé**) |
| `value` | Valeur configurée |
| `value_in_use` | Valeur en cours d'utilisation |

```
name|value|value_in_use
deadlock retries|5|5
print deadlock information|0|0
```

### 4.2 `db_size`

| Colonne | Contenu |
|---|---|
| `db_name` | Nom de la base (informatif, **non utilisé comme clé**) |
| `segmap` | Valeur brute de `sysusages.segmap` |
| `size_mb` | Taille en Mo, somme par `segmap` |

`compare.py` déduit la colonne `segment` : `log` si `segmap` vaut 4, `mixed` si le bit 4 est combiné à d'autres, `data` sinon. **La clé de comparaison est ce `segment`.**

```
db_name|segmap|size_mb
poc_db|3|100
poc_db|4|40
```

### 4.3 `db_options`

Une seule ligne par fichier. Pas de clé.

| Colonne | Contenu |
|---|---|
| `db_name` | Nom de la base (informatif) |
| `status` | `sysdatabases.status` |
| `status2` | `sysdatabases.status2` |
| `status3` | `sysdatabases.status3` |
| `status4` | `sysdatabases.status4` |

Le décodage lisible des options (colonnes `r1_options` / `r2_options` du schéma) est fait par `compare.py` et sera validé contre la sortie de `sp_helpdb` pendant les tests.

```
db_name|status|status2|status3|status4
poc_db|4|0|0|0
```

### 4.4 `obj_tables`

| Colonne | Contenu |
|---|---|
| `table_name` | Nom de la table (**clé**, avec `column_name`) |
| `column_name` | Nom de la colonne (**clé**) |
| `type_name` | Type de données (`systypes.name`) |
| `length` | Longueur |
| `prec` | Précision (`NULL` si non applicable) |
| `scale` | Échelle (`NULL` si non applicable) |
| `status` | `syscolumns.status` brut |

`compare.py` décode `status` (nullabilité, identity) dans les colonnes `r1_attributs` / `r2_attributs`.

```
table_name|column_name|type_name|length|prec|scale|status
customers|email|varchar|100|NULL|NULL|8
orders|total_amount|numeric|6|12|2|0
```

### 4.5 `obj_indexes`

| Colonne | Contenu |
|---|---|
| `table_name` | Nom de la table (**clé**, avec `index_name`) |
| `index_name` | Nom de l'index (**clé**) |
| `status` | `sysindexes.status` brut |
| `statstamp` | Date des statistiques, `YYYY-MM-DD HH:MM:SS` ou `NULL` |

`compare.py` accepte aussi le format par défaut d'ASE (`Oct 12 2026 11:00AM`). La différence sur `statstamp` seule est ignorée par la règle d'exclusion par défaut de `exclusion_rules`.

```
table_name|index_name|status|statstamp
customers|idx_customers_name|0|2026-10-12 11:00:00
orders|pk_orders|2048|NULL
```

### 4.6 `obj_code`

| Colonne | Contenu |
|---|---|
| `object_name` | Nom de l'objet (**clé**, avec `object_type`) |
| `object_type` | `V` (vue), `P` (procédure) ou `TR` (trigger) |

```
object_name|object_type
sp_get_customer|P
v_orders_summary|V
trg_orders_audit|TR
```

### 4.7 `obj_source`

Le code source est découpé par ASE en blocs de 255 caractères (`syscomments`). Il contient des retours à la ligne et peut contenir `|` : on ne le met donc **pas en clair** dans le CSV. **Chaque bloc est livré en hexadécimal**, une ligne par bloc.

| Colonne | Contenu |
|---|---|
| `object_name` | Nom de l'objet (**clé**, avec `object_type`) |
| `object_type` | `V`, `P` ou `TR` |
| `colid` | Numéro du bloc (ordre de reconstitution) |
| `text_hex` | Contenu du bloc en hexadécimal, sans préfixe `0x` |

`compare.py` reconstitue le code par objet (tri sur `colid`, décodage), calcule le hash MD5 et le nombre de lignes, et ne stocke le texte complet que pour les objets en écart.

Piste côté ASE, à valider sur ton instance : `bintostr(convert(varbinary(255), c.text))` pour produire l'hexadécimal.

```
object_name|object_type|colid|text_hex
sp_get_customer|P|1|637265617465...
sp_get_customer|P|2|2020...
```

## 5. Correspondance avec les tables PostgreSQL

| Module | Table de résultats | Colonnes de valeur |
|---|---|---|
| `inst_config` | `diff_inst_config` | `r1_value`, `r1_value_in_use`, `r2_value`, `r2_value_in_use` |
| `db_size` | `diff_db_size` | `r1_segmap`, `r1_size_mb`, `r2_segmap`, `r2_size_mb` |
| `db_options` | `diff_db_options` | `r1_status`…`r1_status4`, `r1_options`, idem `r2_` |
| `obj_tables` | `diff_obj_tables` | `r1_type`, `r1_length`, `r1_prec`, `r1_scale`, `r1_status`, `r1_attributs`, idem `r2_` |
| `obj_indexes` | `diff_obj_indexes` | `r1_status`, `r1_statstamp`, idem `r2_` |
| `obj_code` | `diff_obj_code` | `r1_present`, `r2_present` |
| `obj_source` | `diff_obj_source` | `r1_hash`, `r1_nb_lignes`, `r1_source`, idem `r2_` |

Types d'écart : `ONLY_R1` (clé présente seulement côté 1), `ONLY_R2` (seulement côté 2), `DIFF` (clé présente des deux côtés avec des valeurs différentes).
