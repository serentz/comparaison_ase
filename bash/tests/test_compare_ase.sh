#!/bin/bash
# ==============================================================================
# Tests de bash/compare_ase.sh avec un faux isql (bash/tests/fake_bin/isql).
#
# Prerequis : une base PostgreSQL ou sql/postgres/create_schema.sql a ete execute.
#   export COMPA_TEST_DB=compa PGHOST=<hote ou dossier socket> PGPORT=5432 PGUSER=<login>
#   (PGPASSWORD ou ~/.pgpass si besoin)
#   bash/tests/test_compare_ase.sh
# ==============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../compare_ase.sh"

: "${COMPA_TEST_DB:?definir COMPA_TEST_DB (base PostgreSQL avec le schema compa_ase)}"
: "${PGUSER:?definir PGUSER}"

export PATH="$HERE/fake_bin:$PATH"
export COMPA_FAKE_PASSWORDS="ASE1=pw_test1,ASE2=pw_test2"
PASS=0 FAIL=0
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

P() { psql -X -At -v ON_ERROR_STOP=1 -d "$COMPA_TEST_DB" "$@"; }
ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
ko()   { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -s "$LOG" ] && sed 's/^/         | /' "$LOG" | head -n 12; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu '$3', obtenu '$2')"; fi; }

cmd() { "$SCRIPT" -S ASE1 -D poc_db -s ASE2 -d poc_db -U "$PGUSER" -n "$COMPA_TEST_DB" \
        ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} "$@"; }

echo "== Preparation : logins ASE factices =="
P -q <<'SQL'
insert into compa_ase.config_compa_ase (instance, host, port, login, password)
values ('ASE1','ase01',5000,'sa','pw_test1'), ('ASE2','ase02',5000,'sa','pw_test2')
on conflict (instance) do update set login = excluded.login, password = excluded.password, actif = true;
SQL

echo "== 1. Execution nominale =="
cmd >"$LOG" 2>&1; rc=$?
check "code retour 0" "$rc" "0"
grep -q "30 ecart(s) enregistre(s)" "$LOG" && ok "30 ecarts enregistres" || ko "30 ecarts enregistres"
refid1=$(P -c "select max(refid) from compa_ase.ref_execution where instance1='ASE1' and instance2='ASE2'")
run1=$(P -c "select max(run_id) from compa_ase.run where refid=$refid1")
check "run termine" "$(P -c "select statut||'/'||message from compa_ase.run where run_id=$run1")" "TERMINE/30 ecart(s)"
total=$(P -c "select coalesce(sum(nb),0) from compa_ase.v_synthese_run where run_id=$run1")
check "30 lignes dans les tables diff" "$total" "30"
check "nettoyage : aucun dossier de travail restant" "$(ls -d "${TMPDIR:-/tmp}"/compa_ase_run${run1}_* 2>/dev/null | wc -l)" "0"

echo "== 2. Meme couple : refid reutilise, nouveau run =="
cmd >"$LOG" 2>&1; rc=$?
check "code retour 0" "$rc" "0"
check "refid inchange" "$(P -c "select count(*) from compa_ase.ref_execution where instance1='ASE1' and base1='poc_db' and instance2='ASE2' and base2='poc_db'")" "1"
run2=$(P -c "select max(run_id) from compa_ase.run where refid=$refid1")
[ "$run2" -gt "$run1" ] && ok "nouveau run_id ($run1 -> $run2)" || ko "nouveau run_id"

echo "== 3. Option -k : CSV conserves et formats conformes =="
cmd -k >"$LOG" 2>&1; rc=$?
check "code retour 0" "$rc" "0"
dir=$(sed -n 's/^\[+\] CSV conserves dans //p' "$LOG")
if [ -d "$dir" ]; then
    check "14 fichiers CSV" "$(ls "$dir" | wc -l)" "14"
    check "en-tete db_size" "$(head -n1 "$dir/r1_db_size.csv")" "db_name|segmap|size_mb|page_size"
    check "remplissage d'isql retire (db_size r1)" "$(sed -n 2p "$dir/r1_db_size.csv")" "poc_db|3|100|16384"
    check "invite et '(n rows affected)' retires" "$(grep -c -E 'Password|rows affected' "$dir"/*.csv | grep -v ':0' | wc -l)" "0"
    check "mot de passe absent des CSV" "$(grep -l pw_test "$dir"/*.csv | wc -l)" "0"
    check "permissions du dossier 700" "$(stat -c %a "$dir")" "700"
    rm -rf "$dir"
