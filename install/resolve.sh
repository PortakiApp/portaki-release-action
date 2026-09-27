#!/usr/bin/env bash
# La version du CLI à installer : `REQUESTED` si elle est exacte, sinon le `portaki-sdk` que le
# `Cargo.lock` le plus proche résout — lu en shell, sans cargo : rien n'est encore installé, et le
# job de publication n'exécute pas cargo. Sortie : `version=<x.y.z>`.
#
# Le lock et non `Cargo.toml` : le SDK peut y être déclaré par branche git ou par chemin, et seul le
# lock dit ce qui sera compilé. Un module de monorepo partage celui de la racine.
set -euo pipefail

if [ "${REQUESTED:-auto}" != "auto" ]; then
  echo "version=${REQUESTED}" >>"$GITHUB_OUTPUT"
  echo "Portaki CLI pinned to ${REQUESTED}."
  exit 0
fi

directory="$PWD"
lock=""
while [ "$directory" != "/" ]; do
  if [ -f "$directory/Cargo.lock" ]; then lock="$directory/Cargo.lock"; break; fi
  directory="$(dirname "$directory")"
done
if [ -z "$lock" ]; then
  echo "::error::no Cargo.lock found — commit it, or pass the CLI version explicitly"
  exit 1
fi

resolved="$(awk '
  /^name = "portaki-sdk"$/ { found = 1; next }
  found && /^version = / { gsub(/[",]/, "", $3); print $3; exit }
' "$lock")"
if [ -z "$resolved" ]; then
  echo "::error file=${lock#"$PWD"/}::no portaki-sdk in the lockfile — pass the CLI version explicitly"
  exit 1
fi
echo "version=${resolved}" >>"$GITHUB_OUTPUT"
echo "Portaki SDK resolves to ${resolved}; installing the matching CLI."
