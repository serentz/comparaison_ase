#!/usr/bin/env bash
# ============================================================
# compA_ase : installation du comparateur (extraction isql + compare.py)
#
#   sudo ./install.sh
#
# Installe psql et Python 3 (isql, le client SAP Open Client, doit deja etre installe), copie les programmes dans INSTALL_DIR, ecrit l'acces a la base de resultats
# dans /etc/compa_ase/compa_ase.env (lisible par RUN_USER seul) et cree la commande `compa_ase`.
# Rejouable. Prerequis : base de resultats installee (archive « depot »), scripts/compa_ase.env renseigne.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
load_env
require_vars PG_HOST PG_PORT PG_DB PG_USER PG_PASSWORD
check_password PG_PASSWORD
INSTALL_DIR="${INSTALL_DIR:-/opt/compa_ase}"
RUN_USER="${RUN_USER:-${SUDO_USER:-}}"
[ -n "$RUN_USER" ] || die "RUN_USER vide et SUDO_USER inconnu : renseigner RUN_USER dans compa_ase.env."
id "$RUN_USER" >/dev/null 2>&1 || die "Le login Linux '$RUN_USER' (RUN_USER) n'existe pas."
ETC_DIR="${COMPA_ETC_DIR:-/etc/compa_ase}"      # surchargeables pour les tests
BIN_DIR="${COMPA_BIN_DIR:-/usr/local/bin}"
UNIT_DIR="${COMPA_UNIT_DIR:-/etc/systemd/system}"

# --- 1. Composants ----------------------------------------------------------------------------
missing=()
command -v psql >/dev/null 2>&1 || missing+=(postgresql-client)
command -v python3 >/dev/null 2>&1 || missing+=(python3)
if [ "${#missing[@]}" -gt 0 ]; then log "Installation de : ${missing[*]}"; apt_install "${missing[@]}"; fi
ok "psql $(psql --version | awk '{print $3}'), $(python3 --version)"

