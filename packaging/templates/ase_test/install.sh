#!/usr/bin/env bash
# ============================================================
# compA_ase : cree un serveur ASE 16.0 de TEST et charge la base poc_db (ecarts voulus). POC uniquement.
#
#   sudo ./install.sh
#
# 1. installe les bibliotheques systeme requises par ASE (Rocky/RHEL : libnsl, ncurses-compat-libs, libaio),
# 2. cree le serveur ASE_NAME (infra/ase/build_server.sh : contournement CR 824104, mot de passe sa saisi),
# 3. charge la base poc_db (sql/ase_test/0<ASE_INSTANCE>_*.sql).
# Les binaires SAP ASE ne sont pas fournis : les decompresser avant dans SYBASE_DIR (voir LISEZMOI.md).
# Rejouable : un serveur deja declare dans interfaces n'est pas recree.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
load_env
require_vars SYBASE_DIR ASE_NAME ASE_PORT ASE_PAGE_SIZE ASE_INSTANCE
[[ "$ASE_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "ASE_NAME invalide : lettres, chiffres et _ uniquement."
[[ "$ASE_PORT" =~ ^[0-9]+$ ]] || die "ASE_PORT invalide."
[[ "$ASE_PAGE_SIZE" =~ ^(2|4|8|16)k$ ]] || die "ASE_PAGE_SIZE invalide : 2k, 4k, 8k ou 16k."
[[ "$ASE_INSTANCE" =~ ^[12]$ ]] || die "ASE_INSTANCE invalide : 1 ou 2."
[ -f "$SYBASE_DIR/SYBASE.sh" ] || die "$SYBASE_DIR/SYBASE.sh absent : decompresser d'abord SAP ASE 16.0 dans $SYBASE_DIR."
OWNER="${ASE_USER:-$(stat -c %U "$SYBASE_DIR")}"
id "$OWNER" >/dev/null 2>&1 || die "Le login Linux '$OWNER' (ASE_USER) n'existe pas."

# --- 1. Bibliotheques systeme -------------------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
    log "Bibliotheques requises par ASE (dnf)"
    dnf install -y -q libnsl ncurses-compat-libs libaio >/dev/null
elif command -v apt-get >/dev/null 2>&1; then
    apt_install libaio1 libncurses5 libnsl2 || warn "bibliotheques non installees : verifier libaio, libncurses5 et libnsl."
else
    warn "Ni dnf ni apt-get : installer a la main libnsl, ncurses (compat) et libaio."
fi

# --- 2. Serveur ASE -----------------------------------------------------------------------------------
if [ -f "$SYBASE_DIR/interfaces" ] && grep -q "^$ASE_NAME\b" "$SYBASE_DIR/interfaces"; then
    ok "serveur $ASE_NAME deja declare dans $SYBASE_DIR/interfaces : non recree"
else
    log "Creation du serveur $ASE_NAME (port $ASE_PORT, pages $ASE_PAGE_SIZE) sous le login $OWNER ; le mot de passe sa va etre demande"
    runuser -u "$OWNER" -- env SYBASE_DIR="$SYBASE_DIR" bash "$REPO_DIR/infra/ase/build_server.sh" "$ASE_NAME" "$ASE_PORT" "$ASE_PAGE_SIZE"
fi

# --- 3. Base de test -------------------------------------------------------------------------------------
"$REPO_DIR/scripts/charger-base-test.sh" "$ASE_NAME" "$ASE_INSTANCE"
log "Termine. Verification : sudo ./verify.sh"
