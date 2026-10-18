#!/usr/bin/env bash
# ============================================================
# compA_ase : tests des archives de deploiement.
#
#   sudo packaging/test_packages.sh
#
# 1. Construit les 4 archives dans un dossier temporaire et controle : contenu, SHA256SUMS, reproductibilite,
#    syntaxe des scripts, JSON, Python, fichiers cites par les scripts presents dans l'archive.
# 2. Test d'integration (root + pg_createcluster requis, sinon SKIP) : installe pour de bon l'archive depot
#    (cluster temporaire), declare ASE1/ASE2, installe le comparateur (dossiers temporaires), puis lance une
#    comparaison ASE1/poc_db contre ASE2/poc_db avec le FAUX isql du depot (bash/tests/fake_bin) : 30 ecarts
#    attendus ; installe enfin grafana (commandes simulees). L'archive serveurs_ase_test n'est pas executee
#    (pas d'ASE ici) : contenu et syntaxe seulement.
# Les etapes sans prerequis sont signalees SKIP. Code de sortie : 0 si aucun echec.
# Attention : cree/demarre le cluster Debian compadepot (PORT_DEPOT).
# ============================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
PASS=0 FAIL=0 SKIP=0
PORT_DEPOT="${PORT_DEPOT:-5448}"
DEPOT_CLUSTER=compadepot
PGV=""

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 10 | sed 's/^/         | /'; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP - $1"; }
check() { local label="$1" out; shift; if out="$("$@" 2>&1)"; then ok "$label"; else ko "$label" "$out"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu '$3', obtenu '$2')"; fi; }

cleanup() {
    if [ -n "$PGV" ]; then
        pg_dropcluster --stop "$PGV" "$DEPOT_CLUSTER" >/dev/null 2>&1 || true
    fi
    rm -rf "$T"
}
trap cleanup EXIT

PKGS=(depot comparateur grafana serveurs_ase_test)

echo "== Construction =="
check "build_packages.sh" env OUT_DIR="$T/dist" "$ROOT/packaging/build_packages.sh" vTEST
check "build reproductible (2e build identique)" bash -c "OUT_DIR='$T/dist2' '$ROOT/packaging/build_packages.sh' vTEST >/dev/null && diff '$T/dist/SHA256SUMS' '$T/dist2/SHA256SUMS'"
check "SHA256SUMS du dossier de sortie valide" bash -c "cd '$T/dist' && sha256sum -c SHA256SUMS --quiet"
mkdir -p "$T/x"
for p in "${PKGS[@]}"; do tar xzf "$T/dist/compa_ase_$p.tgz" -C "$T/x" || ko "extraction de $p"; done

expected() {
    case "$1" in
    depot) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_ase.env.example scripts/declarer-instance.sh sql/create_schema.sql ;;
    comparateur) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_ase.env.example scripts/compa_ase-planifie.sh scripts/planifie.conf.example \
        systemd/compa_ase-planifie.service systemd/compa_ase-planifie.timer cron/compa_ase.cron bash/compare_ase.sh python/compare.py \
        bash/queries/inst_config.sql bash/queries/db_size.sql bash/queries/db_options.sql bash/queries/obj_tables.sql bash/queries/obj_indexes.sql \
        bash/queries/obj_code.sql bash/queries/obj_source.sql ;;
    grafana) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_ase.env.example provisioning/datasources/compa_ase.yaml \
        provisioning/dashboards/compa_ase.yaml dashboards/compa-home.json ;;
    serveurs_ase_test) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_ase.env.example scripts/charger-base-test.sh infra/ase/build_server.sh \
        sql/ase_test/01_create_poc_db_instance1.sql sql/ase_test/02_create_poc_db_instance2.sql ;;
    esac
}

