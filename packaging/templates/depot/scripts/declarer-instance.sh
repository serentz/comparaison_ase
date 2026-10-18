#!/usr/bin/env bash
# ============================================================
# compA_ase : declare (ou met a jour) une instance ASE a comparer dans compa_ase.config_compa_ase
#
#   sudo ./scripts/declarer-instance.sh NOM HOTE PORT LOGIN ["commentaire"]
#   INSTANCE_PASSWORD=... sudo -E ./scripts/declarer-instance.sh ASE1 ase01 5000 sa
#
# NOM est le nom utilise ensuite avec -S / -s de compa_ase. Le mot de passe du login est lu dans
# INSTANCE_PASSWORD, sinon demande (jamais en argument : visible dans la liste des processus).
# Login ASE : lecture de master et de la base comparee suffit (sa dans le POC). Voir docs/premiere_execution.md du depot.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
load_env
[ $# -ge 4 ] || die "Usage : $0 NOM HOTE PORT LOGIN [commentaire]"
NAME="$1" HOST="$2" PORT="$3" LOGIN="$4" COMMENT="${5:-}"
[[ "$NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "NOM invalide : lettres, chiffres, _ . - uniquement."
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT invalide."
PW="${INSTANCE_PASSWORD:-}"
if [ -z "$PW" ]; then read -r -s -p "Mot de passe du login $LOGIN sur $HOST:$PORT : " PW; echo; fi
[ -n "$PW" ] || die "Mot de passe vide."
PSQL_CMD="${PSQL_CMD:-runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p $PG_PORT}"
$PSQL_CMD -d "$DEPOT_DB" -v n="$NAME" -v h="$HOST" -v p="$PORT" -v l="$LOGIN" -v pw="$PW" -v c="$COMMENT" <<'SQL'
INSERT INTO compa_ase.config_compa_ase (instance, host, port, login, password, commentaire)
VALUES (:'n', :'h', :'p'::int, :'l', :'pw', nullif(:'c', ''))
ON CONFLICT (instance) DO UPDATE
   SET host = EXCLUDED.host, port = EXCLUDED.port, login = EXCLUDED.login,
       password = EXCLUDED.password, commentaire = EXCLUDED.commentaire, actif = true;
SQL
ok "instance ASE $NAME declaree ($LOGIN@$HOST:$PORT)"
