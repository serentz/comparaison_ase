#!/bin/bash

# ==============================================================================
# Script de comparaison d'instances et de bases de données SAP Sybase ASE 16.0
# Gestion des arguments par getopts (OPTARG) et envoi par Email
# ==============================================================================

# Fonction d'usage/aide
usage() {
    echo "Usage: $0 -s <INSTANCE_1> -d <DB_1> -t <INSTANCE_2> -b <DB_2> [-m <EMAIL>]"
    echo "  -s : Nom de l'instance 1"
    echo "  -d : Nom de la base de données 1"
    echo "  -t : Nom de l'instance 2"
    echo "  -b : Nom de la base de données 2"
    echo "  -m : Adresse email pour l'envoi du rapport (Optionnel)"
    exit 1
}

# Initialisation des variables
SRV1=""
DB1=""
SRV2=""
DB2=""
EMAIL_DEST=""

# Analyse des arguments via getopts
while getopts "s:d:t:b:m:" opt; do
    case $opt in
        s) SRV1=$OPTARG ;;
        d) DB1=$OPTARG ;;
        t) SRV2=$OPTARG ;;
        b) DB2=$OPTARG ;;
        m) EMAIL_DEST=$OPTARG ;;
        *) usage ;;
    esac
done

# Vérification que tous les arguments obligatoires sont présents
if [ -z "$SRV1" ] || [ -z "$DB1" ] || [ -z "$SRV2" ] || [ -z "$DB2" ]; then
    echo "[-] Erreur : Les paramètres -s, -d, -t, -b sont obligatoires."
    usage
fi

# ------------------------------------------------------------------------------
# CONFIGURATION DE LA CONNEXION
# ------------------------------------------------------------------------------
DB_USER="sa"
DB_PASS="votre_mot_de_passe"

# Dossier temporaire unique
TMP_DIR="/tmp/ase_comp_$$.tmp"
mkdir -p "$TMP_DIR"

# Initialisation du fichier de rapport final
REPORT_FILE="rapport_comparaison_${SRV1}_vs_${SRV2}.txt"
> "$REPORT_FILE"

# Nettoyage automatique en sortie
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Exécution ISQL
run_isql() {
    local srv=$1
    local db=$2
    local query=$3
    isql -S "$srv" -D "$db" -U "$DB_USER" -P "$DB_PASS" -w 2000 -b -s ";" <<EOF
set nocount on
go
$query
go
EOF
}

# ==============================================================================
# 1. FONCTIONS D'EXTRACTION DES DONNÉES
# ==============================================================================
extract_data() {
    local srv=$1
    local db=$2
    local pfx="$TMP_DIR/${srv}_${db}"

    echo "[+] Extraction des données depuis $srv.$db..."

    # --- INSTANCE ---
    run_isql "$srv" "master" "select name, value, value_in_use from sysconfigures order by name" > "${pfx}_inst_config.txt"

    # --- BASE DE DONNÉES ---
    local q_db_size="select d.name, u.segmap, sum(u.size) * 2 / 1024 from sysdatabases d, sysusages u where d.name='$db' and d.dbid=u.dbid group by d.name, u.segmap"
    run_isql "$srv" "master" "$q_db_size" > "${pfx}_db_size.txt"
    
    run_isql "$srv" "master" "select status, status2, status3, status4 from sysdatabases where name='$db'" > "${pfx}_db_options.txt"

    # --- OBJECTS ---
    local q_tables="select o.name, c.name, t.name, c.length, c.prec, c.scale, c.status 
                    from sysobjects o, syscolumns c, systypes t 
                    where o.type='U' and o.id=c.id and c.utype=t.utype order by o.name, c.colid"
    run_isql "$srv" "$db" "$q_tables" > "${pfx}_obj_tables.txt"

    local q_indexes="select o.name, i.name, i.status, dateadd(ss, i.statstamp, '1970-01-01') 
                     from sysobjects o, sysindexes i 
                     where o.type='U' and o.id=i.id and i.indid > 0 and i.name not like '_sys_tabstats%' order by o.name, i.name"
    run_isql "$srv" "$db" "$q_indexes" > "${pfx}_obj_indexes.txt"

    local q_code="select name, type from sysobjects where type in ('V', 'P', 'TR') order by type, name"
    run_isql "$srv" "$db" "$q_code" > "${pfx}_obj_code.txt"

    local q_source="select '/* OBJECT_START: ' + o.name + ' (' + o.type + ') */', c.text
                    from sysobjects o, syscomments c
                    where o.id = c.id and o.type in ('V', 'P', 'TR')
                    order by o.type, o.name, c.colid"
    run_isql "$srv" "$db" "$q_source" > "${pfx}_obj_source.txt"
}

