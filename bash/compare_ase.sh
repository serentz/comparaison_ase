#!/bin/bash
# ==============================================================================
# compare_ase.sh - Comparaison de deux couples instance/base SAP ASE
#
# 1. verifie PostgreSQL (schema compa_ase), lit les logins ASE dans config_compa_ase
# 2. cree/retrouve la reference (refid) et ouvre un run (run_id)
# 3. extrait 7 modules x 2 cotes vers des CSV (requetes dans bash/queries/*.sql)
# 4. appelle python/compare.py qui compare et enregistre les ecarts dans PostgreSQL
#
# Mode batch (-B) : lit les couples a comparer dans la table compa_ase.batch_run, execute la comparaison de
# chacun (meme traitement que le mode unitaire) puis y inscrit le resultat (status_run, last_run, elapse).
#
# Format des CSV : docs/format_csv.md
# ==============================================================================
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="${COMPA_QUERIES_DIR:-$SCRIPT_DIR/queries}"
COMPARE_PY="${COMPA_COMPARE_PY:-$PROJECT_DIR/python/compare.py}"
WORK_ROOT="${COMPA_WORKDIR:-${TMPDIR:-/tmp}}"
if [ -n "${COMPA_PYTHON:-}" ]; then
    PY="$COMPA_PYTHON"
elif [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
    PY="$PROJECT_DIR/.venv/bin/python"
else
    PY="python3"
fi

# Codes retour (en plus de ceux de compare.py : 2 = CSV invalide, 3 = erreur PostgreSQL)
E_USAGE=1       # arguments invalides
E_PREREQ=10     # outil manquant ou PostgreSQL injoignable
E_SCHEMA=11     # schema ou tables PostgreSQL absents
E_CONFIG=12     # instance absente de config_compa_ase
E_ASE=13        # connexion ou extraction ASE en echec
E_BATCH=14      # mode batch : au moins une comparaison en echec (voir compa_ase.batch_run)

MODULES=(inst_config db_size db_options obj_tables obj_indexes obj_code obj_source)
declare -A HEADERS=(
    [inst_config]="name|value|value_in_use"
    [db_size]="db_name|segmap|size_mb|page_size"
    [db_options]="db_name|status|status2|status3|status4"
    [obj_tables]="table_name|column_name|type_name|length|prec|scale|status"
    [obj_indexes]="table_name|index_name|status|columns|statstamp"
    [obj_code]="object_name|object_type"
    [obj_source]="object_name|object_type|colid|text_hex"
)
# Base dans laquelle chaque requete s'execute : master ou la base comparee (db)
declare -A CONTEXT=(
    [inst_config]=master [db_size]=master [db_options]=master
    [obj_tables]=db [obj_indexes]=db [obj_code]=db [obj_source]=db
)
REQUIRED_TABLES="'schema_version','ref_execution','run','config_compa_ase','exclusion_rules','diff_inst_config','diff_db_size','diff_db_options','diff_obj_tables','diff_obj_indexes','diff_obj_code','diff_obj_source'"
REQUIRED_TABLES_COUNT=12

log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[-] $*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: $0 -S <instance1> -D <base1> -s <instance2> -d <base2> -U <login_pg> [options]     (une comparaison)
       $0 -B -U <login_pg> [options]                                                       (mode batch)

  -S  instance ASE 1            -D  base de donnees 1
  -s  instance ASE 2            -d  base de donnees 2
  -B  mode batch : compare tous les couples actifs de la table compa_ase.batch_run (-S -D -s -d inutiles)
  -U  login PostgreSQL          -P  mot de passe PostgreSQL (preferer PGPASSWORD ou ~/.pgpass)
  -H  hote PostgreSQL           -p  port PostgreSQL           -n  nom de la base PostgreSQL
  -k  conserver les CSV du run (par defaut : supprimes en fin d'execution)
  -h  cette aide

Les logins ASE sont lus dans la table PostgreSQL compa_ase.config_compa_ase.
En mode batch, le resultat de chaque couple est inscrit dans compa_ase.batch_run (status_run, last_run, elapse) ;
code retour $E_BATCH si au moins une comparaison a echoue.
EOF
    exit $E_USAGE
}

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------
SRV1="" DB1="" SRV2="" DB2=""
PG_USER="" PG_PASS="" PG_HOST="" PG_PORT="" PG_DB=""
KEEP=0
BATCH=0

while getopts "S:D:s:d:BU:P:H:p:n:kh" opt; do
    case $opt in
        S) SRV1=$OPTARG ;;
        D) DB1=$OPTARG ;;
        s) SRV2=$OPTARG ;;
        d) DB2=$OPTARG ;;
        B) BATCH=1 ;;
        U) PG_USER=$OPTARG ;;
        P) PG_PASS=$OPTARG ;;
        H) PG_HOST=$OPTARG ;;
        p) PG_PORT=$OPTARG ;;
        n) PG_DB=$OPTARG ;;
        k) KEEP=1 ;;
        *) usage ;;
    esac
