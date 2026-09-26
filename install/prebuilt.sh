#!/usr/bin/env bash
# Installe le binaire `portaki` précompilé de la release `v$VERSION` de portaki-sdk.
#
# Sortie `installed=true` quand le binaire est en place (dans le PATH des étapes suivantes),
# `installed=false` pour laisser `cargo install` prendre le relais. Code non nul uniquement
# quand l'archive existe mais que sa somme manque ou ne correspond pas : là, rien ne s'exécute.
set -euo pipefail

skip() {
  echo "$1 — falling back to \`cargo install\`."
  echo "installed=false" >>"$GITHUB_OUTPUT"
  exit 0
}

case "${RUNNER_OS:-}-${RUNNER_ARCH:-}" in
  Linux-X64) target=x86_64-unknown-linux-gnu ;;
  macOS-ARM64) target=aarch64-apple-darwin ;;
  *) skip "No prebuilt CLI for ${RUNNER_OS:-?}/${RUNNER_ARCH:-?}" ;;
esac

# Une version exacte seulement : `version:` accepte aussi ce que `cargo install --version`
# comprend (`^8`, `>=8.1`), qui ne nomme aucune release.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  skip "\`${VERSION}\` is not an exact version"
fi

archive="portaki-${VERSION}-${target}.tar.gz"
base="https://github.com/PortakiApp/portaki-sdk/releases/download/v${VERSION}"
work="${RUNNER_TEMP:?}/portaki-prebuilt"
bin="${RUNNER_TEMP}/portaki-bin"
rm -rf "$work" "$bin"
mkdir -p "$work" "$bin"

# Toute erreur ici (404 d'une version sans asset, réseau) ne coûte que le repli.
if ! curl -fsSL --retry 3 -o "$work/$archive" "$base/$archive"; then
  skip "No prebuilt ${archive} in release v${VERSION}"
fi

if ! curl -fsSL --retry 3 -o "$work/$archive.sha256" "$base/$archive.sha256"; then
  echo "::error::${archive} is published without its ${archive}.sha256 — refusing to run it."
  exit 1
fi

expected="$(awk '{ print $1; exit }' "$work/$archive.sha256")"
if command -v sha256sum >/dev/null; then
  actual="$(sha256sum "$work/$archive" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "$work/$archive" | awk '{ print $1 }')"
fi
if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || [ "$actual" != "$expected" ]; then
  echo "::error::SHA-256 mismatch for ${archive}: expected '${expected}', got '${actual}'."
  exit 1
fi

tar -xzf "$work/$archive" -C "$bin" portaki
chmod +x "$bin/portaki"
# Construit sur `ubuntu-latest` : une image plus ancienne peut manquer de la glibc qu'il vise.
if ! "$bin/portaki" -V >/dev/null 2>&1; then
  rm -rf "$bin"
  skip "The prebuilt CLI does not run on this runner"
fi
echo "$bin" >>"$GITHUB_PATH"
echo "installed=true" >>"$GITHUB_OUTPUT"
echo "Portaki CLI ${VERSION} (${target}) installed from the prebuilt release, sha256 ${actual}."
