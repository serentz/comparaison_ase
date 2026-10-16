<#
.SYNOPSIS
  Cree le reseau et les 4 VM Hyper-V du POC comparaison_ase (generation 2, Linux).

.DESCRIPTION
  - un commutateur interne + NAT (192.168.50.0/24 par defaut, passerelle .1 = le PC hote) ;
  - 4 VM : pg01 (Ubuntu), bastion (Ubuntu), ase01 et ase02 (CentOS) ;
  - chaque VM a son disque VHDX, son ISO monte, le demarrage UEFI sur l'ISO et Secure Boot au modele
    "Microsoft UEFI Certificate Authority" (obligatoire pour Linux en generation 2).
  Le script n'installe pas l'OS : demarrer les VM puis suivre docs/installation_vm.md.
  Il peut etre relance : ce qui existe deja est ignore.

.EXAMPLE
  .\create_vms.ps1 -UbuntuIso I:\ISO\ubuntu-24.04-live-server-amd64.iso -CentosIso I:\ISO\CentOS-Stream-9-latest-x86_64-dvd1.iso

  A lancer dans PowerShell ouvert en administrateur. Fonctionnalite Windows "Hyper-V" requise.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UbuntuIso,
    [Parameter(Mandatory)][string]$CentosIso,
    [string]$VmRoot     = 'I:\POC\HyperV',
    [string]$SwitchName = 'compa-net',
    [string]$Subnet     = '192.168.50',     # trois premiers octets, masque /24
    [switch]$Start                          # demarre les VM a la fin
)

$ErrorActionPreference = 'Stop'

foreach ($iso in @($UbuntuIso, $CentosIso)) {
    if (-not (Test-Path -LiteralPath $iso)) { throw "ISO introuvable : $iso" }
}
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw "Module Hyper-V absent. Activer la fonctionnalite Windows Hyper-V (Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All), redemarrer, relancer."
}

# Nom, ISO, vCPU, RAM (Go), disque (Go), derniere partie de l'adresse IP
$vms = @(
    @{ Name = 'pg01';    Iso = $UbuntuIso; Cpu = 2; MemGB = 4; DiskGB = 30; Ip = 11 },
    @{ Name = 'bastion'; Iso = $UbuntuIso; Cpu = 2; MemGB = 4; DiskGB = 30; Ip = 10 },
    @{ Name = 'ase01';   Iso = $CentosIso; Cpu = 2; MemGB = 4; DiskGB = 40; Ip = 21 },
    @{ Name = 'ase02';   Iso = $CentosIso; Cpu = 2; MemGB = 4; DiskGB = 40; Ip = 22 }
)

# --- Reseau : commutateur interne + NAT --------------------------------------
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Host "[+] Commutateur interne '$SwitchName'"
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
}
$alias = "vEthernet ($SwitchName)"
if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress "$Subnet.1" -ErrorAction SilentlyContinue)) {
    Write-Host "[+] Adresse $Subnet.1/24 sur $alias (passerelle des VM)"
    New-NetIPAddress -InterfaceAlias $alias -IPAddress "$Subnet.1" -PrefixLength 24 | Out-Null
}
$nat = Get-NetNat -ErrorAction SilentlyContinue
if (-not ($nat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq "$Subnet.0/24" })) {
    if ($nat) {
        Write-Warning "Un NAT existe deja ($($nat[0].InternalIPInterfaceAddressPrefix)) : Windows n'en autorise souvent qu'un. Si l'etape suivante echoue, supprimer l'ancien (Remove-NetNat) ou choisir un autre -Subnet."
    }
    Write-Host "[+] NAT $Subnet.0/24 (acces Internet des VM)"
    New-NetNat -Name $SwitchName -InternalIPInterfaceAddressPrefix "$Subnet.0/24" | Out-Null
}

# --- VM -----------------------------------------------------------------------
foreach ($v in $vms) {
    $name = $v.Name
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Write-Host "[=] VM $name existe deja, ignoree"
        continue
    }
    $dir = Join-Path $VmRoot $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Host "[+] VM $name ($($v.Cpu) vCPU, $($v.MemGB) Go, disque $($v.DiskGB) Go)"

    New-VM -Name $name -Generation 2 -Path $VmRoot `
        -MemoryStartupBytes ([uint64]$v.MemGB * 1GB) `
        -NewVHDPath (Join-Path $dir "$name.vhdx") -NewVHDSizeBytes ([uint64]$v.DiskGB * 1GB) `
        -SwitchName $SwitchName | Out-Null
    Set-VMProcessor -VMName $name -Count $v.Cpu
    Set-VMMemory -VMName $name -DynamicMemoryEnabled $false
    Set-VM -Name $name -AutomaticCheckpointsEnabled $false
    Enable-VMIntegrationService -VMName $name -Name 'Guest Service Interface'

    Add-VMDvdDrive -VMName $name -Path $v.Iso
    $dvd = Get-VMDvdDrive -VMName $name
    Set-VMFirmware -VMName $name -FirstBootDevice $dvd -EnableSecureBoot On `
        -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
}

# --- Resume ---------------------------------------------------------------------
Write-Host ""
Write-Host "Plan d'adressage (a configurer dans chaque OS, voir docs/installation_vm.md) :"
Write-Host "  passerelle : $Subnet.1 (PC hote)   DNS : 8.8.8.8 (ou le DNS de ton reseau)"
$vms | ForEach-Object { '  {0,-8} {1}.{2}' -f $_.Name, $Subnet, $_.Ip } | Write-Host

if ($Start) {
    $vms | ForEach-Object { Start-VM -Name $_.Name }
    Write-Host "VM demarrees : ouvrir chaque console (vmconnect localhost <nom>) pour lancer l'installation."
} else {
    Write-Host "Demarrage : Start-VM -Name pg01,bastion,ase01,ase02   puis   vmconnect localhost pg01"
}
