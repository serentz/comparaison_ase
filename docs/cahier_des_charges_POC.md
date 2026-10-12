# POC : comparaison d'instances et de bases SAP ASE, restitution Grafana

| | |
|---|---|
| Projet | `compre_ase_db` |
| Version du document | 0.1 (12/10/2026) |
| Dépôt git | `https://github.com/serentz/comparaison_ase` |
| Répertoire local | `I:\POC\compre_ase_db` |

## 1. Objectif

Comparer deux couples **instance / base de données** SAP ASE 16.0 sur 7 modules de contrôle. Chaque écart est enregistré dans PostgreSQL, puis affiché dans Grafana avec un dashboard par module.

## 2. Décisions validées

| Sujet | Décision |
|---|---|
| Modules | Les 7 modules : `inst_config`, `db_size`, `db_options`, `obj_tables`, `obj_indexes`, `obj_code`, `obj_source` |
| Bruit de comparaison | Table de règles d'exclusion configurable dans PostgreSQL (`exclusion_rules`) |
| Connexion ASE | `isql` conservé (fichier `interfaces` du client Open Client) |
| Logins ASE | Un login par instance dans `config_compa_ase` |
| Rapport texte et email (`-m`) | Supprimés, Grafana remplace le rapport |
| Identification d'une exécution | `refid` + `run_id` + `ts_exec` |
| Mot de passe PostgreSQL | `-P` accepté, avec alternative `PGPASSWORD` ou `.pgpass` |
| Options PostgreSQL supplémentaires | `-H` (hôte), `-p` (port), `-n` (nom de la base) |
| Plateforme des VM | Hyper-V, installé sur le PC de développement |
| OS | Ubuntu pour PostgreSQL et le bastion, CentOS pour les 2 serveurs SAP ASE |
| Licence ASE | Developer Edition gratuite, période de grâce de 30 jours suffisante pour le POC |
| Accès GitHub | Fourni par l'utilisateur sur demande de Claude |

## 3. Architecture cible (Hyper-V, 4 VM Linux)

| VM | OS | Rôle | Dimensionnement indicatif |
|---|---|---|---|
| `pg01` | Ubuntu | PostgreSQL (résultats, références, configuration) | 2 vCPU, 2 à 4 Go |
| `ase01` | CentOS | SAP ASE 16.0 Developer Edition, instance 1 | 2 vCPU, 4 Go |
| `ase02` | CentOS | SAP ASE 16.0 Developer Edition, instance 2 | 2 vCPU, 4 Go |
| `bastion` | Ubuntu | Exécution du script, client `isql`, venv Python, Grafana | 2 vCPU, 4 Go |

Total indicatif : environ 14 Go de RAM. Réseau : un commutateur virtuel Hyper-V commun (interne ou NAT) avec adresses IP fixes.
Ports : 5432 (PostgreSQL), 5000 (ASE, à confirmer), 3000 (Grafana).

## 4. Lancement du script (ligne de commande)

| Option | Rôle |
|---|---|
| `-S` | Instance 1 |
| `-D` | Base de données 1 |
| `-s` | Instance 2 |
| `-d` | Base de données 2 |
| `-U` | Login PostgreSQL |
| `-P` | Mot de passe PostgreSQL (alternative : `PGPASSWORD` ou `.pgpass`) |
| `-H` | Hôte PostgreSQL |
| `-p` | Port PostgreSQL |
| `-n` | Nom de la base PostgreSQL |

Les options `-t`, `-b` et `-m` de l'ancien script sont supprimées.

## 5. Pré-contrôles au démarrage

1. Connexion à PostgreSQL. Si le schéma ou les tables sont absents, le script **s'arrête** avec un message demandant d'exécuter `create_schema.sql`.
2. Lecture des logins ASE dans `config_compa_ase` (un login par instance).
3. Recherche de la combinaison (instance1, base1, instance2, base2) dans `ref_execution`. Si elle n'existe pas, elle est créée ; sinon le `refid` existant est réutilisé.
4. Création d'un nouveau `run_id` pour l'exécution en cours.
5. Vérification de la connectivité aux deux instances ASE. En cas d'échec, arrêt avec un code retour non nul (jamais de faux « 0 écart »).

## 6. Partie 1 : extraction (bash, `Compare_instance_V3.sh` allégé)

- On conserve uniquement `extract_data` et `run_isql`. On supprime `compare_data`, `format_result` et `send_report_mail`.
- Connexion via `isql`. Le mot de passe ASE n'est pas passé en clair dans la ligne de commande (visible dans `ps`) : fichier temporaire en mode 600 ou variable d'environnement.
- Sortie : **un CSV par module et par côté**, avec en-têtes, séparateur fixe, `NULL` explicite, sans espaces de remplissage et sans troncature.
- Dossier de travail dédié par `run_id`, nettoyé en fin d'exécution.
- Le bash appelle ensuite `compare.py` avec le `run_id`, le `refid` et les chemins des CSV.

## 7. Partie 2 : comparaison (Python, venv)

Pour chaque module : chargement des deux CSV en mémoire (pandas), jointure par clé, détection des écarts, application des règles d'exclusion, insertion dans PostgreSQL.

| Module | Clé | Valeurs comparées |
|---|---|---|
| `inst_config` | name | value, value_in_use |
| `db_size` | segmap (mappé data / log / mixed), hors nom de base | taille en Mo |
| `db_options` | ligne unique | status, status2, status3, status4 |
| `obj_tables` | table + colonne | type, length, prec, scale, status décodé |
| `obj_indexes` | table + index | status (la date `statstamp` est exclue par défaut) |
| `obj_code` | name + type | présence |
| `obj_source` | name + type | hash MD5 du code reconstitué (`colid`), texte stocké à part |