else
    ko "dossier CSV conserve introuvable"
fi

echo "== 4. Erreurs =="
"$SCRIPT" -D poc_db -s ASE2 -d poc_db -U u >"$LOG" 2>&1; check "argument manquant -> 1" "$?" "1"
"$SCRIPT" -S "a;b" -D x -s y -d z -U u >"$LOG" 2>&1; check "nom invalide -> 1" "$?" "1"

"$SCRIPT" -S ASE_INCONNU -D poc_db -s ASE2 -d poc_db -U "$PGUSER" -n "$COMPA_TEST_DB" \
    ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} >"$LOG" 2>&1; rc=$?
check "instance absente de config_compa_ase -> 12" "$rc" "12"
grep -q "config_compa_ase" "$LOG" && ok "message explicite" || ko "message explicite"

runs_before=$(P -c "select count(*) from compa_ase.run")
COMPA_FAKE_FAIL=ASE2 cmd >"$LOG" 2>&1; rc=$?
check "connexion ASE en echec -> 13" "$rc" "13"
check "aucun run cree avant la verification ASE" "$(P -c "select count(*) from compa_ase.run")" "$runs_before"

P -q -c "update compa_ase.config_compa_ase set password='mauvais' where instance='ASE1'"
cmd >"$LOG" 2>&1; check "mauvais mot de passe ASE -> 13" "$?" "13"
P -q -c "update compa_ase.config_compa_ase set password='pw_test1' where instance='ASE1'"

# CSV invalide : une requete qui renvoie un nombre de colonnes incorrect -> compare.py code 2, run en ERREUR
COMPA_FAKE_FIXTURES=$(mktemp -d)
cp "$HERE/../../python/tests/fixtures/"*.csv "$COMPA_FAKE_FIXTURES/"
printf 'db_name|segmap|size_mb|page_size\npoc_db|3\n' > "$COMPA_FAKE_FIXTURES/r1_db_size.csv"
export COMPA_FAKE_FIXTURES
cmd >"$LOG" 2>&1; rc=$?
check "CSV invalide -> 2 (compare.py)" "$rc" "2"
last=$(P -c "select max(run_id) from compa_ase.run")
check "run marque ERREUR" "$(P -c "select statut from compa_ase.run where run_id=$last")" "ERREUR"
rm -rf "$COMPA_FAKE_FIXTURES"; unset COMPA_FAKE_FIXTURES

echo "== 5. Schema absent =="
empty="compa_empty_$$"
if createdb "$empty" 2>/dev/null; then
    "$SCRIPT" -S ASE1 -D poc_db -s ASE2 -d poc_db -U "$PGUSER" -n "$empty" \
        ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} >"$LOG" 2>&1; rc=$?
    check "schema absent -> 11" "$rc" "11"
    grep -q "create_schema.sql" "$LOG" && ok "message : executer create_schema.sql" || ko "message : executer create_schema.sql"
    dropdb "$empty"
else
    echo "  skip - createdb impossible"
fi

echo "== 6. Mode batch (-B) =="
bcmd() { "$SCRIPT" -B -U "$PGUSER" -n "$COMPA_TEST_DB" ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} "$@"; }
P -q -c "delete from compa_ase.batch_run"
"$SCRIPT" -B -S ASE1 -U u >"$LOG" 2>&1; check "-B avec -S -> 1" "$?" "1"
"$SCRIPT" -B >"$LOG" 2>&1; check "-B sans -U -> 1" "$?" "1"

bcmd >"$LOG" 2>&1; rc=$?
check "batch vide -> 0" "$rc" "0"
grep -q "Aucun couple actif" "$LOG" && ok "message : aucun couple" || ko "message : aucun couple"

