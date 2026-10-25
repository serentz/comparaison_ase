# Changelog

## 0.2 - en cours (2026-10-18)

### Mode batch
- Option `-B` de `compare_ase.sh` : compare tous les couples actifs de la nouvelle table `compa_ase.batch_run` (`ds1`, `db1`, `ds2`, `db2`, `status_run`, `last_run`, `elapse`, `actif`) et y inscrit le resultat de chacun. Un couple en echec n'arrete pas les suivants ; code retour 14 si au moins un echec.
- Le traitement unitaire est une fonction (`run_unit`) : il ne quitte plus le script, le mode batch enchaine les couples.
- Schema : la table est creee par `create_schema.sql` (rejouable) ; l'archive `depot` attend 13 tables.

### Compatibilite
- `compare.py` fonctionne sous Python 3.6 (RHEL 8) : plus de `from __future__ import annotations` ni de `dataclasses`, `subprocess.run` sans `capture_output`. Teste sous 3.8 et 3.13 ; 3.6 verifie par analyse de syntaxe (pas d interpreteur 3.6 disponible pour l execution).

- `compare_ase.sh` : variable `COMPA_SOURCE_ENCODING` transmise a `compare.py --source-encoding` (le code source ASE n'est pas en UTF-8 : chez un client, serveur declare iso_1 mais code en cp850). Message d'erreur precisant l'octet fautif et la marche a suivre.

- Regles d'exclusion par defaut pour `inst_config` (schema et mode `--dry-run`) : `current audit table` ignore ; dimensionnement (`number of %`, `%memory%`, `%cache size%`, `%pipe max messages`, `permission cache entries`, `stack size`) marque `ATTENDU`. Les ecarts restent enregistres. Releve sur un client reel (38 ecarts prod/preprod). A desactiver via `actif = false` dans `exclusion_rules`.

### Deploiement par archives
- Dossier `Deploy/` : 4 archives (`compa_ase_depot`, `compa_ase_comparateur`, `compa_ase_grafana`, `compa_ase_serveurs_ase_test`), chacune avec `install.sh`, `verify.sh`, `LISEZMOI.md` et `SHA256SUMS`. Voir `docs/deploiement_archives.md`.
- `packaging/build_packages.sh` (archives reproductibles) et `packaging/test_packages.sh` (installation reelle du depot, du comparateur et de Grafana simule, puis comparaison avec le faux `isql` : 30 ecarts).
- `isql` (SAP Open Client) et les binaires ASE ne sont pas fournis : `verify.sh` du comparateur controle leur presence.

## 0.1 - 2026-10-16

Premiere version complete, validee de bout en bout sur deux serveurs ASE 16.0 SP03 PL10 reels
(Rocky 8.10) : un run sur la base de test `poc_db` donne 30 ecarts attendus, identiques a ceux des
fixtures, repartis sur les 7 modules. Captures : `images/R0.1/` (fixtures) et `images/R0.1/ase_reel/`
(run 7 sur ASE reels).

### Contenu
- Extraction ASE (`bash/compare_ase.sh`, requetes dans `bash/queries/`), comparaison et enregistrement
  (`python/compare.py`), schema PostgreSQL `compa_ase` (`sql/postgres/create_schema.sql`).
- 7 modules : inst_config, db_size (avec taille de page `@@maxpagesize`), db_options, obj_tables,
  obj_indexes (avec colonnes d'index), obj_code, obj_source (hash et diff ligne a ligne).
- Regles d'exclusion (`exclusion_rules`) : `statstamp`, `executable codesize + overhead` et
  `total logical memory` (valeur en cours) ignores par defaut.
- Grafana : 8 dashboards provisionnes (synthese + un par module), navigation entre modules.
- Infrastructure reproductible : creation des 4 VM Hyper-V sans intervention
  (`infra/hyperv/create_vms.ps1`), creation d'un serveur ASE (`infra/ase/build_server.sh`).

### Points constates sur ASE reel (corriges dans cette version)
- `isql -s '|'` ajoute un `|` en tete et en fin de ligne.
- Noms de parametres dupliques dans `sysconfigures` (ex. `default data cache`) : regroupement par nom.
- `index_col` : conversion en `varchar(255)` (sinon `isql` coupe la ligne) ; `',' + NULL` donne `','`.
- `dataserver` plante au demarrage (SIGSEGV dans `Snap::Validate`, CR 824104) : flag `-T11889`.
- Locale : `isql` exige une locale presente dans `locales.dat` (`en_US.UTF-8`).
- Prerequis Rocky 8 pour ASE : `libnsl`, `ncurses-compat-libs`, `libaio`.

### Limites connues
- Comparaison faite avec le login `sa` (login en lecture seule a creer).
- La taille de page n'apparait que lorsqu'elle differe entre les deux serveurs.
- `-T11889` desactive la validation de la fonction "simplified native access plans" : ne pas l'activer.
