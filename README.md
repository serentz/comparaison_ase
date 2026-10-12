# comparaison_ase

POC de comparaison de deux couples **instance / base de données** SAP ASE 16.0.
Les écarts sont enregistrés dans PostgreSQL et affichés dans Grafana (un dashboard par module).

## Modules comparés

`inst_config`, `db_size`, `db_options`, `obj_tables`, `obj_indexes`, `obj_code`, `obj_source`

## Contenu du dépôt

| Dossier | Contenu |
|---|---|
| `bash/` | `compare_ase.sh` (orchestration), `queries/*.sql` (requêtes d'extraction), `tests/` (faux `isql`, tests). `Compare_instance_V3.sh` : ancien script, conservé pour référence |
| `docs/` | Cahier des charges du POC |
| `python/` | `compare.py` (comparaison des CSV et insertion dans PostgreSQL) et `tests/` (tests automatisés, CSV factices) |
| `sql/postgres/` | `create_schema.sql` : schéma PostgreSQL `compa_ase` (références, runs, configuration, exclusions, 7 tables `diff_<module>`, vues Grafana) |
| `sql/ase_test/` | Deux scripts créant la base `poc_db` avec des écarts volontaires (instance 1 et instance 2) |

Dossier à venir : `grafana/` (dashboards).

## Lancer une comparaison

Prérequis sur le bastion : `psql`, `isql` (client Open Client, instances résolues par le fichier `interfaces`), Python 3.8+.

1. Déclarer les deux instances ASE (un login par instance) :

```sql
INSERT INTO compa_ase.config_compa_ase (instance, host, port, login, password)
VALUES ('ASE1', 'ase01', 5000, '<login>', '<mot_de_passe>'),
       ('ASE2', 'ase02', 5000, '<login>', '<mot_de_passe>');
```

2. Lancer le script (mot de passe PostgreSQL par `PGPASSWORD` ou `~/.pgpass`) :

```
bash/compare_ase.sh -S ASE1 -D poc_db -s ASE2 -d poc_db -U <login_pg> -H <hote_pg> -p 5432 -n compa
```

| Option | Rôle |
|---|---|
| `-S` `-D` | Instance et base 1 |
| `-s` `-d` | Instance et base 2 |
| `-U` `-P` | Login et mot de passe PostgreSQL (`-P` est visible dans `ps`, préférer `PGPASSWORD`) |
| `-H` `-p` `-n` | Hôte, port et base PostgreSQL |
| `-k` | Conserver les CSV du run |

Le script vérifie le schéma PostgreSQL, lit les logins ASE dans `config_compa_ase`, crée ou retrouve le `refid`, ouvre un `run_id`, extrait les 7 modules des deux côtés, puis appelle `python/compare.py`. Le mot de passe ASE est transmis à `isql` par l'entrée standard, jamais en argument.

Les requêtes d'extraction sont dans `bash/queries/<module>.sql` : ce sont des requêtes de départ reprises de `Compare_instance_V3.sh`, **à remplacer par les requêtes validées**. Seules les colonnes décrites dans `docs/format_csv.md` comptent.

| Code retour | Signification |
|---|---|
| 0 | Comparaison terminée |
| 1 | Arguments invalides |
| 2 | CSV invalide (retour de `compare.py`) |
| 3 | Erreur PostgreSQL (retour de `compare.py`) |
| 10 | Outil manquant ou PostgreSQL injoignable |
| 11 | Schéma ou tables PostgreSQL absents : exécuter `sql/postgres/create_schema.sql` |
| 12 | Instance absente de `config_compa_ase` |
| 13 | Connexion ou extraction ASE en échec |

## Tester sans instance ASE

Un faux `isql` (`bash/tests/fake_bin/isql`), alimenté par les CSV factices, simule le comportement d'`isql` (invite `Password:`, colonnes remplies d'espaces, code retour 0 même en cas d'échec) :

```
export COMPA_TEST_DB=compa PGHOST=<hote> PGPORT=5432 PGUSER=<login>   # base où create_schema.sql a été exécuté
bash/tests/test_compare_ase.sh
```

## Tester `compare.py` seul

```
cd python
python3 compare.py --csv-dir tests/fixtures --dry-run -v      # 30 écarts attendus
python3 -m unittest discover -s tests -v                      # tests automatisés
```

Les CSV de `tests/fixtures` reproduisent les écarts des scripts `sql/ase_test`. Les tests d'intégration PostgreSQL sont activés avec `COMPA_TEST_PG=1` (voir l'en-tête de `python/tests/test_compare.py`).

## Création du schéma PostgreSQL

```
createdb -h <hote> -U <login> compa
psql -h <hote> -U <login> -d compa -f sql/postgres/create_schema.sql
psql -h <hote> -U <login> -d compa -c "ALTER ROLE grafana_ro LOGIN PASSWORD '<a_definir>'"
```

Le script est rejouable sans perte de données. Le rôle `grafana_ro` (lecture seule) est créé sans mot de passe : à définir manuellement, sans le versionner.

## Documentation

- [`docs/cahier_des_charges_POC.md`](docs/cahier_des_charges_POC.md) : cahier des charges du POC
- [`docs/format_csv.md`](docs/format_csv.md) : format des CSV produits par le script bash et lus par `compare.py`

## Sécurité

Aucun mot de passe ni fichier de configuration sensible ne doit être versionné.
Les logins ASE sont lus dans la table PostgreSQL `config_compa_ase`.
