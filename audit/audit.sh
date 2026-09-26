#!/usr/bin/env bash
# `cargo audit` (RustSec) sur le `Cargo.lock` du module — sans rien compiler du module.
#
# Le binaire vient de la release de RustSec, épinglé par version et par SHA-256 : ni `cargo
# install` (deux minutes de compilation), ni build du module. Il lit le lockfile et la base
# d'avis ; il n'exécute pas une ligne du module.
#
# Entrées (environnement) : FAIL_ON (critical | high | medium | low | none), REPORT (chemin du
# rapport, relatif au répertoire courant). Sortie : `report=<chemin absolu>`.
set -euo pipefail

VERSION="0.22.2"
case "${RUNNER_OS:-}-${RUNNER_ARCH:-}" in
  Linux-X64) target=x86_64-unknown-linux-musl sum=7fb9497f8594b389e5fce5ef9b92db08432996895b2e0c5a0167a69ed445c428 ;;
  Linux-ARM64) target=aarch64-unknown-linux-gnu sum=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd ;;
  macOS-ARM64) target=aarch64-apple-darwin sum=ec7ca4263769593df4d909be85b94a6b79efa2897be5d2bb8ebd516e823175af ;;
  macOS-X64) target=x86_64-apple-darwin sum=847831323de932155b226ab60ee4a180e13e5d007a019f0d4b7b4d89a6de2ab2 ;;
  *) echo "::error::no prebuilt cargo-audit for ${RUNNER_OS:-?}/${RUNNER_ARCH:-?}"; exit 1 ;;
esac

# Le `Cargo.lock` le plus proche en remontant : un module de monorepo partage celui de la racine.
directory="$PWD"
lock=""
while [ "$directory" != "/" ]; do
  if [ -f "$directory/Cargo.lock" ]; then lock="$directory/Cargo.lock"; break; fi
  directory="$(dirname "$directory")"
done
if [ -z "$lock" ]; then
  echo "::error::no Cargo.lock found above $PWD — cargo audit reads the lockfile, not Cargo.toml"
  exit 1
fi

work="${RUNNER_TEMP:?}/portaki-cargo-audit"
rm -rf "$work"
mkdir -p "$work"
archive="cargo-audit-${target}-v${VERSION}.tgz"
curl -fsSL --retry 3 -o "$work/$archive" \
  "https://github.com/rustsec/rustsec/releases/download/cargo-audit%2Fv${VERSION}/${archive}"
if command -v sha256sum >/dev/null; then
  actual="$(sha256sum "$work/$archive" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "$work/$archive" | awk '{ print $1 }')"
fi
if [ "$actual" != "$sum" ]; then
  echo "::error::SHA-256 mismatch for ${archive}: expected ${sum}, got ${actual} — not running it."
  exit 1
fi
tar -xzf "$work/$archive" -C "$work"
binary="$work/cargo-audit-${target}-v${VERSION}/cargo-audit"

# Code de sortie ignoré : `cargo audit` rend 1 dès qu'il trouve quelque chose, et le seuil est
# le nôtre. Un JSON absent ou illisible, lui, fait échouer plus bas — une base d'avis
# injoignable ne passe pas pour un module sain.
"$binary" audit --json --file "$lock" >"$work/raw.json" || true
if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))["vulnerabilities"]' "$work/raw.json" 2>/dev/null; then
  echo "::error::cargo audit produced no report for ${lock} — see the step log"
  "$binary" audit --file "$lock" || true
  exit 1
fi

mkdir -p "$(dirname "$REPORT")"
report_path="$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
echo "report=${report_path}" >>"$GITHUB_OUTPUT"
CARGO_AUDIT_VERSION="$VERSION" python3 "$(dirname "$0")/report.py" "$work/raw.json" "$report_path" "$FAIL_ON"
