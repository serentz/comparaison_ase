#!/usr/bin/env bash
# ============================================================
# compA_ase : charge la base de test poc_db sur un serveur ASE.
#
#   ./scripts/charger-base-test.sh NOM_SERVEUR 1|2
#
# ATTENTION : SUPPRIME puis recree la base poc_db. Le mot de passe sa est lu dans ASE_SA_PASSWORD, sinon demande
# (jamais en argument). L'instance 1 et l'instance 2 different volontairement (30 ecarts en tout).
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
[ $# -eq 2 ] || die "Usage : $0 NOM_SERVEUR 1|2"
NAME="$1" N="$2"
[[ "$NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "NOM_SERVEUR invalide."
[[ "$N" =~ ^[12]$ ]] || die "Le numero d'instance doit etre 1 ou 2."
. "$SYBASE_DIR/SYBASE.sh"
command -v isql >/dev/null 2>&1 || die "isql introuvable apres $SYBASE_DIR/SYBASE.sh"
SQL="$(ls "$REPO_DIR"/sql/ase_test/0${N}_*.sql)"
PW="${ASE_SA_PASSWORD:-}"
if [ -z "$PW" ]; then read -r -s -p "Mot de passe sa de $NAME : " PW; echo; fi
[ -n "$PW" ] || die "Mot de passe vide."
LOGF="$(mktemp)"
# Le mot de passe passe par l'entree standard (invite d'isql), pas par -P (visible dans ps).
printf '%s\n' "$PW" | LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 isql -S "$NAME" -U sa -i "$SQL" -o "$LOGF" || { cat "$LOGF" >&2; rm -f "$LOGF"; die "isql a echoue sur $NAME"; }
if grep -Eq '^Msg [0-9]+, Level (1[1-9]|2[0-9])' "$LOGF"; then
    grep -E '^Msg ' "$LOGF" | head -n 5 >&2; rm -f "$LOGF"; die "erreurs ASE pendant le chargement (journal ci-dessus)"
fi
rm -f "$LOGF"
ok "base poc_db chargee sur $NAME (script $(basename "$SQL"))"
