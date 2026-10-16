# Première exécution sur un nouvel environnement

Liste de contrôle à suivre avant de lancer `bash/compare_ase.sh` sur des serveurs ASE autres que ceux du POC.
Le script ne fait que des lectures sur ASE (requêtes `select`, rien n'est écrit dans les bases comparées) ;
seul le schéma PostgreSQL `compa_ase` reçoit des données.

## 1. Poste d'exécution

- [ ] `isql` (Open Client) fonctionne, `psql` et Python 3.8+ sont installés.
- [ ] Les deux instances sont dans le fichier `interfaces` du poste (`isql -S <instance>` se connecte).
- [ ] Locale : `isql` refuse une locale absente de `$SYBASE/locales/locales.dat`
      (`Locale name "fr_FR.UTF-8" doesn't exist`). Le script force `en_US.UTF-8` ; si elle n'existe pas là-bas,
      choisis-en une présente dans `locales.dat` et passe-la : `ASE_LANG=<locale> bash bash/compare_ase.sh ...`.
- [ ] Les fichiers viennent d'un dépôt Git ou d'un `scp` sans fins de ligne Windows (`dos2unix` sinon).

## 2. Droits du login ASE

Un login **en lecture seule** suffit. Vérifie avec ce login qu'il peut lire :

- dans `master` : `sysdatabases`, `sysusages`, `sysconfigures`, `syscurconfigs` ;
- dans chaque base comparée : `sysobjects`, `sysindexes`, `sysstatistics`, `syscolumns`, `syscomments`.

Si le texte des procédures est masqué (`sp_hidetext`), `obj_source` ne ramènera rien pour ces objets :
le module les verra comme vides des deux côtés. Compare le nombre de lignes de `r1_obj_source.csv`
avec celui de `r1_obj_code.csv` pour t'en rendre compte.

## 3. Premier run : toujours avec `-k`

```
bash bash/compare_ase.sh -S <inst1> -D <base1> -s <inst2> -d <base2> -U <login_pg> -H <hote_pg> -p 5432 -n <base_pg> -k
```

`-k` conserve les CSV dans `/tmp/compa_ase_run<N>_*`. Contrôle-les avant d'interpréter les écarts :

```
D=$(ls -d /tmp/compa_ase_run*/ | tail -1)
wc -l $D/*.csv                                   # volumétrie par module
for f in $D/r1_*.csv; do echo $f; awk -F'|' '{print NF}' $f | sort | uniq -c; done   # nombre de colonnes par ligne
head -3 $D/r1_inst_config.csv | cat -A           # espaces, retours chariot, '|' en trop
```

Chaque fichier doit avoir **le même nombre de colonnes sur toutes les lignes**, celui de son en-tête
(voir `docs/format_csv.md`). Les erreurs vues sur le POC viennent toutes d'ici : `isql` qui ajoute un `|`
en début et fin de ligne, noms de paramètres en double, lignes coupées.

## 4. Volumétrie et durée

- `obj_source` extrait le code source en hexadécimal, par morceaux de `syscomments` : sur une base riche en
  procédures, le CSV peut être gros et l'extraction longue. Teste d'abord sur une base modeste.
- `obj_tables` et `obj_indexes` parcourent tout le catalogue de la base.
- Lance le premier run hors heures de pointe, les catalogues étant interrogés en lecture.

## 5. Interpréter les premiers écarts

Un premier run sur de vrais serveurs remonte toujours du bruit. Lis la liste avant de conclure, puis écarte
ce qui est sans intérêt avec `compa_ase.exclusion_rules` (documenté dans `docs/format_csv.md`, section 5).
Déjà ignorés par défaut : `statstamp` des index, `value_in_use` de `executable codesize + overhead` et de
`total logical memory`. Tu trouveras d'autres mesures calculées par ASE dans `inst_config`.

## 6. Particularités ASE à connaître

- Le flag `-T11889` du POC contourne un défaut propre à la version testée (CR 824104). **Ne le recopie pas**
  sur d'autres serveurs sans en avoir besoin : il désactive une validation interne d'ASE.
- Une taille de page différente entre les deux serveurs fait varier `size_mb` : lis l'écart `page_size`
  avec ceux de `db_size`.
- Les requêtes de `bash/queries/` sont à adapter si une version d'ASE renomme ou retire une colonne système :
  l'erreur `isql` s'affiche (`Msg ..., Level ...`) et le script s'arrête sur le module concerné.

## 7. Sécurité

- [ ] Login ASE dédié, en lecture seule (pas `sa`), mot de passe saisi hors historique shell.
- [ ] Les CSV conservés avec `-k` contiennent le **code source** de la base : supprime-les après contrôle
      (`rm -r /tmp/compa_ase_run*`).
- [ ] `compa_ase.config_compa_ase` contient des mots de passe : jamais lisible par Grafana (déjà le cas pour
      `grafana_ro`), jamais versionnée.
- [ ] Mot de passe PostgreSQL par `PGPASSWORD` ou `~/.pgpass`, jamais en option `-P` (visible dans `ps`).

## 8. Grafana

Les dashboards sont générés par `grafana/build_dashboards.py` et supposent la source de données de
`grafana/provisioning/datasources/compa_ase.yaml` (uid `compa_ase_pg`). Si ton Grafana a déjà ses propres
conventions (dossiers, source de données, variables), adapte le générateur et régénère les JSON plutôt que de
modifier les fichiers à la main.
