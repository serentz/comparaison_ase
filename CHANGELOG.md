# Changelog

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