for p in "${PKGS[@]}"; do
    D="$T/x/compa_ase_$p"
    echo "== Archive $p =="
    missing=""
    for f in $(expected "$p") VERSION SHA256SUMS; do [ -f "$D/$f" ] || missing="$missing $f"; done
    [ -z "$missing" ] && ok "contenu attendu present" || ko "fichiers manquants :$missing"
    check "SHA256SUMS valide" bash -c "cd '$D' && sha256sum -c SHA256SUMS --quiet"
    eq "VERSION indique la version" "$(sed -n 1p "$D/VERSION")" "compA_ase vTEST"
    [ -z "$(find "$D" -name 'compa_ase.env' -o -name '*.pgpass')" ] && ok "aucun secret dans l'archive" || ko "secret present dans l'archive"
    grep -rl --exclude='*.json' '{{' "$D" >/dev/null 2>&1 && ko "marqueur {{...}} non remplace" || ok "marqueurs de modele remplaces"
    for s in install.sh verify.sh; do [ -x "$D/$s" ] && ok "$s executable" || ko "$s non executable"; done
    for f in $(cd "$D" && find . -name '*.sh' | sed 's|^\./||'); do check "bash -n $f" bash -n "$D/$f"; done
    for f in $(cd "$D" && find . -name '*.json' | sed 's|^\./||'); do python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$D/$f" 2>/dev/null || ko "JSON invalide : $f"; done
    for f in $(cd "$D" && find . -name '*.py' | sed 's|^\./||'); do check "python compile : $f" python3 -m py_compile "$D/$f"; done
    # Fermeture : chaque nom de fichier cite (hors commentaires) par les scripts d'installation existe dans l'archive.
    allow='^(compa_ase\.env|compa_ase\.conf|postgresql\.conf|pg_hba\.conf|grafana\.list|grafana\.gpg|gpg\.key|sources\.list|build_server\.sh|charger-base-test\.sh|compare_ase\.sh|SYBASE\.sh|interfaces|planifie\.conf|compa_ase\.cron|declarer-instance\.sh|compa_ase-planifie\.(sh|service|timer)|compa_ase\.yaml|create_schema\.sql|compare\.py|lib\.sh|verify\.sh|install\.sh|grafana-server|planifie\.conf\.example|compa_ase\.env\.example)$'
    refs="$(cd "$D" && cat install.sh scripts/declarer-instance.sh scripts/compa_ase-planifie.sh scripts/charger-base-test.sh 2>/dev/null | sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' \
        | grep -o '[A-Za-z0-9_][A-Za-z0-9_.-]*\.\(py\|sql\|service\|timer\|json\|sh\|yaml\|cron\|example\)' | sort -u)"
    unresolved=""
    for r in $refs; do
        echo "$r" | grep -Eq "$allow" && { [ -n "$(find "$D" -name "$r" -print -quit)" ] || echo "$r" | grep -Eq '^(compa_ase\.conf|postgresql\.conf|pg_hba\.conf|grafana\.list|grafana\.gpg|gpg\.key|sources\.list|compare_ase\.sh|SYBASE\.sh|compa_ase\.env|planifie\.conf|compa_ase-planifie\.(sh|service|timer)|compa_ase\.cron)$' || unresolved="$unresolved $r"; continue; }
        [ -n "$(find "$D" -name "$r" -print -quit)" ] || unresolved="$unresolved $r"
    done
    [ -z "$unresolved" ] && ok "tout fichier cite par les scripts est dans l'archive" || ko "cites mais absents de l'archive :$unresolved"
