# compA_ase : archive « comparateur » ({{VERSION}})

Installe sur la machine qui lance les comparaisons (`bastion`, 192.168.50.10) :

| Composant | Rôle |
|---|---|
| `compare_ase.sh` + 7 requêtes SQL | extrait avec `isql` la configuration et les objets des deux couples instance/base ASE |
| `compare.py` | compare les extractions et enregistre les écarts dans la base de résultats |
| commande `compa_ase` | lance une comparaison avec l'accès à la base de résultats déjà configuré |
| `compa_ase-planifie` | lance les comparaisons listées dans `/etc/compa_ase/planifie.conf` (timer systemd ou cron) |

À installer après l'archive `compa_ase_depot`.

> **`isql` n'est pas fourni.** C'est le client SAP Open Client (livré avec SAP ASE), un logiciel SAP qui ne peut pas être redistribué. Il doit être installé avant, avec un fichier `interfaces` qui décrit les instances ASE (`isql -S <nom>` doit se connecter).

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh`, `verify.sh` | installation (rejouable) et contrôles |
| `bash/compare_ase.sh`, `bash/queries/*.sql` | script d'orchestration et 7 requêtes d'extraction (une par module) |
| `python/compare.py` | comparaison (bibliothèque standard Python, **aucun paquet pip** : pas de `manifeste.txt`) |
| `systemd/`, `cron/` | planification quotidienne : timer systemd, ou fichier cron équivalent |
| `scripts/` | `compa_ase-planifie.sh`, modèle `planifie.conf.example`, `compa_ase.env.example` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04, `sudo`, accès `apt` (paquets `postgresql-client` et `python3`).
- `isql` (SAP Open Client) installé et son fichier `interfaces` à jour (`SYBASE_ENV_FILE` = chemin de `SYBASE.sh`).
- La base de résultats installée (archive depot) et joignable : IP, port, mot de passe de `compa_app`.
- Les instances ASE à comparer joignables et déclarées dans `config_compa_ase` (archive depot, `declarer-instance.sh`).

## 2. Installation

```bash
tar xzf compa_ase_comparateur.tgz
cd compa_ase_comparateur
sha256sum -c SHA256SUMS --quiet && echo "archive intacte"

cp scripts/compa_ase.env.example scripts/compa_ase.env
nano scripts/compa_ase.env          # accès à la base de résultats, SYBASE_ENV_FILE

sudo ./install.sh
sudo ./verify.sh
```

### Paramètres (`scripts/compa_ase.env`)

| Variable | Rôle |
|---|---|
| `PG_HOST`, `PG_PORT`, `PG_DB` | base de résultats (`192.168.50.11`, 5432, `compa`) |
| `PG_USER`, `PG_PASSWORD` | login propriétaire (`compa_app`) et son mot de passe (celui de l'archive depot) |
| `INSTALL_DIR` | dossier des programmes (`/opt/compa_ase`) |
| `RUN_USER` | login Linux qui lance les comparaisons (vide : celui qui a lancé `sudo`). **Seul lui peut lire `/etc/compa_ase/compa_ase.env`** |
| `SYBASE_ENV_FILE` | script `SYBASE.sh` du client SAP (chemin de `isql` et variable `SYBASE`) ; vide si `isql` est déjà dans le `PATH` |
| `ASE_LANG` | locale des sessions `isql` (`en_US.UTF-8`) |
| `ENABLE_SCHEDULE` | `1` active le timer de comparaison quotidienne |

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt update && sudo apt install -y postgresql-client python3
```

**Programmes** (aucun venv, aucune dépendance)

```bash
sudo mkdir -p /opt/compa_ase/bash/queries /opt/compa_ase/python
sudo install -m 0755 bash/compare_ase.sh /opt/compa_ase/bash/ && sudo install -m 0644 bash/queries/*.sql /opt/compa_ase/bash/queries/
sudo install -m 0755 python/compare.py /opt/compa_ase/python/
```

**SQL** : aucun à exécuter ici. Le script lit les logins des instances ASE dans la base de résultats (`config_compa_ase`) et y écrit les écarts.

**Utilisation**

```bash
compa_ase -S ASE1 -D poc_db -s ASE2 -d poc_db -k      # -k : conserve les CSV pour contrôle (premier run)
compa_ase -h                                          # aide
```

Équivalent sans la commande `compa_ase` : `. /opt/sap/SYBASE.sh; PGPASSWORD=... /opt/compa_ase/bash/compare_ase.sh -S ASE1 -D poc_db -s ASE2 -d poc_db -U compa_app -H 192.168.50.11 -p 5432 -n compa`. Sur les deux instances de test (`archive serveurs_ase_test`), le résultat attendu est de **30 écarts**. Liste de contrôle de première exécution et interprétation des écarts : `docs/premiere_execution.md` du dépôt comparaison_ase.

## 4. Planification (systemd, ou cron)

Les comparaisons à planifier sont listées dans `/etc/compa_ase/planifie.conf` (une ligne par comparaison : `INSTANCE1 BASE1 INSTANCE2 BASE2`) :

```
ASE1 poc_db ASE2 poc_db
```

**Timer systemd** : tous les jours à 02:30. `install.sh` l'installe et l'active si `ENABLE_SCHEDULE=1`. À la main :

```bash
sudo cp systemd/compa_ase-planifie.service systemd/compa_ase-planifie.timer /etc/systemd/system/
sudo sed -i 's/^User=.*/User=<RUN_USER>/' /etc/systemd/system/compa_ase-planifie.service
sudo systemctl daemon-reload && sudo systemctl enable --now compa_ase-planifie.timer
systemctl list-timers 'compa_ase-*'          # prochaine exécution
journalctl -u compa_ase-planifie -n 20       # dernière exécution
```

**Équivalent cron** (à la place du timer, jamais en plus) :

```bash
sudo sed 's/RUN_USER/<login>/' cron/compa_ase.cron | sudo tee /etc/cron.d/compa_ase
```

soit la ligne : `30 2 * * * <login> /usr/local/bin/compa_ase-planifie 2>&1 | logger -t compa_ase-planifie`.

## 5. Mise à jour et désinstallation

- **Mise à jour** : extraire la nouvelle archive, recopier `scripts/compa_ase.env`, relancer `sudo ./install.sh`.
- **Désinstallation** :

```bash
sudo systemctl disable --now compa_ase-planifie.timer 2>/dev/null
sudo rm -f /etc/systemd/system/compa_ase-planifie.* /etc/cron.d/compa_ase /usr/local/bin/compa_ase /usr/local/bin/compa_ase-planifie
sudo rm -r /opt/compa_ase /etc/compa_ase && sudo systemctl daemon-reload
```

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| `compa_ase` : « illisible (réservé à ... ) » | lancer la commande avec le login `RUN_USER` |
| Code retour 10 | outil manquant (`isql` : `SYBASE_ENV_FILE`) ou base de résultats injoignable (`verify.sh`) |
| `isql` : locale refusée | `ASE_LANG` doit exister dans `locales.dat` de l'ASE (`en_US.UTF-8`) |
| Code retour 11 | schéma absent : relancer `install.sh` de l'archive depot |
| Code retour 12 | instance absente de `config_compa_ase` : `declarer-instance.sh` (archive depot) |
| Code retour 13 | connexion `isql` ou extraction ASE en échec : nom dans `interfaces`, hôte, port, login/mot de passe dans `config_compa_ase`, instance démarrée |