done

if [ "$BATCH" = 1 ]; then
    if [ -n "$SRV1$DB1$SRV2$DB2" ]; then
        err "-B (batch) ne se combine pas avec -S, -D, -s, -d : les couples viennent de la table compa_ase.batch_run."
        usage
    fi
    if [ -z "$PG_USER" ]; then
        err "Le parametre -U est obligatoire."
        usage
    fi
elif [ -z "$SRV1" ] || [ -z "$DB1" ] || [ -z "$SRV2" ] || [ -z "$DB2" ] || [ -z "$PG_USER" ]; then
    err "Les parametres -S, -D, -s, -d et -U sont obligatoires (ou -B pour le mode batch)."
    usage
fi

# Les noms sont reinjectes dans des requetes et des chemins : liste blanche de caracteres
valid_names() {   # $@ = noms a controler
    local v
    for v in "$@"; do
        if ! [[ $v =~ ^[A-Za-z0-9_.-]+$ ]]; then
            err "Valeur invalide '$v' : seuls les lettres, chiffres, '_', '.' et '-' sont acceptes."
            return 1
        fi
    done
}
if [ "$BATCH" = 0 ]; then
    valid_names "$SRV1" "$DB1" "$SRV2" "$DB2" || exit $E_USAGE
fi
if [ -n "$PG_PORT" ] && ! [[ $PG_PORT =~ ^[0-9]+$ ]]; then
    err "Le port PostgreSQL doit etre numerique."
    exit $E_USAGE
fi
[ -n "$PG_PASS" ] && warn "-P est visible dans la liste des processus : preferer PGPASSWORD ou ~/.pgpass."

# ------------------------------------------------------------------------------
# Acces PostgreSQL
# ------------------------------------------------------------------------------
PG_ARGS=(-X -v ON_ERROR_STOP=1 -U "$PG_USER")
[ -n "$PG_HOST" ] && PG_ARGS+=(-h "$PG_HOST")
[ -n "$PG_PORT" ] && PG_ARGS+=(-p "$PG_PORT")
[ -n "$PG_DB" ] && PG_ARGS+=(-d "$PG_DB")
[ -n "$PG_PASS" ] && export PGPASSWORD="$PG_PASS"

pg() { psql "${PG_ARGS[@]}" "$@"; }

# ------------------------------------------------------------------------------
# Nettoyage et suivi du run (etat de la comparaison en cours ; remis a zero par unit_cleanup)
# ------------------------------------------------------------------------------
WORK=""
RUN_ID=""
REFID=""
RUN_OPEN=0

fail_run() {
    # Marque le run en ERREUR (au mieux : ne masque pas l'erreur d'origine)
    [ -n "$RUN_ID" ] || return 0
    pg -q -At -o /dev/null -v rid="$RUN_ID" -v msg="$1" >/dev/null 2>&1 <<'SQL'
select compa_ase.end_run(:rid, 'ERREUR', :'msg');
SQL
    RUN_OPEN=0
}

unit_cleanup() {   # $1 = code de sortie (pour le message d'un run interrompu)
    if [ "$RUN_OPEN" = 1 ]; then
        fail_run "script interrompu (code $1)"
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        if [ "$KEEP" = 1 ]; then
            log "CSV conserves dans $WORK"
        else
            rm -rf "$WORK"
        fi
    fi
    WORK="" RUN_ID="" REFID="" RUN_OPEN=0
}

