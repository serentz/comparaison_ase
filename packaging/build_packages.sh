#!/usr/bin/env bash
# ============================================================
# compA_ase : construit les 4 archives de deploiement dans Deploy/
#
#   packaging/build_packages.sh [VERSION]      (VERSION par defaut : git describe)
#
#   Deploy/compa_ase_depot.tgz          base de resultats : PostgreSQL, schema compa_ase
#   Deploy/compa_ase_comparateur.tgz    compare_ase.sh, requetes, compare.py, planification
#   Deploy/compa_ase_grafana.tgz        Grafana : source de donnees et 8 dashboards
#   Deploy/compa_ase_serveurs_ase_test.tgz  serveur ASE de TEST + base poc_db avec ecarts voulus (POC)
#   Deploy/SHA256SUMS                  empreintes des 4 archives
#
# Les fichiers viennent du depot (une seule source) ; packaging/templates/ ne contient que ce qui est propre
# aux archives (LISEZMOI, install.sh, verify.sh, scripts, planification). Archives reproductibles :
# memes sources = memes octets (date du dernier commit, tri des fichiers, proprietaire root).
# Necessite : bash, tar, gzip, sha256sum ; git (facultatif, pour la version).
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/packaging/templates"
OUT="${OUT_DIR:-$ROOT/Deploy}"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo inconnue)"; fi
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo inconnu)"
EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)"

die() { echo "ERREUR : $*" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

begin() { PKG="$1"; PKG_NAME="compa_ase_$2"; PKG_DIR="$WORK/$PKG_NAME"; mkdir -p "$PKG_DIR"; }
# add SRC [DST] [MODE] : fichier du depot -> archive.
add() { [ -f "$ROOT/$1" ] || die "fichier absent du depot : $1"; install -D -m "${3:-0644}" "$ROOT/$1" "$PKG_DIR/${2:-$1}"; }
# tpl SRC [DST] [MODE] : fichier de packaging/templates/<archive>/ (marqueurs remplaces) -> archive.
tpl() {
    local src="$TPL/$PKG/$1" dst="$PKG_DIR/${2:-$1}"
    [ -f "$src" ] || die "modele absent : packaging/templates/$PKG/$1"
    mkdir -p "$(dirname "$dst")"
    sed -e "s|{{VERSION}}|$VERSION|g" "$src" > "$dst"
    chmod "${3:-0644}" "$dst"
}
common() { mkdir -p "$PKG_DIR/scripts"; install -m 0644 "$TPL/common/lib.sh" "$PKG_DIR/scripts/lib.sh"; }

finish() {
    printf 'compA_ase %s\narchive : %s\ncommit : %s\n' "$VERSION" "$PKG_NAME" "$COMMIT" > "$PKG_DIR/VERSION"
    ( cd "$PKG_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum | sed 's| \./| |' > SHA256SUMS )
    mkdir -p "$OUT"
    ( cd "$WORK" && find "$PKG_NAME" -exec touch -h -d "@$EPOCH" {} + \
        && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" -cf - "$PKG_NAME" | gzip -n -9 > "$OUT/$PKG_NAME.tgz" )
    echo "  $OUT/$PKG_NAME.tgz ($(find "$PKG_DIR" -type f | wc -l) fichiers, $(du -k "$OUT/$PKG_NAME.tgz" | cut -f1) Ko)"
}

echo "compA_ase : construction des archives (version $VERSION, commit $COMMIT)"
rm -f "$OUT"/compa_ase_*.tgz "$OUT"/SHA256SUMS

# ---- 1. Depot : base de resultats -------------------------------------------------------------
begin depot depot
tpl LISEZMOI.md; tpl install.sh "" 0755; tpl verify.sh "" 0755; common
tpl compa_ase.env.example scripts/compa_ase.env.example
tpl scripts/declarer-instance.sh "" 0755
add sql/postgres/create_schema.sql sql/create_schema.sql
finish

# ---- 2. Comparateur ------------------------------------------------------------------------
begin comparateur comparateur
tpl LISEZMOI.md; tpl install.sh "" 0755; tpl verify.sh "" 0755; common
tpl compa_ase.env.example scripts/compa_ase.env.example
tpl scripts/compa_ase-planifie.sh "" 0755; tpl scripts/planifie.conf.example
tpl systemd/compa_ase-planifie.service; tpl systemd/compa_ase-planifie.timer; tpl cron/compa_ase.cron
add bash/compare_ase.sh bash/compare_ase.sh 0755
for f in "$ROOT"/bash/queries/*.sql; do add "bash/queries/$(basename "$f")"; done
add python/compare.py python/compare.py 0755
finish

# ---- 3. Grafana ------------------------------------------------------------------------------
begin grafana grafana
tpl LISEZMOI.md; tpl install.sh "" 0755; tpl verify.sh "" 0755; common
tpl compa_ase.env.example scripts/compa_ase.env.example
for f in "$ROOT"/grafana/dashboards/*.json; do add "grafana/dashboards/$(basename "$f")" "dashboards/$(basename "$f")"; done
add grafana/provisioning/datasources/compa_ase.yaml provisioning/datasources/compa_ase.yaml
add grafana/provisioning/dashboards/compa_ase.yaml provisioning/dashboards/compa_ase.yaml
finish

# ---- 4. Serveurs ASE de test -------------------------------------------------------------------
begin ase_test serveurs_ase_test
tpl LISEZMOI.md; tpl install.sh "" 0755; tpl verify.sh "" 0755; common
tpl compa_ase.env.example scripts/compa_ase.env.example
tpl scripts/charger-base-test.sh "" 0755
add infra/ase/build_server.sh infra/ase/build_server.sh 0755
for f in "$ROOT"/sql/ase_test/*.sql; do add "sql/ase_test/$(basename "$f")"; done
finish

( cd "$OUT" && sha256sum compa_ase_*.tgz > SHA256SUMS )
echo "Termine. Empreintes : $OUT/SHA256SUMS"