Types d'écart : `ONLY_R1`, `ONLY_R2`, `DIFF`. Les écarts correspondant à une règle d'exclusion sont ignorés ou marqués « attendu ».

## 8. Modèle de données PostgreSQL

- **`ref_execution`** : `refid` (PK), `instance1`, `base1`, `instance2`, `base2`, contrainte UNIQUE sur les 4 colonnes.
- **`run`** : `run_id` (PK), `refid`, `ts_exec`, `statut`.
- **`config_compa_ase`** : `instance`, `host`, `port`, `login`, `password`.
- **`exclusion_rules`** : `module`, `cle`, `motif`, `actif`.
- **`diff_<module>`** (7 tables) : `run_id`, `refid`, `ts_exec`, `type_diff`, colonnes de clé, `R1_<valeur>`, `R2_<valeur>`. Une ligne consolidée par différence, avec index sur `run_id` et `refid`.
- Script `create_schema.sql` livré.
- Un utilisateur PostgreSQL en lecture seule pour Grafana.

## 9. Grafana (sur le bastion)

- Datasource PostgreSQL, provisionnée par fichiers.
- 7 dashboards, un par module.
- En haut de chaque dashboard : variable de sélection du run (timestamp, instance 1 + base 1, instance 2 + base 2).
- Navigation entre modules par une barre de liens de dashboards (`links`), identique sur toutes les pages. Éventuellement un dashboard d'accueil récapitulatif.
- Dashboards exportés en JSON et versionnés dans git.

## 10. Plan d'action par étapes

1. Création des 4 VM sous Hyper-V et du réseau.
2. Installation de PostgreSQL, exécution de `create_schema.sql`, alimentation de `config_compa_ase`.
3. Installation des 2 instances ASE 16.0 Developer Edition, puis exécution des scripts de base de test (annexe A).
4. Bastion : client ASE (`isql`), Python, création du venv, `requirements.txt`.
5. Revue et allègement de `Compare_instance_V3.sh`.
6. Développement de `compare.py` et tests module par module.
7. Installation de Grafana, datasource, 7 dashboards, navigation.
8. Tests de bout en bout, documentation (README).
9. Création et mise à jour du projet git sous `https://github.com/serentz`, sans aucun secret dans le dépôt.

## 11. Arborescence du projet

```
compre_ase_db/
  bash/        Compare_instance_V3.sh (existant, à alléger)
  python/      compare.py, requirements.txt
  sql/
    postgres/  create_schema.sql
    ase_test/  01_create_poc_db_instance1.sql, 02_create_poc_db_instance2.sql
  grafana/     provisioning et dashboards JSON
  docs/        ce document
```

## 12. Livrables

Script bash allégé, `compare.py`, `create_schema.sql`, scripts de base de test ASE, dashboards Grafana (JSON), `requirements.txt`, README, plan d'action, dépôt git.

## 13. Critères d'acceptation

- Le script s'arrête proprement si le schéma est absent ou si une instance est injoignable.
- Un même couple instance/base réutilise le même `refid`.
- Chaque différence de l'annexe A apparaît dans le bon dashboard.
- Le sélecteur de run et la navigation entre les 7 dashboards fonctionnent.

---

## Annexe A : jeu de test ASE (deux scripts avec écarts volontaires)

Deux scripts créent la base `poc_db` : `01_create_poc_db_instance1.sql` sur l'instance 1 et `02_create_poc_db_instance2.sql` sur l'instance 2. Le nom de base est identique des deux côtés pour que les clés de comparaison correspondent. À exécuter avec `sa` :

```
isql -S <INSTANCE> -U sa -i <script>.sql -o <script>.log
```

Avant exécution, adapter le chemin des devices (`physname`) en tête de chaque script. Les commentaires SQL sont volontairement sans accent (charset ASE).

| Module | Écarts attendus |
|---|---|
| `inst_config` | `deadlock retries` : 5 / 10 ; `print deadlock information` : 0 / 1 |
| `db_size` | data : 100 Mo / 120 Mo ; log : 40 Mo / 50 Mo |
| `db_options` | `select into/bulkcopy/pllsort` actif en base 1 ; `trunc log on chkpt` et `abort tran on log full` actifs en base 2 |
| `obj_tables` | `customers.email` varchar(100) / varchar(150) ; `customers.phone` nullable / not null ; `orders.total_amount` numeric(12,2) / numeric(14,2) ; `order_items.discount` seulement en base 1 ; `products.barcode` seulement en base 2 ; table `tmp_import` seulement en base 1 ; table `archive_orders` seulement en base 2 |
| `obj_indexes` | `idx_orders_date` seulement en base 1 ; `idx_orders_customer` seulement en base 2 ; `pk_products` clustered / nonclustered ; `uq_customers_email` unique / non unique ; dates de statistiques de `customers` différentes (bruit, couvert par une règle d'exclusion) |
| `obj_code` | `sp_purge_orders` (P) et `trg_customers_upd` (TR) seulement en base 1 ; `sp_archive_orders` (P) et `v_customer_orders` (V) seulement en base 2 |
| `obj_source` | contenu différent : `sp_get_customer`, `sp_calc_order_total` (code long sur plusieurs blocs `syscomments`, écart dans le dernier bloc), `v_orders_summary`, `trg_orders_audit` |
| Témoins sans écart | table `audit_log`, procédure `sp_list_products`, index `idx_customers_name` et `idx_order_items_order` |
