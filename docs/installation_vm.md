# Création des 4 VM sous Hyper-V

Le script `infra/hyperv/create_vms.ps1` crée le réseau et les 4 VM. L'installation des OS reste manuelle (une dizaine de minutes par VM).

| VM | OS | IP | vCPU / RAM / disque |
|---|---|---|---|
| `bastion` | Ubuntu Server 24.04 LTS | 192.168.50.10 | 2 / 4 Go / 30 Go |
| `pg01` | Ubuntu Server 24.04 LTS | 192.168.50.11 | 2 / 4 Go / 30 Go |
| `ase01` | CentOS | 192.168.50.21 | 2 / 4 Go / 40 Go |
| `ase02` | CentOS | 192.168.50.22 | 2 / 4 Go / 40 Go |

Le PC hôte est la passerelle (192.168.50.1) : il donne l'accès Internet aux VM par NAT et les VM sont joignables depuis lui.

## 1. Prérequis sur le PC

- Windows 10/11 Pro, Enterprise ou Education (Hyper-V n'existe pas en édition Famille).
- Hyper-V activé : PowerShell en administrateur, `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All`, puis redémarrage. Vérification : `Get-Command New-VM`.
- Mémoire : les 4 VM utilisent 16 Go. Prévoir 24 Go de RAM au PC, ou réduire `MemGB` dans le script (2 Go pour `pg01` et `bastion` suffisent pour le POC).
- Environ 140 Go de disque libre sur `I:` (les VHDX grossissent à l'usage).

## 2. ISO à télécharger

| OS | Où | Remarque |
|---|---|---|
| Ubuntu Server 24.04 LTS | ubuntu.com/download/server | ISO « live server » amd64 |
| CentOS | centos.org/download | **CentOS Stream 9**, ISO `dvd1` |

**Choix CentOS** : CentOS Linux 7 et CentOS Stream 8 sont en fin de vie. SAP ASE 16.0 Developer Edition est certifié sur des versions précises de RHEL : avant de télécharger, vérifie dans les notes de ta version d'ASE si RHEL 9 est supporté. Sinon, AlmaLinux 8 ou Rocky Linux 8 (clones de RHEL 8) sont les alternatives sûres ; le reste de ce guide s'applique pareil.

## 3. Lancer le script

PowerShell en administrateur, depuis le dossier du dépôt :

```
Set-ExecutionPolicy -Scope Process Bypass
.\infra\hyperv\create_vms.ps1 -UbuntuIso "I:\ISO\ubuntu-24.04-live-server-amd64.iso" -CentosIso "I:\ISO\CentOS-Stream-9-latest-x86_64-dvd1.iso"
```

Les deux options attendent le chemin complet du fichier `.iso`, pas celui du dossier. Le script crée :
- un commutateur interne `compa-net` et un NAT 192.168.50.0/24 ;
- les 4 VM en génération 2, mémoire fixe, ISO monté, démarrage sur l'ISO, Secure Boot avec le modèle *Microsoft UEFI Certificate Authority* (sans lui, Linux ne démarre pas en génération 2) ;
- aucun point de contrôle automatique.

Options : `-VmRoot` (défaut `I:\POC\HyperV`), `-Subnet`, `-SwitchName`, `-Start` (démarre les VM). Il peut être relancé : une VM déjà créée est ignorée.

## 4. Installer les OS

Démarrer une VM (`Start-VM -Name pg01`), ouvrir sa console (`vmconnect localhost pg01`), puis :

**Ubuntu** : choisir la langue et le clavier, installer *Ubuntu Server* (minimal), cocher **Install OpenSSH server**, créer ton utilisateur. Le commutateur interne n'a **pas de DHCP** : à l'écran *Network configuration*, sélectionner `eth0`, *Edit IPv4*, méthode *Manual*, puis saisir le sous-réseau `192.168.50.0/24`, l'adresse de la VM, la passerelle `192.168.50.1` et les DNS `8.8.8.8,1.1.1.1`. La section 5 ne sert alors que pour corriger a posteriori.

**CentOS** : choisir *Installation Destination* (disque entier, automatique), créer ton utilisateur avec droits administrateur (cocher « Make this user administrator »), mot de passe root au choix, logiciel *Server* (ou *Minimal Install*).

Après le redémarrage, éjecter l'ISO si l'installateur ne le fait pas : `Set-VMDvdDrive -VMName pg01 -Path $null`.

## 5. Adresses IP fixes

**Ubuntu** (`pg01`, `bastion`) : créer `/etc/netplan/01-compa.yaml` (adapter l'IP, vérifier le nom de l'interface avec `ip a`, souvent `eth0`), puis `sudo chmod 600 /etc/netplan/01-compa.yaml && sudo netplan apply` :

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [192.168.50.11/24]
      routes:
        - to: default
          via: 192.168.50.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

Supprimer ou renommer l'éventuel autre fichier de `/etc/netplan` qui active le DHCP sur la même interface.

**CentOS** (`ase01`, `ase02`) :

```
nmcli con show                       # repérer le nom de la connexion, ex. "eth0" ou "Wired connection 1"
sudo nmcli con mod "eth0" ipv4.method manual ipv4.addresses 192.168.50.21/24 \
     ipv4.gateway 192.168.50.1 ipv4.dns "8.8.8.8 1.1.1.1"
sudo nmcli con up "eth0"
```

Test depuis chaque VM : `ping -c2 192.168.50.1` puis `ping -c2 8.8.8.8` puis `ping -c2 ubuntu.com`.

## 6. Noms et accès SSH

Sur chaque VM, ajouter à `/etc/hosts` :

```
192.168.50.10  bastion
192.168.50.11  pg01
192.168.50.21  ase01
192.168.50.22  ase02
```

Hostname : `sudo hostnamectl set-hostname pg01` (adapter). Depuis ton PC : `ssh <utilisateur>@192.168.50.10`. Pour la suite, utilise `ssh-copy-id` depuis le bastion vers les 3 autres VM.

## 7. Pare-feu et mises à jour

- Ubuntu : `sudo apt update && sudo apt -y upgrade`. Le pare-feu `ufw` est inactif par défaut ; s'il est actif, ouvrir 22 et, selon la VM, 5432 (`pg01`) ou 3000 (`bastion`).
- CentOS : `sudo dnf -y update`. Ouvrir 5000/tcp sur `ase01` et `ase02` après l'installation d'ASE : `sudo firewall-cmd --permanent --add-port=5000/tcp && sudo firewall-cmd --reload`.

## 8. Point de contrôle

Quand les 4 OS sont installés, configurés et mis à jour, arrêter les VM et créer un point de contrôle pour pouvoir revenir en arrière :

```
Stop-VM -Name pg01,bastion,ase01,ase02
Checkpoint-VM -Name pg01,bastion,ase01,ase02 -SnapshotName os-pret
```

## 9. Suite

1. `pg01` : installer PostgreSQL, exécuter `sql/postgres/create_schema.sql` (voir `README.md`).
2. `ase01`, `ase02` : installer ASE 16.0 Developer Edition, puis exécuter les scripts de `sql/ase_test/`.
3. `bastion` : client `isql`, Python, `psql`, Grafana (`grafana/README.md`).
