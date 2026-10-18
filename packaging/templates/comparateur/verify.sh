#!/usr/bin/env bash
# compA_ase : controles apres installation du comparateur.   sudo ./verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
ETC_DIR="${COMPA_ETC_DIR:-/etc/compa_ase}"
BIN_DIR="${COMPA_BIN_DIR:-/usr/local/bin}"
[ -f "$ETC_DIR/compa_ase.env" ] || die "$ETC_DIR/compa_ase.env absent : lancer ./install.sh d'abord."
. "$ETC_DIR/compa_ase.env"
FAIL=0
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else warn "ECHEC : $label"; FAIL=1; fi; }

[ -z "${SYBASE_ENV_FILE:-}" ] || . "$SYBASE_ENV_FILE"
check "psql present" command -v psql
check "isql present (SAP Open Client)" command -v isql
[ -z "${SYBASE:-}" ] || check "fichier interfaces present ($SYBASE/interfaces)" test -f "$SYBASE/interfaces"
check "python3 present" command -v python3
check "compare_ase.sh executable" test -x "$INSTALL_DIR/bash/compare_ase.sh"
check "7 requetes d'extraction" bash -c "[ \$(ls '$INSTALL_DIR'/bash/queries/*.sql | wc -l) -eq 7 ]"
check "compare.py compile" python3 -m py_compile "$INSTALL_DIR/python/compare.py"
check "commande compa_ase installee" test -x "$BIN_DIR/compa_ase"
check "compa_ase.env en 0600" bash -c "[ \"\$(stat -c %a '$ETC_DIR/compa_ase.env')\" = 600 ]"
check "base de resultats joignable, schema compa_ase present" env PGPASSWORD="$PG_PASSWORD" psql -X -At -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT version FROM compa_ase.schema_version"
n="$(PGPASSWORD="$PG_PASSWORD" psql -X -At -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT count(*) FROM compa_ase.config_compa_ase WHERE actif" 2>/dev/null || echo '?')"
printf '   instances ASE declarees dans la base de resultats : %s\n' "$n"
[ "$FAIL" -eq 0 ] && ok "Tous les controles sont bons" || die "Au moins un controle a echoue (voir ci-dessus)"