P -q -c "insert into compa_ase.batch_run (ds1, db1, ds2, db2) values ('ASE1','poc_db','ASE2','poc_db'), ('ASE2','poc_db','ASE1','poc_db'), ('ASE1','poc_db','ASE_INCONNU','poc_db'), ('ASE1','autre','ASE2','autre')"
P -q -c "update compa_ase.batch_run set actif = false where db1 = 'autre'"
check "avant le batch : status_run NULL" "$(P -c "select count(*) from compa_ase.batch_run where status_run is null and last_run is null and elapse is null")" "4"
runs_before=$(P -c "select count(*) from compa_ase.run")
bcmd >"$LOG" 2>&1; rc=$?
check "batch avec un couple en echec -> 14" "$rc" "14"
grep -q "2 comparaison(s) reussie(s), 1 en echec" "$LOG" && ok "bilan du batch" || ko "bilan du batch"
check "2 runs crees (les couples actifs executes, l'inactif ignore)" "$(( $(P -c "select count(*) from compa_ase.run") - runs_before ))" "2"
check "couple OK : status_run true" "$(P -c "select status_run from compa_ase.batch_run where ds1='ASE1' and ds2='ASE2' and db1='poc_db'")" "t"
check "couple en echec (instance inconnue) : status_run false" "$(P -c "select status_run from compa_ase.batch_run where ds2='ASE_INCONNU'")" "f"
check "couple inactif : jamais execute" "$(P -c "select status_run is null and last_run is null from compa_ase.batch_run where db1='autre'")" "t"
check "last_run et elapse renseignes pour les 3 couples actifs" "$(P -c "select count(*) from compa_ase.batch_run where actif and last_run is not null and elapse is not null")" "3"
check "last_run recent" "$(P -c "select count(*) from compa_ase.batch_run where actif and last_run > now() - interval '5 minutes'")" "3"
check "run d'un couple OK : 30 ecarts" "$(P -c "select message from compa_ase.run r join compa_ase.ref_execution f using (refid) where f.instance1='ASE1' and f.instance2='ASE2' and f.base1='poc_db' order by run_id desc limit 1")" "30 ecart(s)"
check "nettoyage : aucun dossier de travail restant" "$(ls -d "${TMPDIR:-/tmp}"/compa_ase_run*_* 2>/dev/null | wc -l)" "0"

# Un couple en echec ne bloque pas les suivants, et un couple repare repasse a true
P -q -c "update compa_ase.batch_run set actif = false where ds2 = 'ASE_INCONNU'"
COMPA_FAKE_FAIL=ASE2 bcmd >"$LOG" 2>&1; rc=$?
check "connexion ASE en echec sur tout le batch -> 14" "$rc" "14"
check "les 2 couples actifs passent a false" "$(P -c "select count(*) from compa_ase.batch_run where actif and status_run is false")" "2"
bcmd >"$LOG" 2>&1; rc=$?
check "batch complet reussi -> 0" "$rc" "0"
check "les 2 couples actifs repassent a true" "$(P -c "select count(*) from compa_ase.batch_run where actif and status_run is true")" "2"

P -q -c "drop table compa_ase.batch_run"
bcmd >"$LOG" 2>&1; rc=$?
check "table batch_run absente -> 11" "$rc" "11"
grep -q "create_schema.sql" "$LOG" && ok "message : rejouer create_schema.sql" || ko "message : rejouer create_schema.sql"
psql -X -q -d "$COMPA_TEST_DB" -v ON_ERROR_STOP=1 -f "$HERE/../../sql/postgres/create_schema.sql" >/dev/null 2>&1 \
    && ok "schema rejoue : batch_run recree" || ko "schema rejoue : batch_run recree"

echo "== Nettoyage =="
P -q -c "delete from compa_ase.config_compa_ase where instance in ('ASE1','ASE2')"

echo
echo "Resultat : $PASS ok, $FAIL en echec"
[ "$FAIL" -eq 0 ]
