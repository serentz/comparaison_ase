# Déploiement par archives

> **Statut : écrit le 2026-10-18, à valider sur VM neuves.** Testé en local : construction reproductible, contenu des archives, syntaxe des scripts, et **installation réelle du dépôt de résultats, du comparateur et de Grafana (simulé) suivie d'une comparaison** avec le faux `isql` du dépôt (cluster PostgreSQL temporaire, 30 écarts attendus, comparaison planifiée). **Non testé** : l'archive `serveurs_ase_test` (aucun ASE dans l'environnement de test), l'installation des paquets `apt`/`dnf`, systemd, l'ouverture des dashboards dans un Grafana réel.

Au lieu de cloner le dépôt sur chaque VM, on dépose **une archive par fonction** (dossier `Deploy/`). Chaque archive contient ses scripts `install.sh` et `verify.sh`, un `LISEZMOI.md` (composants, SQL, planification systemd et cron, vérification, mise à jour, désinstallation, dépannage) et `SHA256SUMS`.

| Archive | Machine du POC | Contenu |
|---|---|---|
| `compa_ase_depot.tgz` | `pg01` | PostgreSQL, base `compa`, schéma `compa_ase`, rôle Grafana, déclaration des instances ASE à comparer |
| `compa_ase_comparateur.tgz` | `bastion` | `compare_ase.sh`, 7 requêtes, `compare.py`, commande `compa_ase`, comparaison planifiée (timer systemd ou cron) |
| `compa_ase_grafana.tgz` | `bastion` | Grafana, source de données, 8 dashboards |
| `compa_ase_serveurs_ase_test.tgz` | `ase01`, `ase02` | création d'un serveur ASE et de la base `poc_db` avec écarts voulus : **POC uniquement** |

Pas de `manifeste.txt` ici : `compare.py` n'utilise que la bibliothèque standard Python (aucun venv, aucun paquet pip).

## Ce qui n'est pas dans les archives

Les logiciels SAP ne sont pas redistribuables :

- **SAP ASE 16.0** (binaires) : à décompresser dans `/opt/sap` avant l'archive `serveurs_ase_test`.
- **`isql` (SAP Open Client)** : à installer sur la machine du comparateur, avec un fichier `interfaces` qui décrit les instances. `SYBASE_ENV_FILE` (chemin de `SYBASE.sh`) le rend accessible à la commande `compa_ase`. `verify.sh` du comparateur échoue si `isql` est introuvable.

## Ordre d'installation

1. `compa_ase_depot` sur la machine PostgreSQL ;
2. (POC) `compa_ase_serveurs_ase_test` sur `ase01` (`ASE_NAME=ASE1`, `ASE_INSTANCE=1`) puis sur `ase02` (`ASE2`, `2`) ;
3. `declarer-instance.sh ASE1 ase01 5000 sa` et `ASE2 ase02 5000 sa` (archive depot) ;
4. `compa_ase_comparateur` sur la machine qui lance les comparaisons ;
5. `compa_ase_grafana` (même machine ou autre).

Sur chaque machine : `tar xzf`, `cp scripts/compa_ase.env.example scripts/compa_ase.env`, éditer, `sudo ./install.sh`, `sudo ./verify.sh`. Les mots de passe (`compa_app`, `grafana_ro`) doivent être **identiques** dans les archives qui les partagent. Le mot de passe `sa` n'est jamais écrit dans un fichier.

## Cohabitation avec compA_pg

Les deux projets peuvent partager la base `compa` (schémas `compa_pg` et `compa_ase`) et le même Grafana : variables `COMPA_PG_*` et bloc géré `COMPA_PG env` communs (mêmes valeurs), dossiers de dashboards et fichiers de provisioning distincts.

## Construire les archives

```bash
packaging/build_packages.sh v0.2        # -> Deploy/*.tgz et Deploy/SHA256SUMS
```

Nécessite `bash`, `tar`, `gzip`, `sha256sum` (Git Bash ou WSL sous Windows). Les archives sont **reproductibles** : mêmes sources, mêmes octets. Elles sont générées depuis les fichiers du dépôt (une seule source de vérité) ; ce qui est propre aux archives est dans `packaging/templates/`. Les fichiers de `Deploy/` ne se modifient pas à la main : modifier la source, reconstruire, recommiter.

## Tests

```bash
sudo packaging/test_packages.sh
```

1. Contrôle des archives : contenu, empreintes, reproductibilité, syntaxe des scripts, JSON, Python, fichiers cités par les scripts.
2. Intégration (root et PostgreSQL Debian requis, sinon `SKIP`) : installation réelle du dépôt de résultats (cluster temporaire `compadepot`, port 5448), déclaration de `ASE1`/`ASE2`, installation du comparateur (dossiers temporaires), comparaison `ASE1/poc_db` contre `ASE2/poc_db` avec le faux `isql` (`bash/tests/fake_bin`) : **30 écarts**, comparaison planifiée, `verify.sh` en échec sans `isql`, installation de Grafana (commandes simulées), rejeu de chaque installation.

## Ce que cette version change dans le dépôt

Aucun fichier existant n'est modifié : le dossier `Deploy/` et le dossier `packaging/` sont ajoutés. Le chemin « cloner le dépôt » (README, « Lancer une comparaison ») fonctionne comme avant.
