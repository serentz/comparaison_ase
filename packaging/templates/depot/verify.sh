#!/usr/bin/env bash
# compA_ase : controles apres installation de la base de resultats.   sudo ./verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
load_env
PSQL_CMD="${PSQL_CMD:-runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p $PG_PORT}"
FAIL=0
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else warn "ECHEC : $label"; FAIL=1; fi; }
q() { $PSQL_CMD -d "$DEPOT_DB" -At -c "$1"; }
eq() { [ "$(q "$1")" = "$2" ]; }

check "base $DEPOT_DB joignable" q "SELECT 1"
check "13 tables dans le schema compa_ase" eq "SELECT count(*) FROM information_schema.tables WHERE table_schema='compa_ase' AND table_type='BASE TABLE'" 13
check "version du schema notee" eq "SELECT count(*) FROM compa_ase.schema_version" 1
check "fonctions get_or_create_refid, start_run, end_run" eq "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='compa_ase' AND proname IN ('get_or_create_refid','start_run','end_run')" 3
check "vues v_run_selector et v_synthese_run" eq "SELECT count(*) FROM information_schema.views WHERE table_schema='compa_ase' AND table_name IN ('v_run_selector','v_synthese_run')" 2
check "$DEPOT_OWNER peut se connecter" eq "SELECT rolcanlogin::text FROM pg_roles WHERE rolname='$DEPOT_OWNER'" true
check "grafana_ro peut se connecter" eq "SELECT rolcanlogin::text FROM pg_roles WHERE rolname='grafana_ro'" true
check "grafana_ro lit les resultats" bash -c "$PSQL_CMD -d '$DEPOT_DB' -c 'SET ROLE grafana_ro; SELECT 1 FROM compa_ase.run LIMIT 1'"
check "grafana_ro ne lit PAS config_compa_ase (mots de passe)" bash -c "! $PSQL_CMD -d '$DEPOT_DB' -c 'SET ROLE grafana_ro; SELECT 1 FROM compa_ase.config_compa_ase LIMIT 1' 2>/dev/null"
check "ecoute reseau (listen_addresses = *)" bash -c "[ \"\$($PSQL_CMD -d postgres -At -c 'SHOW listen_addresses')\" = '*' ]"
printf '   instances ASE declarees : %s\n' "$(q 'SELECT count(*) FROM compa_ase.config_compa_ase')"
printf '   comparaisons (runs) : %s\n' "$(q 'SELECT count(*) FROM compa_ase.run')"
[ "$FAIL" -eq 0 ] && ok "Tous les controles sont bons" || die "Au moins un controle a echoue (voir ci-dessus)"
