# comparaison_ase

POC de comparaison de deux couples **instance / base de données** SAP ASE 16.0.
Les écarts sont enregistrés dans PostgreSQL et affichés dans Grafana (un dashboard par module).

## Modules comparés

`inst_config`, `db_size`, `db_options`, `obj_tables`, `obj_indexes`, `obj_code`, `obj_source`

## Contenu du dépôt

| Dossier | Contenu |
|---|---|
| `bash/` | Extraction des données ASE via `isql` (`Compare_instance_V3.sh`, à alléger) |
| `docs/` | Cahier des charges du POC |
| `python/` | `compare.py` (comparaison des CSV et insertion dans PostgreSQL) et `tests/` (tests automatisés, CSV factices) |
| `sql/postgres/` | `create_schema.sql` : schéma PostgreSQL `compa_ase` (références, runs, configuration, exclusions, 7 tables `diff_<module>`, vues Grafana) |
| `sql/ase_test/` | Deux scripts créant la base `poc_db` avec des écarts volontaires (instance 1 et instance 2) |

Dossier à venir : `grafana/` (dashboards).

## Tester `compare.py` sans instance ASE

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