cleanup() { unit_cleanup $?; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------------------
# Pre-controles (une seule fois, en mode unitaire comme en mode batch)
# ------------------------------------------------------------------------------
preflight() {
    local cmd mod nb_tables
    for cmd in psql isql "$PY"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "Commande introuvable : $cmd"
            return $E_PREREQ
        fi
    done
    if [ ! -f "$COMPARE_PY" ]; then
        err "compare.py introuvable : $COMPARE_PY"
        return $E_PREREQ
    fi
    for mod in "${MODULES[@]}"; do
        if [ ! -f "$QUERIES_DIR/$mod.sql" ]; then
            err "Requete manquante : $QUERIES_DIR/$mod.sql"
            return $E_PREREQ
        fi
    done

    nb_tables=$(pg -At -c "select count(*) from information_schema.tables where table_schema = 'compa_ase' and table_name in ($REQUIRED_TABLES)" 2>&1)
    if [ $? -ne 0 ]; then
        err "Connexion PostgreSQL impossible : $nb_tables"
        return $E_PREREQ
    fi
    if [ "$nb_tables" != "$REQUIRED_TABLES_COUNT" ]; then
        err "Le schema compa_ase est absent ou incomplet ($nb_tables/$REQUIRED_TABLES_COUNT tables)."
        err "Executer d'abord le script de creation : psql -f sql/postgres/create_schema.sql"
        return $E_SCHEMA
    fi
    if [ "$BATCH" = 1 ]; then
        nb_tables=$(pg -At -c "select count(*) from information_schema.tables where table_schema = 'compa_ase' and table_name = 'batch_run'" 2>&1)
        if [ "$nb_tables" != "1" ]; then
            err "La table compa_ase.batch_run est absente : rejouer sql/postgres/create_schema.sql (sans perte de donnees)."
            return $E_SCHEMA
        fi
    fi
    log "PostgreSQL : schema compa_ase present."
}

# ------------------------------------------------------------------------------
# Logins ASE (table config_compa_ase)
# ------------------------------------------------------------------------------
declare -A ASE_LOGIN ASE_PASS

fetch_creds() {   # $1 = 1|2 (cote), $2 = instance ; retourne un code E_*
    local row
    row=$(pg -At -F $'\t' -v inst="$2" 2>&1 <<'SQL'
select login, password from compa_ase.config_compa_ase where instance = :'inst' and actif;
SQL
    )
    if [ $? -ne 0 ]; then
        err "Lecture de config_compa_ase impossible : $row"
        return $E_PREREQ
    fi
    if [ -z "$row" ]; then
        err "Instance '$2' absente (ou inactive) de compa_ase.config_compa_ase : l'y declarer avant de relancer."
        return $E_CONFIG
    fi
    IFS=$'\t' read -r "ASE_LOGIN[$1]" "ASE_PASS[$1]" <<<"$row"
}

# ------------------------------------------------------------------------------
# Acces ASE via isql
#   Le mot de passe est transmis sur l'entree standard (premiere ligne), jamais en
#   argument : il n'apparait donc pas dans la liste des processus.
# ------------------------------------------------------------------------------
ISQL_OUT=""

run_isql() {   # $1 = cote (1|2), $2 = instance, $3 = base de contexte, $4 = requete SQL
    local rc
    ISQL_OUT=$(printf '%s\nset nocount on\ngo\n%s\ngo\n' "${ASE_PASS[$1]}" "$4" \
        | LANG="${ASE_LANG:-en_US.UTF-8}" LC_ALL="${ASE_LANG:-en_US.UTF-8}" isql -S "$2" -D "$3" -U "${ASE_LOGIN[$1]}" -w 4096 -b -s '|' 2>&1)
    rc=$?
    # isql peut afficher l'invite "Password:" devant la premiere ligne de sortie
    ISQL_OUT=$(printf '%s\n' "$ISQL_OUT" | tr -d '\r' | sed -e '1s/^Password: *//')
    [ $rc -eq 0 ] || return 1
    # isql retourne souvent 0 meme en cas d'echec de connexion ou d'erreur SQL
    if printf '%s\n' "$ISQL_OUT" | grep -Eq '^(Msg [0-9]+, Level [0-9]+|CT-LIBRARY error|Open Client Message|ct_connect|ct_init|Login failed)'; then
        return 1
    fi
    return 0
}

show_isql_error() {
    printf '%s\n' "$ISQL_OUT" | grep -v '^[[:space:]]*$' | head -n 3 | sed 's/^/    /' >&2
}

# Corps de CSV : retire lignes vides et "(n rows affected)", espaces de remplissage d'isql
# et le '|' que cet isql ajoute en tete et en fin de ligne avec -s '|' (sinon 2 colonnes vides en trop)
csv_body() {
    sed -E \
        -e '/^[[:space:]]*$/d' \
        -e '/^\([0-9]+ rows? affected\)/d' \
        -e 's/[[:space:]]*\|[[:space:]]*/|/g' \
        -e 's/^[[:space:]]+//' \
        -e 's/[[:space:]]+$//' \
        -e 's/^\|(.*)\|$/\1/'
}

check_ase() {   # $1 = cote, $2 = instance ; retourne E_ASE si la connexion echoue
    log "Connexion a l'instance $2..."
    if ! run_isql "$1" "$2" master "select @@servername"; then
        err "Connexion a l'instance ASE '$2' impossible :"
        show_isql_error
        return $E_ASE
    fi
}

extract_side() {   # $1 = cote (1|2), $2 = instance, $3 = base
    local mod ctx sql out="$WORK/r$1"
    for mod in "${MODULES[@]}"; do
        ctx=master
        [ "${CONTEXT[$mod]}" = db ] && ctx=$3
        sql=$(sed "s/__DB__/$3/g" "$QUERIES_DIR/$mod.sql")
        log "Extraction $2.$3 : $mod"
        if ! run_isql "$1" "$2" "$ctx" "$sql"; then
            err "Echec de l'extraction du module $mod sur $2.$3 :"
            show_isql_error
            return 1
        fi
        { echo "${HEADERS[$mod]}"; printf '%s\n' "$ISQL_OUT" | csv_body; } > "${out}_${mod}.csv"
    done
}

# ------------------------------------------------------------------------------
# Une comparaison (traitement unitaire) : run_unit INSTANCE1 BASE1 INSTANCE2 BASE2
#   Retourne le code de sortie du traitement (0 = comparaison terminee). Ne quitte jamais le script :
#   le mode batch enchaine les couples. Le run et le dossier de travail sont nettoyes a la fin.
# ------------------------------------------------------------------------------
run_unit_body() {
    local s1=$1 d1=$2 s2=$3 d2=$4 rc
    ASE_LOGIN=() ASE_PASS=()

    fetch_creds 1 "$s1" || return $?
    fetch_creds 2 "$s2" || return $?
    check_ase 1 "$s1" || return $?
    check_ase 2 "$s2" || return $?

    # Reference (refid) et run
    REFID=$(pg -At -v i1="$s1" -v b1="$d1" -v i2="$s2" -v b2="$d2" 2>&1 <<'SQL'
select compa_ase.get_or_create_refid(:'i1', :'b1', :'i2', :'b2');
SQL
    )
    if ! [[ $REFID =~ ^[0-9]+$ ]]; then
        err "Creation de la reference impossible : $REFID"
        return $E_PREREQ
    fi
    RUN_ID=$(pg -At -v refid="$REFID" 2>&1 <<'SQL'
select compa_ase.start_run(:refid);
SQL
    )
    if ! [[ $RUN_ID =~ ^[0-9]+$ ]]; then
        err "Ouverture du run impossible : $RUN_ID"
        RUN_ID=""
        return $E_PREREQ
    fi
    RUN_OPEN=1
    log "Reference refid=$REFID : $s1.$d1 vs $s2.$d2 (run_id=$RUN_ID)"

    # Extraction (7 modules x 2 cotes)
    WORK=$(mktemp -d "$WORK_ROOT/compa_ase_run${RUN_ID}_XXXXXX") || { fail_run "dossier de travail impossible"; return $E_PREREQ; }
    chmod 700 "$WORK"
    if ! extract_side 1 "$s1" "$d1" || ! extract_side 2 "$s2" "$d2"; then
        fail_run "echec de l'extraction ASE"
        return $E_ASE
    fi

    # Comparaison (compare.py enregistre les ecarts et cloture le run)
    # Encodage reel du code source ASE (obj_source), pas forcement UTF-8 ni le jeu declare par le serveur (ex. cp850 sur serveur iso_1)
    local -a args=(--source-encoding "${COMPA_SOURCE_ENCODING:-utf-8}" --csv-dir "$WORK" --run-id "$RUN_ID" --refid "$REFID" -U "$PG_USER")
    [ -n "$PG_HOST" ] && args+=(-H "$PG_HOST")
    [ -n "$PG_PORT" ] && args+=(-p "$PG_PORT")
    [ -n "$PG_DB" ] && args+=(-n "$PG_DB")

    log "Comparaison des extractions..."
    "$PY" "$COMPARE_PY" "${args[@]}"
    rc=$?
    RUN_OPEN=0      # compare.py a cloture le run (TERMINE ou ERREUR)
    return $rc
}

run_unit() {
    local rc
    run_unit_body "$@"
    rc=$?
    unit_cleanup $rc
    return $rc
}

# ------------------------------------------------------------------------------
# Mode batch : une comparaison par ligne active de compa_ase.batch_run
# ------------------------------------------------------------------------------
record_batch_result() {   # $1..$4 = couple, $5 = code retour, $6 = debut (epoch), $7 = duree (s)
    local ok=f
    [ "$5" -eq 0 ] && ok=t
    pg -q -At -o /dev/null -v b1="$1" -v b2="$2" -v b3="$3" -v b4="$4" -v ok="$ok" -v t0="$6" -v el="$7" <<'SQL' \
        || warn "Mise a jour de compa_ase.batch_run impossible pour $1/$2 contre $3/$4."
update compa_ase.batch_run
   set status_run = :'ok'::boolean,
       last_run   = to_timestamp(:'t0'::bigint),
       elapse     = make_interval(secs => :'el'::int)
 where ds1 = :'b1' and db1 = :'b2' and ds2 = :'b3' and db2 = :'b4';
SQL
}

run_batch() {
    local -a rows
    local row ds1 db1 ds2 db2 t0 rc n=0 nok=0 nko=0
    # Lecture complete avant la boucle : psql et isql lisent l'entree standard, une boucle "while read" les perturberait
    mapfile -t rows < <(pg -At -F $'\t' -c "select ds1, db1, ds2, db2 from compa_ase.batch_run where actif order by ds1, db1, ds2, db2")
    if [ "${#rows[@]}" -eq 0 ]; then
        warn "Aucun couple actif dans compa_ase.batch_run : rien a comparer."
        return 0
    fi
    log "Batch : ${#rows[@]} comparaison(s) a executer."
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r ds1 db1 ds2 db2 <<<"$row"
        n=$((n + 1))
        log "Batch $n/${#rows[@]} : $ds1.$db1 vs $ds2.$db2"
        t0=$(date +%s)
        if valid_names "$ds1" "$db1" "$ds2" "$db2"; then
            run_unit "$ds1" "$db1" "$ds2" "$db2"
            rc=$?
        else
            rc=$E_USAGE
        fi
        record_batch_result "$ds1" "$db1" "$ds2" "$db2" "$rc" "$t0" "$(( $(date +%s) - t0 ))"
        if [ "$rc" -eq 0 ]; then
            nok=$((nok + 1))
        else
            nko=$((nko + 1))
            warn "Batch : $ds1.$db1 vs $ds2.$db2 en echec (code $rc)."
        fi
    done
    log "Batch termine : $nok comparaison(s) reussie(s), $nko en echec."
    [ "$nko" -eq 0 ] || return $E_BATCH
}

preflight || exit $?

if [ "$BATCH" = 1 ]; then
    run_batch
    exit $?
fi
run_unit "$SRV1" "$DB1" "$SRV2" "$DB2"
exit $?