# --- 2. Programmes ----------------------------------------------------------------------------
log "Programmes dans $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bash/queries" "$INSTALL_DIR/python"
install_file "$REPO_DIR/bash/compare_ase.sh" "$INSTALL_DIR/bash/compare_ase.sh" 0755
for f in "$REPO_DIR"/bash/queries/*.sql; do install_file "$f" "$INSTALL_DIR/bash/queries/$(basename "$f")" 0644; done
install_file "$REPO_DIR/python/compare.py" "$INSTALL_DIR/python/compare.py" 0755
install_file "$REPO_DIR/scripts/compa_ase-planifie.sh" "$BIN_DIR/compa_ase-planifie" 0755
ok "$(ls "$INSTALL_DIR"/bash/queries/*.sql | wc -l) requetes d'extraction, compare.py, compare_ase.sh"

# --- 3. Acces a la base de resultats --------------------------------------------------------
mkdir -p "$ETC_DIR"
envtmp="$(mktemp)"
cat > "$envtmp" <<ENVF
# Gere par compA_ase (archive comparateur). Acces a la base de resultats ; lu par la commande compa_ase.
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_DB=$PG_DB
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
INSTALL_DIR=$INSTALL_DIR
SYBASE_ENV_FILE=${SYBASE_ENV_FILE:-}
ASE_LANG=${ASE_LANG:-en_US.UTF-8}
ENVF
install_file "$envtmp" "$ETC_DIR/compa_ase.env" 0600; rm -f "$envtmp"
chown "$RUN_USER" "$ETC_DIR/compa_ase.env" 2>/dev/null || true
chmod 0600 "$ETC_DIR/compa_ase.env"
# Liste des comparaisons planifiees : une ligne « INSTANCE1 BASE1 INSTANCE2 BASE2 », conservee si elle existe.
if [ ! -f "$ETC_DIR/planifie.conf" ]; then
    install -m 0644 "$REPO_DIR/scripts/planifie.conf.example" "$ETC_DIR/planifie.conf"
    log "cree : $ETC_DIR/planifie.conf (a editer pour la comparaison planifiee)"
fi

# --- 4. Commande compa_ase ------------------------------------------------------------------
wrap="$(mktemp)"
cat > "$wrap" <<WRAP
#!/usr/bin/env bash
# compA_ase : lance une comparaison avec l'acces a la base de resultats de $ETC_DIR/compa_ase.env.
#   compa_ase -S INSTANCE1 -D BASE1 -s INSTANCE2 -d BASE2 [-k]      (compa_ase -h : aide)
ENV_FILE="\${COMPA_ASE_ENV:-$ETC_DIR/compa_ase.env}"
[ -r "\$ENV_FILE" ] || { echo "[-] \$ENV_FILE illisible (reserve a $RUN_USER) : lancer la commande avec ce login." >&2; exit 10; }
set -a; . "\$ENV_FILE"; set +a
[ -z "\${SYBASE_ENV_FILE:-}" ] || . "\$SYBASE_ENV_FILE"
export ASE_LANG PGPASSWORD="\$PG_PASSWORD"
exec "\$INSTALL_DIR/bash/compare_ase.sh" -U "\$PG_USER" -H "\$PG_HOST" -p "\$PG_PORT" -n "\$PG_DB" "\$@"
WRAP
install_file "$wrap" "$BIN_DIR/compa_ase" 0755; rm -f "$wrap"
ok "commande $BIN_DIR/compa_ase"

# --- 5. Planification (facultative) ---------------------------------------------------------
if [ "${ENABLE_SCHEDULE:-0}" = "1" ] && [ -d /run/systemd/system ]; then
    sed -e "s|^User=.*|User=$RUN_USER|" -e "s|/usr/local/bin|$BIN_DIR|g" "$REPO_DIR/systemd/compa_ase-planifie.service" > "$UNIT_DIR/compa_ase-planifie.service"
    install_file "$REPO_DIR/systemd/compa_ase-planifie.timer" "$UNIT_DIR/compa_ase-planifie.timer" 0644
    systemctl daemon-reload
    systemctl enable --now compa_ase-planifie.timer >/dev/null
    ok "timer compa_ase-planifie actif (tous les jours a 02:30)"
else
    log "Comparaison planifiee non activee (ENABLE_SCHEDULE=0) : voir LISEZMOI.md, section Planification."
fi

# --- 5b. isql (SAP Open Client : logiciel SAP, non fourni dans l'archive) -----------------------------
if [ -n "${SYBASE_ENV_FILE:-}" ]; then
    [ -r "$SYBASE_ENV_FILE" ] || die "SYBASE_ENV_FILE illisible : $SYBASE_ENV_FILE"
    # shellcheck disable=SC1090
    ( . "$SYBASE_ENV_FILE"; command -v isql ) >/dev/null 2>&1 || warn "isql introuvable apres $SYBASE_ENV_FILE : verifier l'installation du client SAP."
elif ! command -v isql >/dev/null 2>&1; then
    warn "isql introuvable : installer SAP Open Client (ou ASE), puis renseigner SYBASE_ENV_FILE=<.../SYBASE.sh> dans compa_ase.env et relancer."
fi

# --- 6. Acces a la base de resultats ----------------------------------------------------------
if PGPASSWORD="$PG_PASSWORD" psql -X -At -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT version FROM compa_ase.schema_version" >/dev/null 2>&1; then
    ok "base de resultats joignable, schema compa_ase present"
else
    warn "Base de resultats injoignable ($PG_USER@$PG_HOST:$PG_PORT/$PG_DB) ou schema compa_ase absent : installer l'archive « depot » d'abord (ALLOW_SUBNET, mot de passe)."
fi
log "Termine. Essai : compa_ase -h   puis   compa_ase -S <inst1> -D <base1> -s <inst2> -d <base2> -k   (login $RUN_USER)"
