#!/usr/bin/env bash
# Cree un serveur ASE 16.0 (Express) en mode texte avec srvbuildres.
# Usage : build_server.sh NOM_SERVEUR [PORT] [PAGE_SIZE]     ex : build_server.sh ASE1 5000 4k
# Le mot de passe sa est saisi au clavier : jamais en argument, jamais versionne.
# Le fichier de reponses (qui le contient) est cree en 600 puis supprime en sortie.
set -euo pipefail

NAME="${1:?Usage: $0 NOM_SERVEUR [PORT] [PAGE_SIZE]}"
PORT="${2:-5000}"
PAGE="${3:-4k}"
SYBASE_DIR="${SYBASE_DIR:-/opt/sap}"
DATA_DIR="${DATA_DIR:-$SYBASE_DIR/data}"

# shellcheck disable=SC1091
source "$SYBASE_DIR/SYBASE.sh"

read -rsp "Mot de passe sa pour $NAME : " PW; echo
read -rsp "Confirmer : " PW2; echo
[ "$PW" = "$PW2" ] || { echo "Les mots de passe different." >&2; exit 1; }
[ "${#PW}" -ge 8 ] || { echo "8 caracteres minimum." >&2; exit 1; }

mkdir -p "$DATA_DIR"
RS="$(mktemp)"; chmod 600 "$RS"
trap 'rm -f "$RS"' EXIT

cat > "$RS" <<EOT
sybinit.release_directory: USE_DEFAULT
sybinit.product: sqlsrv
sqlsrv.server_name: $NAME
sqlsrv.sa_password: $PW
sqlsrv.new_config: yes
sqlsrv.do_add_server: yes
sqlsrv.network_protocol_list: tcp
sqlsrv.network_hostname_list: $(hostname -s)
sqlsrv.network_port_list: $PORT
sqlsrv.application_type: USE_DEFAULT
sqlsrv.server_page_size: $PAGE
sqlsrv.force_buildmaster: no
sqlsrv.master_device_physical_name: $DATA_DIR/master.dat
sqlsrv.master_device_size: USE_DEFAULT
sqlsrv.master_database_size: USE_DEFAULT
sqlsrv.errorlog: USE_DEFAULT
sqlsrv.do_upgrade: no
sqlsrv.sybsystemprocs_device_physical_name: $DATA_DIR/sysprocs.dat
sqlsrv.sybsystemprocs_device_size: USE_DEFAULT
sqlsrv.sybsystemprocs_database_size: USE_DEFAULT
sqlsrv.default_backup_server: ${NAME}_BS
sqlsrv.do_configure_pci: no
sqlsrv.do_optimize_config: no
sqlsrv.configure_remote_command_and_control_agent_ase: no
sqlsrv.enable_ase_for_ase_cockpit_monitor: no
EOT

"$SYBASE/$SYBASE_ASE/bin/srvbuildres" -r "$RS"
echo
echo "Serveur $NAME cree. Test :  isql -Usa -S$NAME   (puis: select @@version / go)"
