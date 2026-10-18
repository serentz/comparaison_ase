# compA_ase : archive « depot » ({{VERSION}})

Installe la **base de résultats** : PostgreSQL, la base `compa` et le schéma `compa_ase` (références, runs, configuration des instances ASE, règles d'exclusion, 7 tables `diff_<module>`, vues Grafana). C'est là que le comparateur écrit et que Grafana lit.

À installer **en premier**. Machine du POC : `pg01` (192.168.50.11).

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh` | installation complète (rejouable) |
| `verify.sh` | contrôles après installation |
| `sql/create_schema.sql` | schéma `compa_ase` (rejouable sans perte de données) |
| `scripts/declarer-instance.sh` | déclare une instance ASE à comparer dans `compa_ase.config_compa_ase` |
| `scripts/compa_ase.env.example` | paramètres à copier en `compa_ase.env` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04 (ou Debian), accès à `apt`, un compte avec `sudo`.
- Les IP du réseau : le comparateur et Grafana doivent joindre cette machine sur le port PostgreSQL (`ALLOW_SUBNET`).

## 2. Installation

```bash
tar xzf compa_ase_depot.tgz
cd compa_ase_depot
sha256sum -c SHA256SUMS --quiet && echo "archive intacte"

cp scripts/compa_ase.env.example scripts/compa_ase.env
nano scripts/compa_ase.env          # mots de passe, réseau

sudo ./install.sh
sudo ./verify.sh
```

### Paramètres (`scripts/compa_ase.env`)

| Variable | Rôle |
|---|---|
| `PG_PORT` | port du cluster qui héberge la base (5432) |
| `DEPOT_DB`, `DEPOT_OWNER` | nom de la base (`compa`) et login propriétaire (`compa_app`), utilisé par le comparateur |
| `DEPOT_OWNER_PASSWORD` | mot de passe de ce login (à reprendre dans l'archive comparateur) |
| `GRAFANA_RO_PASSWORD` | mot de passe de `grafana_ro`, lecture seule (à reprendre dans l'archive grafana) |
| `ALLOW_SUBNET` | réseau autorisé à joindre la base (`192.168.50.0/24`) |

Mots de passe : 8 caractères minimum, lettres, chiffres et `. _ @ % + = -` seulement.

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt update && sudo apt install -y postgresql
```

**Réseau PostgreSQL** (version 16, cluster `main` ; adapter) :

```bash
echo "listen_addresses = '*'" | sudo tee /etc/postgresql/16/main/conf.d/compa_ase.conf
echo "host compa compa_app 192.168.50.0/24 scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
echo "host compa grafana_ro 192.168.50.0/24 scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
sudo systemctl restart postgresql
```

**SQL** : login, base, schéma, rôle Grafana.

```bash
sudo -u postgres psql -c "CREATE ROLE compa_app LOGIN CREATEROLE PASSWORD '<mdp>'"
sudo -u postgres psql -c "CREATE DATABASE compa OWNER compa_app"
PGOPTIONS="-c role=compa_app" sudo -E -u postgres psql -d compa < sql/create_schema.sql    # le « < » est voulu : postgres ne lit pas /home
sudo -u postgres psql -d compa -c "ALTER ROLE grafana_ro LOGIN PASSWORD '<mdp>'"
```

## 4. Déclarer les instances ASE à comparer

Chaque instance ASE comparée est enregistrée sous un nom (`ASE1`, `ASE2`...) avec son hôte, son port et son login (`sa` dans le POC), utilisé ensuite avec `-S` et `-s`. **Le nom doit être celui du fichier `interfaces` du comparateur** (`isql -S <nom>`). Le mot de passe est lu dans `INSTANCE_PASSWORD` ou demandé :

```bash
sudo ./scripts/declarer-instance.sh ASE1 ase01 5000 sa "instance ASE de test 1"
sudo ./scripts/declarer-instance.sh ASE2 ase02 5000 sa "instance ASE de test 2"
```

`config_compa_ase` contient des mots de passe en clair : jamais lisible par `grafana_ro`, jamais versionné.

## 5. Planification

Rien à planifier ici : ce sont des tables PostgreSQL. Les comparaisons se planifient sur la machine du comparateur (archive `compa_ase_comparateur`). Pour sauvegarder les résultats : `sudo -u postgres pg_dump -Fc compa > compa.dump`.

## 6. Mise à jour et désinstallation

- **Mise à jour** : extraire la nouvelle archive, recopier `scripts/compa_ase.env`, relancer `sudo ./install.sh` : le schéma est rejoué sans perte de données.
- **Désinstallation** (⚠ détruit les résultats) : `sudo -u postgres psql -c "DROP DATABASE compa"`, puis `DROP ROLE compa_app; DROP ROLE grafana_ro;`, et retirer les lignes ajoutées à `conf.d/compa_ase.conf` et `pg_hba.conf` (bloc `COMPA_PG depot`).

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| « Aucun cluster PostgreSQL n'écoute sur le port » | `pg_lsclusters` ; adapter `PG_PORT` |
| Le comparateur ne se connecte pas | `ALLOW_SUBNET`, pare-feu, `sudo -u postgres psql -c "SHOW listen_addresses"` doit donner `*` |
| `verify.sh` : « 12 tables » en échec | relancer `install.sh` et lire les erreurs SQL |