# ==============================================================================
# 2. FONCTIONS DE COMPARAISON DES DONNÉES
# ==============================================================================
compare_data() {
    echo "[+] Comparaison différentielle des éléments..."
    
    diff "${TMP_DIR}/${SRV1}_${DB1}_inst_config.txt" "${TMP_DIR}/${SRV2}_${DB2}_inst_config.txt" > "${TMP_DIR}/diff_inst_config.diff"
    diff "${TMP_DIR}/${SRV1}_${DB1}_db_size.txt" "${TMP_DIR}/${SRV2}_${DB2}_db_size.txt" > "${TMP_DIR}/diff_db_size.diff"
    diff "${TMP_DIR}/${SRV1}_${DB1}_db_options.txt" "${TMP_DIR}/${SRV2}_${DB2}_db_options.txt" > "${TMP_DIR}/diff_db_options.diff"
    diff "${TMP_DIR}/${SRV1}_${DB1}_obj_tables.txt" "${TMP_DIR}/${SRV2}_${DB2}_obj_tables.txt" > "${TMP_DIR}/diff_obj_tables.diff"
    diff "${TMP_DIR}/${SRV1}_${DB1}_obj_indexes.txt" "${TMP_DIR}/${SRV2}_${DB2}_obj_indexes.txt" > "${TMP_DIR}/diff_obj_indexes.diff"
    diff "${TMP_DIR}/${SRV1}_${DB1}_obj_code.txt" "${TMP_DIR}/${SRV2}_${DB2}_obj_code.txt" > "${TMP_DIR}/diff_obj_code.diff"
    diff "${TMP_DIR}/${SRV1}_${DB1}_obj_source.txt" "${TMP_DIR}/${SRV2}_${DB2}_obj_source.txt" > "${TMP_DIR}/diff_obj_source.diff"
}

