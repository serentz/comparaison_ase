#!/usr/bin/env bash
# compA_ase : controles du serveur ASE de test.   ./verify.sh   (ASE_SA_PASSWORD, sinon mot de passe demande)
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
load_env
. "$SYBASE_DIR/SYBASE.sh"
FAIL=0
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else warn "ECHEC : $label"; FAIL=1; fi; }
PW="${ASE_SA_PASSWORD:-}"
if [ -z "$PW" ]; then read -r -s -p "Mot de passe sa de $ASE_NAME : " PW; echo; fi
check "isql present" command -v isql
check "serveur $ASE_NAME declare dans interfaces" grep -q "^$ASE_NAME\b" "$SYBASE_DIR/interfaces"
export PW ASE_NAME
check "serveur $ASE_NAME repond" bash -c 'printf "%s\nselect @@version\ngo\n" "$PW" | isql -S "$ASE_NAME" -U sa -b | grep -qi "Adaptive Server"'
check "base poc_db presente" bash -c 'printf "%s\nselect name from master..sysdatabases where name = \"poc_db\"\ngo\n" "$PW" | isql -S "$ASE_NAME" -U sa -b | grep -q poc_db'
[ "$FAIL" -eq 0 ] && ok "Tous les controles sont bons" || die "Au moins un controle a echoue (voir ci-dessus)"
