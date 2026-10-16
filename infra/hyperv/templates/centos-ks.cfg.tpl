# Installation automatique de CentOS Stream (kickstart) - genere par create_vms.ps1
text
poweroff
cdrom
lang fr_FR.UTF-8
keyboard --vckeymap={{KEYBOARD}} --xlayouts='{{KEYBOARD}}'
timezone Europe/Paris --utc
network --bootproto=static --device=link --ip={{IP}} --netmask=255.255.255.0 --gateway={{GATEWAY}} --nameserver=8.8.8.8,1.1.1.1 --hostname={{NAME}} --activate
rootpw --lock
user --name={{USER}} --groups=wheel --plaintext --password={{PASSWORD}}
{{SSHKEYS}}
firstboot --disable
firewall --enabled --ssh --port=5000:tcp
services --enabled=sshd
ignoredisk --only-use=sda
zerombr
clearpart --all --initlabel --drives=sda
autopart --type=lvm
bootloader --location=mbr

%packages
@^minimal-environment
openssh-server
%end

%post
cat >> /etc/hosts <<'EOT'
{{HOSTS}}
EOT
%end