# ==============================================================================
# 3. MISE EN FORME DU RÉSULTAT ET RAPPORT
# ==============================================================================
format_result() {
    echo "[+] Analyse des écarts et construction du rapport final..."
    
    count_diffs() {
        local diff_file=$1
        if [ ! -s "$diff_file" ]; then
            echo "0 (OK)"
        else
            local nb_lines=$(grep -c '^[<>]' "$diff_file")
            echo "$nb_lines écart(s)"
        fi
    }

    STATUS_CONF=$(count_diffs "${TMP_DIR}/diff_inst_config.diff")
    STATUS_SIZE=$(count_diffs "${TMP_DIR}/diff_db_size.diff")
    STATUS_OPT=$(count_diffs "${TMP_DIR}/diff_db_options.diff")
    STATUS_TAB=$(count_diffs "${TMP_DIR}/diff_obj_tables.diff")
    STATUS_IDX=$(count_diffs "${TMP_DIR}/diff_obj_indexes.diff")
    STATUS_COD=$(count_diffs "${TMP_DIR}/diff_obj_code.diff")
    STATUS_SRC=$(count_diffs "${TMP_DIR}/diff_obj_source.diff")

    {
        echo "======================================================================="
        echo " RAPPORT DE COMPARAISON SYBASE ASE 16.0"
        echo " Date de génération : $(date)"
        echo " Environnement : [$SRV1].[$DB1] VS [$SRV2].[$DB2]"
        echo "======================================================================="
        echo ""
        echo "-----------------------------------------------------------------------"
        echo " 1. TABLEAU RÉCAPITULATIF DES ÉCARTS"
        echo "-----------------------------------------------------------------------"
        printf "%-45s | %-20s\n" "Élément analysé" "Nombre de différences"
        printf "%-45s | %-20s\n" "---------------------------------------------" "--------------------"
        printf "%-45s | %-20s\n" "Configuration Instance (sysconfigures)" "$STATUS_CONF"
        printf "%-45s | %-20s\n" "Options Base de Données (sysdatabases)" "$STATUS_OPT"
        printf "%-45s | %-20s\n" "Taille Data / Log (sysusages)" "$STATUS_SIZE"
        printf "%-45s | %-20s\n" "Structure des Tables & Defaults (syscolumns)" "$STATUS_TAB"
        printf "%-45s | %-20s\n" "Index & Update Statistics (sysindexes)" "$STATUS_IDX"
        printf "%-45s | %-20s\n" "Présence des Vues, Procédures & Triggers" "$STATUS_COD"
        printf "%-45s | %-20s\n" "Code source (Contenu syscomments)" "$STATUS_SRC"
        echo "-----------------------------------------------------------------------"
        echo ""
        echo "-----------------------------------------------------------------------"
        echo " 2. DÉTAIL DES DIFFÉRENCES (< $SRV1 / > $SRV2)"
        echo "-----------------------------------------------------------------------"
        
        if [ "$STATUS_CONF" != "0 (OK)" ]; then
            echo "### Écarts Configuration Instance ###"
            cat "${TMP_DIR}/diff_inst_config.diff"
            echo ""
        fi
        
        if [ "$STATUS_OPT" != "0 (OK)" ] || [ "$STATUS_SIZE" != "0 (OK)" ]; then
            echo "### Écarts Base de données (Taille/Options) ###"
            [ -s "${TMP_DIR}/diff_db_size.diff" ] && cat "${TMP_DIR}/diff_db_size.diff"
            [ -s "${TMP_DIR}/diff_db_options.diff" ] && cat "${TMP_DIR}/diff_db_options.diff"
            echo ""
        fi
        
        if [ "$STATUS_TAB" != "0 (OK)" ]; then
            echo "### Écarts Structure Tables (Colonnes, Types, Nullabilité) ###"
            cat "${TMP_DIR}/diff_obj_tables.diff"
            echo ""
        fi

        if [ "$STATUS_IDX" != "0 (OK)" ]; then
            echo "### Écarts Index et Dates de mise à jour des statistiques ###"
            cat "${TMP_DIR}/diff_obj_indexes.diff"
            echo ""
        fi

        if [ "$STATUS_COD" != "0 (OK)" ]; then
            echo "### Écarts Liste des Vues, Procédures stockées et Triggers (Présence) ###"
            cat "${TMP_DIR}/diff_obj_code.diff"
            echo ""
        fi

        if [ "$STATUS_SRC" != "0 (OK)" ]; then
            echo "### Écarts de Code Source (Contenu) ###"
            cat "${TMP_DIR}/diff_obj_source.diff"
            echo ""
        fi
        
    } >> "$REPORT_FILE"

    echo "[✓] Le rapport complet a été généré avec succès : $REPORT_FILE"
}

# ==============================================================================
# 4. ENVOI DU RAPPORT PAR EMAIL
# ==============================================================================
send_report_mail() {
    if [ -n "$EMAIL_DEST" ]; then
        echo "[+] Envoi du rapport par email à $EMAIL_DEST..."
        local subject="Rapport Comparaison Sybase ASE : $SRV1 VS $SRV2"
        
        # Utilisation de mailx (ou mail). S'adapte à la majorité des Linux.
        if command -v mailx &>/dev/null; then
            mailx -s "$subject" "$EMAIL_DEST" < "$REPORT_FILE"
        elif command -v mail &>/dev/null; then
            mail -s "$subject" "$EMAIL_DEST" < "$REPORT_FILE"
        else
            echo "[-] Erreur : Ni 'mailx' ni 'mail' n'ont été trouvés sur ce système. Impossible d'envoyer l'email."
            return 1
        fi
        echo "[✓] Email envoyé."
    fi
}

# ==============================================================================
# EXECUTION DU FLUX PRINCIPAL
# ==============================================================================
extract_data "$SRV1" "$DB1"
extract_data "$SRV2" "$DB2"
compare_data
format_result
send_report_mail