# Création des 4 VM sous Hyper-V

Le script `infra/hyperv/create_vms.ps1` crée le réseau et les 4 VM **et installe les OS sans intervention** (Ubuntu par autoinstall, CentOS par kickstart). Il est rejouable : `-Destroy` supprime tout, on relance, on obtient les mêmes VM.

| VM | OS | IP | vCPU / RAM / disque |
|---|---|---|---|
| `bastion` | Ubuntu Server 24.04 LTS | 192.168.50.10 | 2 / 4 Go / 30 Go |
| `pg01` | Ubuntu Server 24.04 LTS | 192.168.50.11 | 2 / 4 Go / 30 Go |
| `ase01` | CentOS Stream 9 | 192.168.50.21 | 2 / 4 Go / 40 Go |
| `ase02` | CentOS Stream 9 | 192.168.50.22 | 2 / 4 Go / 40 Go |

Le PC hôte est la passerelle (192.168.50.1) : NAT vers Internet, VM joignables depuis le PC. Il n'y a **pas de DHCP** : les IP fixes sont écrites dans la configuration d'installation.

## 1. Prérequis

- Windows 10/11 Pro, Enterprise ou Education avec Hyper-V : `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` (PowerShell administrateur), puis redémarrage.
- 16 Go de RAM pour les 4 VM (24 Go au PC recommandés), environ 140 Go de disque libre.
- Deux ISO : **Ubuntu Server** (`ubuntu-24.04.5-live-server-amd64.iso`, releases.ubuntu.com/24.04/) et **CentOS Stream 9** (`dvd1`, centos.org/download). Pas l'ISO « desktop » d'Ubuntu.
- Un utilisateur et un mot de passe à choisir : ils seront identiques sur les 4 VM (`admin01` par défaut). Le mot de passe est demandé par le script, jamais écrit dans git.

ASE 16.0 est certifié sur des versions précises de RHEL : vérifier dans les notes de ta version qu'il accepte RHEL 9 (CentOS Stream 9). Sinon, AlmaLinux ou Rocky 8 : même procédure, autre ISO (le kickstart est identique).

## 2. Lancer

PowerShell **en administrateur**, depuis le dossier du dépôt :

```
Set-ExecutionPolicy -Scope Process Bypass
.\infra\hyperv\create_vms.ps1 -UbuntuIso "K:\ShareLinux\Image ISO\ubuntu-24.04.5-live-server-amd64.iso" -CentosIso "K:\ShareLinux\Image ISO\CentOS-Stream-9-20260316.0-x86_64-dvd1.iso"
```

Les deux options attendent le chemin complet du fichier `.iso`, pas celui du dossier.

Le script :
1. crée le commutateur interne `compa-net` et le NAT 192.168.50.0/24 ;
2. crée les 4 VM (génération 2, Secure Boot réglé pour Linux, démarrage disque puis DVD) ;
3. prépare pour chacune un petit disque de configuration (volume `CIDATA` pour Ubuntu, `OEMDRV` pour CentOS) : IP fixe, nom, utilisateur, SSH, disque entier, `/etc/hosts`, clavier français ;
4. démarre les VM, ouvre leurs consoles et attend (10 à 20 minutes) ;
5. quand les VM se sont éteintes seules, retire l'ISO et les disques de configuration (ils contiennent le mot de passe), redémarre les VM et attend SSH ;
6. affiche pour chaque VM la commande `ssh` à utiliser.

Pendant l'installation, deux gestes éventuels dans les consoles :
- **Ubuntu** : si la console demande `Continue with autoinstall?`, taper `yes` puis Entrée.
- **CentOS** : si le menu de démarrage attend, choisir *Install CentOS Stream 9* (le choix par défaut ajoute une vérification du média, plus lente mais sans conséquence).

Options utiles : `-AdminUser`, `-SshPublicKeyFile` (par défaut `~\.ssh\id_ed25519.pub` ou `id_rsa.pub` s'ils existent, la clé est installée sur les 4 VM), `-Keyboard` (défaut `fr`), `-VmRoot` (défaut `I:\POC\HyperV`), `-Subnet`, `-NoConsole`.

## 3. Recommencer de zéro

```
.\infra\hyperv\create_vms.ps1 -Destroy
```

Après confirmation (`OUI`), supprime les 4 VM et leurs disques. Le réseau est conservé. Relancer ensuite la commande de la section 2.

`-Only` limite l'opération à certaines VM, par exemple pour refaire seulement les serveurs ASE avec un autre OS :

```
.\infra\hyperv\create_vms.ps1 -Destroy -Only ase01,ase02
.\infra\hyperv\create_vms.ps1 -Only ase01,ase02 -CentosIso "K:\ShareLinux\Image ISO\<AlmaLinux-8 dvd>.iso"
```

## 4. En cas de problème

| Symptôme | Piste |
|---|---|
| `Il faut le chemin complet d'un fichier .iso` | Donner le fichier, pas le dossier |
| `VM deja presentes` | `-Destroy` puis relancer |
| Console noire au démarrage | Secure Boot : vérifier `Get-VMFirmware -VMName pg01` (modèle *MicrosoftUEFICertificateAuthority*) |
| L'installateur Ubuntu pose des questions (langue, réseau…) | La configuration n'a pas été lue : vérifier que la VM a 2 disques (`Get-VMHardDiskDrive -VMName pg01`) |
| L'installateur CentOS est graphique et interactif | Même vérification pour `ase01`. Le disque `OEMDRV` doit être présent |
| Le script s'arrête sur le délai | Regarder les consoles, relancer avec `-Destroy` puis sans |
| `SSH ne repond pas` en fin de script | Console de la VM : `ip a` doit montrer l'IP du tableau, `systemctl status ssh` (Ubuntu) ou `sshd` (CentOS) |

Après connexion : `ping 8.8.8.8` et `ping ubuntu.com` doivent répondre depuis chaque VM.

## 5. Point de contrôle

Quand les 4 VM répondent en SSH :

```
Stop-VM -Name pg01,bastion,ase01,ase02
Checkpoint-VM -Name pg01,bastion,ase01,ase02 -SnapshotName os-pret
Start-VM -Name pg01,bastion,ase01,ase02
```

## 6. Suite : PostgreSQL sur `pg01`

`ssh admin01@192.168.50.11`, puis :

```
sudo apt update && sudo apt -y upgrade
sudo apt install -y postgresql
sudo -u postgres psql -c "CREATE ROLE compa_app LOGIN CREATEROLE"
sudo -u postgres psql -c "\password compa_app"
sudo -u postgres createdb -O compa_app compa
sudo sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
echo "host compa all 192.168.50.0/24 scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
sudo systemctl restart postgresql
```

Depuis le PC, copier le schéma puis le charger sur `pg01` :

```
scp I:\POC\comparaison_ase\sql\postgres\create_schema.sql admin01@192.168.50.11:~/
```
```
psql -h 127.0.0.1 -U compa_app -d compa -f ~/create_schema.sql
psql -h 127.0.0.1 -U compa_app -d compa -c "\dt compa_ase.*"      # 12 tables
```

Rôle de lecture pour Grafana (créé `NOLOGIN` par le schéma) :

```
psql -h 127.0.0.1 -U compa_app -d compa -c "ALTER ROLE grafana_ro LOGIN"
psql -h 127.0.0.1 -U compa_app -d compa     # puis : \password grafana_ro
```

Ensuite : ASE 16.0 Developer Edition sur `ase01` et `ase02` (puis `sql/ase_test/`), client `isql`, Python et Grafana sur `bastion` (`grafana/README.md`).
