# compA_ase : archive « serveurs ASE de test » ({{VERSION}})

**POC uniquement.** Crée un serveur SAP ASE 16.0 (Express/Developer) et y charge la base `poc_db`, qui contient des écarts voulus entre l'instance 1 et l'instance 2 : le comparateur doit en trouver **30**. À installer sur `ase01` (instance 1) puis sur `ase02` (instance 2) ; machines du POC : 192.168.50.21 et .22.

> **Les binaires SAP ASE ne sont pas fournis** (logiciel SAP, non redistribuable). Télécharger SAP ASE 16.0 sur le site SAP, le décompresser dans `SYBASE_DIR` (`/opt/sap`) en tant que propriétaire de ce dossier, avant d'installer cette archive.

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh` | bibliothèques système, création du serveur, chargement de `poc_db` (rejouable) |
| `verify.sh` | contrôles (serveur répond, `poc_db` présente) |
| `infra/ase/build_server.sh` | crée le serveur via `srvbuildres` ; contournement du bug CR 824104 (`dataserver -T11889`) ; mot de passe `sa` saisi au clavier |
| `scripts/charger-base-test.sh` | charge `poc_db` (⚠ la supprime d'abord si elle existe) |
| `sql/ase_test/01_*.sql`, `02_*.sql` | création de `poc_db` pour l'instance 1 et pour l'instance 2 |
| `scripts/compa_ase.env.example` | paramètres à copier en `compa_ase.env` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Rocky Linux 8 (testé en 8.10) ou équivalent RHEL ; `sudo` ; 4 Go de RAM, 2 vCPU.
- SAP ASE 16.0 décompressé dans `SYBASE_DIR` (le fichier `SYBASE.sh` doit y être).
- Bibliothèques : `libnsl`, `ncurses-compat-libs`, `libaio` (installées par `install.sh` avec `dnf`).

## 2. Installation

```bash
tar xzf compa_ase_serveurs_ase_test.tgz
cd compa_ase_serveurs_ase_test
sha256sum -c SHA256SUMS --quiet && echo "archive intacte"

cp scripts/compa_ase.env.example scripts/compa_ase.env
nano scripts/compa_ase.env          # ASE_NAME=ASE1 et ASE_INSTANCE=1 sur ase01 ; ASE2 et 2 sur ase02

sudo ./install.sh                   # demande le mot de passe sa (8 caractères minimum)
./verify.sh
```

### Paramètres (`scripts/compa_ase.env`)

| Variable | Rôle |
|---|---|
| `SYBASE_DIR` | dossier de SAP ASE (`/opt/sap`) |
| `ASE_NAME`, `ASE_PORT` | nom du serveur (`ASE1`/`ASE2`) et port TCP (5000) |
| `ASE_PAGE_SIZE` | taille de page, **identique sur les deux serveurs** (`4k`) ; la comparaison `db_size` en tient compte |
| `ASE_INSTANCE` | `1` ou `2` : script de base de test à charger |
| `ASE_USER` | propriétaire Linux de `SYBASE_DIR` (vide : propriétaire du dossier) |

Le mot de passe `sa` n'est jamais dans un fichier : saisi au clavier, ou variable `ASE_SA_PASSWORD` pour `charger-base-test.sh` et `verify.sh`.

## 3. Ce que fait `install.sh`, et son équivalent à la main

```bash
sudo dnf install -y libnsl ncurses-compat-libs libaio
sudo -u <proprietaire> SYBASE_DIR=/opt/sap bash infra/ase/build_server.sh ASE1 5000 4k    # demande le mot de passe sa
. /opt/sap/SYBASE.sh
isql -Usa -SASE1 -i sql/ase_test/01_create_poc_db_instance1.sql -o 01.log                 # instance 2 : 02_..., ASE2
```

## 4. Après l'installation : déclarer les instances

Sur la machine du comparateur, ajouter `ASE1` et `ASE2` au fichier `interfaces` (hôte `ase01` / `ase02`, port 5000), puis les déclarer dans la base de résultats (`scripts/declarer-instance.sh` de l'archive depot, login `sa`).

## 5. Mise à jour et désinstallation

- **Mise à jour** : relancer `sudo ./install.sh` ne recrée pas le serveur ; il recharge `poc_db` (⚠ remise à zéro de cette base).
- **Désinstallation** : `isql -Usa -SASE1`, puis `shutdown` ; supprimer le contenu de `$SYBASE_DIR/data` et l'entrée `ASE1` de `$SYBASE_DIR/interfaces`. Le contournement CR 824104 reste en place (`dataserver.bin` + script `dataserver`).

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| `dataserver` plante au démarrage (SIGSEGV, `Snap::Validate`) | contournement CR 824104 : `build_server.sh` le met en place ; sinon vérifier `$SYBASE/$SYBASE_ASE/bin/dataserver` (script) et `dataserver.bin` |
| Erreurs de bibliothèques (`libnsl.so.1`, `libaio`, `libtinfo`/`ncurses`) | installer `libnsl`, `ncurses-compat-libs`, `libaio` |
| `isql` : locale refusée | utiliser `LANG=en_US.UTF-8` (déjà fait par `charger-base-test.sh`) |
| Pas assez de mémoire | 4 Go par VM ASE ; arrêter les autres VM de l'hôte |

Cette archive n'est pas testée automatiquement (pas d'ASE dans l'environnement de test) : seuls le contenu, la syntaxe des scripts et les fichiers cités sont vérifiés. Une première exécution sur les VM réelles est à valider.
