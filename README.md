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
| `sql/postgres/` | `create_schema.sql` : schéma PostgreSQL `compa_ase` (références, runs, configuration, exclusions, 7 tables `diff_<module>`, vues Grafana) |
| `sql/ase_test/` | Deux scripts créant la base `poc_db` avec des écarts volontaires (instance 1 et instance 2) |

Dossiers à venir : `python/` (comparaison), `grafana/` (dashboards).

## Création du schéma PostgreSQL

```
createdb -h <hote> -U <login> compa
psql -h <hote> -U <login> -d compa -f sql/postgres/create_schema.sql
psql -h <hote> -U <login> -d compa -c "ALTER ROLE grafana_ro LOGIN PASSWORD '<a_definir>'"
```

Le script est rejouable sans perte de données. Le rôle `grafana_ro` (lecture seule) est créé sans mot de passe : à définir manuellement, sans le versionner.

## Documentation

Voir [`docs/cahier_des_charges_POC.md`](docs/cahier_des_charges_POC.md).

## Sécurité

Aucun mot de passe ni fichier de configuration sensible ne doit être versionné.
Les logins ASE sont lus dans la table PostgreSQL `config_compa_ase`.