done
eq "8 dashboards dans l'archive grafana" "$(ls "$T/x/compa_ase_grafana/dashboards/"*.json | wc -l)" "8"
for f in "$ROOT"/grafana/dashboards/*.json; do cmp -s "$f" "$T/x/compa_ase_grafana/dashboards/$(basename "$f")" || ko "dashboard modifie : $f"; done
eq "7 requetes dans l'archive comparateur" "$(ls "$T/x/compa_ase_comparateur/bash/queries/"*.sql | wc -l)" "7"
cmp -s "$ROOT/sql/postgres/create_schema.sql" "$T/x/compa_ase_depot/sql/create_schema.sql" && ok "schema identique a celui du depot Git" || ko "schema different"
cmp -s "$ROOT/infra/ase/build_server.sh" "$T/x/compa_ase_serveurs_ase_test/infra/ase/build_server.sh" && ok "build_server.sh identique a celui du depot Git" || ko "build_server.sh different"

echo "== Integration : installation reelle (depot, comparateur, grafana) =="
PGV="$(ls /usr/lib/postgresql 2>/dev/null | sort -n | tail -n 1)"
if [ "$(id -u)" -ne 0 ] || [ -z "$PGV" ] || ! command -v pg_createcluster >/dev/null || ! command -v psql >/dev/null || ! command -v python3 >/dev/null; then
    skip "root, PostgreSQL Debian (pg_createcluster), psql et python3 requis"; PGV=""
else
    SECRET_APP="Test_compa_app_1"; SECRET_RO="Test_grafana_1"
    pg_dropcluster --stop "$PGV" "$DEPOT_CLUSTER" >/dev/null 2>&1 || true
    pg_createcluster "$PGV" "$DEPOT_CLUSTER" --port "$PORT_DEPOT" >/dev/null 2>&1
    pg_ctlcluster "$PGV" "$DEPOT_CLUSTER" start

    # --- depot ---
    D="$T/x/compa_ase_depot"
    cat > "$D/scripts/compa_ase.env" <<ENV
PG_PORT=$PORT_DEPOT
DEPOT_DB=compa
DEPOT_OWNER=compa_app
DEPOT_OWNER_PASSWORD=$SECRET_APP
GRAFANA_RO_PASSWORD=$SECRET_RO
ALLOW_SUBNET=127.0.0.1/32
ENV
    check "depot : install.sh" "$D/install.sh"
    check "depot : install.sh rejoue (idempotent)" "$D/install.sh"
    check "depot : verify.sh" "$D/verify.sh"

    # --- declaration des instances ASE (mots de passe factices du faux isql) ---
    check "depot : declarer-instance.sh ASE1" env INSTANCE_PASSWORD=pw_test1 "$D/scripts/declarer-instance.sh" ASE1 ase01 5000 sa "instance 1"
    check "depot : declarer-instance.sh ASE2" env INSTANCE_PASSWORD=pw_test2 "$D/scripts/declarer-instance.sh" ASE2 ase02 5000 sa
    check "depot : declarer-instance.sh ASE2 (mise a jour)" env INSTANCE_PASSWORD=pw_test2 "$D/scripts/declarer-instance.sh" ASE2 ase02 5000 sa "instance 2"
    eq "2 instances declarees" "$(runuser -u postgres -- psql -X -At -p "$PORT_DEPOT" -d compa -c 'SELECT count(*) FROM compa_ase.config_compa_ase')" "2"

    # --- comparateur (faux isql du depot dans le PATH) ---
    M="$T/x/compa_ase_comparateur"; mkdir -p "$T/inst" "$T/etc" "$T/bin"
    cat > "$M/scripts/compa_ase.env" <<ENV
PG_HOST=127.0.0.1
PG_PORT=$PORT_DEPOT
PG_DB=compa
PG_USER=compa_app
PG_PASSWORD=$SECRET_APP
INSTALL_DIR=$T/inst
RUN_USER=root
ENV
    export COMPA_ETC_DIR="$T/etc" COMPA_BIN_DIR="$T/bin" COMPA_UNIT_DIR="$T/units"
    export COMPA_FAKE_PASSWORDS="ASE1=pw_test1,ASE2=pw_test2"
    FAKEPATH="$ROOT/bash/tests/fake_bin:$PATH"
    check "comparateur : install.sh" env PATH="$FAKEPATH" "$M/install.sh"
    check "comparateur : install.sh rejoue" env PATH="$FAKEPATH" "$M/install.sh"
    check "comparateur : verify.sh" env PATH="$FAKEPATH" "$M/verify.sh"
    eq "compa_ase.env en 0600" "$(stat -c %a "$T/etc/compa_ase.env")" "600"
    out="$(PATH="$T/bin:$FAKEPATH" "$T/bin/compa_ase" -S ASE1 -D poc_db -s ASE2 -d poc_db 2>&1)"; rc=$?
    eq "compa_ase ASE1/poc_db contre ASE2/poc_db : code retour 0" "$rc" "0"
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -n 8 | sed 's/^/         | /'
    P="runuser -u postgres -- psql -X -At -p $PORT_DEPOT -d compa"
    total="$($P -c "SELECT sum(nb) FROM (SELECT count(*) nb FROM compa_ase.diff_inst_config UNION ALL SELECT count(*) FROM compa_ase.diff_db_size UNION ALL SELECT count(*) FROM compa_ase.diff_db_options UNION ALL SELECT count(*) FROM compa_ase.diff_obj_tables UNION ALL SELECT count(*) FROM compa_ase.diff_obj_indexes UNION ALL SELECT count(*) FROM compa_ase.diff_obj_code UNION ALL SELECT count(*) FROM compa_ase.diff_obj_source) x")"
    eq "30 ecarts enregistres (faux isql, fixtures du depot)" "$total" "30"
    # Planification : planifie.conf + compa_ase-planifie
    echo "ASE1 poc_db ASE2 poc_db" > "$T/etc/planifie.conf"
    PATH="$T/bin:$FAKEPATH" COMPA_PLANIFIE_CONF="$T/etc/planifie.conf" "$T/bin/compa_ase-planifie" >/dev/null 2>&1; rc=$?
    eq "compa_ase-planifie : code retour 0" "$rc" "0"
    eq "2 runs enregistres apres la comparaison planifiee" "$($P -c 'SELECT count(*) FROM compa_ase.run')" "2"
    echo "ASE1 poc_db ASEINCONNU poc_db" > "$T/etc/planifie.conf"
    PATH="$T/bin:$FAKEPATH" COMPA_PLANIFIE_CONF="$T/etc/planifie.conf" "$T/bin/compa_ase-planifie" >/dev/null 2>&1; rc=$?
    eq "compa_ase-planifie : instance inconnue -> code retour 1" "$rc" "1"
    # Sans isql : verify.sh doit echouer (isql n'est pas fourni par l'archive)
    PATH="/usr/bin:/bin" "$M/verify.sh" >/dev/null 2>&1 && ko "comparateur : verify.sh sans isql devrait echouer" || ok "comparateur : verify.sh echoue sans isql"
    unset COMPA_ETC_DIR COMPA_BIN_DIR COMPA_UNIT_DIR COMPA_FAKE_PASSWORDS

    # --- grafana (commandes simulees, dossiers temporaires) ---
    G="$T/x/compa_ase_grafana"; mkdir -p "$T/stubs"
    printf '#!/bin/sh\nexit 0\n' > "$T/stubs/grafana-server"; chmod +x "$T/stubs/grafana-server"
    cat > "$G/scripts/compa_ase.env" <<ENV
COMPA_PG_HOST=127.0.0.1
COMPA_PG_PORT=$PORT_DEPOT
COMPA_PG_DB=compa
COMPA_PG_PASSWORD=$SECRET_RO
ENV
    export GRAFANA_DEFAULTS_FILE="$T/default-grafana-server" GRAFANA_PROV_DIR="$T/prov" GRAFANA_DASH_DIR="$T/dash/compa_ase"
    printf '# reglages par defaut de Grafana\nGRAFANA_USER=grafana\n' > "$GRAFANA_DEFAULTS_FILE"
    check "grafana : install.sh" env PATH="$T/stubs:$PATH" "$G/install.sh"
    check "grafana : install.sh rejoue" env PATH="$T/stubs:$PATH" "$G/install.sh"
    eq "grafana : reglages par defaut conserves" "$(grep -c '^GRAFANA_USER=grafana' "$GRAFANA_DEFAULTS_FILE")" "1"
    eq "grafana : un seul bloc COMPA_PG env apres rejeu" "$(grep -c '^# BEGIN COMPA_PG env' "$GRAFANA_DEFAULTS_FILE")" "1"
    eq "grafana : 8 dashboards copies" "$(ls "$GRAFANA_DASH_DIR"/*.json | wc -l)" "8"
    check "grafana : verify.sh" env PATH="$T/stubs:$PATH" "$G/verify.sh"
    check "grafana_ro lit les resultats mais pas config_compa_ase" bash -c "PGPASSWORD='$SECRET_RO' psql -X -At -h 127.0.0.1 -p $PORT_DEPOT -U grafana_ro -d compa -c 'SELECT count(*) FROM compa_ase.run' && ! PGPASSWORD='$SECRET_RO' psql -X -At -h 127.0.0.1 -p $PORT_DEPOT -U grafana_ro -d compa -c 'SELECT 1 FROM compa_ase.config_compa_ase' 2>/dev/null"
    unset GRAFANA_DEFAULTS_FILE GRAFANA_PROV_DIR GRAFANA_DASH_DIR
fi

echo
echo "Resultat : $PASS ok, $FAIL echec(s), $SKIP ignore(s)"
[ "$FAIL" -eq 0 ]
