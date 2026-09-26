#!/usr/bin/env bash
# Signe l'artefact OCI qui vient d'être poussé, sans clé : l'identité est le jeton OIDC du job,
# que Fulcio échange contre un certificat éphémère, et chaque signature entre au journal Rekor.
#
# Trois pièces, attachées au digest sur le registre OCI :
#   1. la signature de l'artefact (`cosign sign`) ;
#   2. une attestation de provenance SLSA v1 — dépôt, commit, workflow, ref, run ;
#   3. le rapport `cargo audit`, en attestation `https://portaki.app/attestations/cargo-audit/v1`,
#      s'il existe.
#
# Le certificat porte lui-même le dépôt, le commit et le workflow (claims OIDC signés par
# GitHub) : c'est lui que le registre Portaki confronte à la liaison du module, pas le contenu
# de l'attestation. Aucun code du module ne tourne ici.
#
# Entrées (environnement) : REGISTRY, AUDIT_REPORT (facultatif), GITHUB_TOKEN. Sortie :
# `digest`, `image`.
set -euo pipefail

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::no OIDC token in this job — add \`permissions: id-token: write\`: keyless signing needs it."
  exit 1
fi

portaki --plain ci info >"${RUNNER_TEMP:?}/portaki-sign-info"
id="$(sed -n 1p "$RUNNER_TEMP/portaki-sign-info")"
version="$(sed -n 2p "$RUNNER_TEMP/portaki-sign-info")"

# Le nom que `portaki publish` donne à l'artefact : `<registre>/portaki-modules-<id>:<version>`.
prefix="${REGISTRY%/}"
image="${prefix%/portaki-modules}/portaki-modules-${id}"
host="${image%%/*}"
repository="${image#*/}"

# Le digest que le tag désigne à l'instant, lu sur le registre — jamais recalculé ici. Le job
# de publication tient la file (`concurrency`) : personne ne réécrit ce tag entre la poussée,
# la signature et l'annonce, qui relit le même tag.
token="$(curl -fsS -u "${GITHUB_ACTOR}:${GITHUB_TOKEN}" \
  "https://${host}/token?service=${host}&scope=repository:${repository}:pull" | jq -r '.token // empty')"
digest="$(curl -fsSI \
  -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
  "https://${host}/v2/${repository}/manifests/${version}" |
  tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }')"
if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::could not read the digest of ${image}:${version} — was it pushed?"
  exit 1
fi
subject="${image}@${digest}"

printf '%s' "$GITHUB_TOKEN" | cosign login "$host" --username "$GITHUB_ACTOR" --password-stdin >/dev/null

cosign sign --yes "$subject"

# La provenance, au format SLSA v1. Tout vient de l'environnement que GitHub pose sur le run.
server="${GITHUB_SERVER_URL:-https://github.com}"
jq -n \
  --arg repository "${server}/${GITHUB_REPOSITORY}" \
  --arg path "${GITHUB_WORKFLOW_REF#"${GITHUB_REPOSITORY}"/}" \
  --arg ref "${GITHUB_REF}" \
  --arg sha "${GITHUB_SHA}" \
  --arg event "${GITHUB_EVENT_NAME}" \
  --arg repositoryId "${GITHUB_REPOSITORY_ID:-}" \
  --arg ownerId "${GITHUB_REPOSITORY_OWNER_ID:-}" \
  --arg builder "${server}/${GITHUB_WORKFLOW_REF}" \
  --arg run "${server}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}" \
  '{
    buildDefinition: {
      buildType: "https://portaki.app/buildtypes/release-action/v1",
      externalParameters: {workflow: {repository: $repository, path: ($path | sub("@.*$"; "")), ref: $ref}},
      internalParameters: {github: {event_name: $event, repository_id: $repositoryId, repository_owner_id: $ownerId}},
      resolvedDependencies: [{uri: ("git+" + $repository + "@" + $ref), digest: {gitCommit: $sha}}]
    },
    runDetails: {builder: {id: $builder}, metadata: {invocationId: $run}}
  }' >"$RUNNER_TEMP/portaki-provenance.json"
cosign attest --yes --type slsaprovenance1 --predicate "$RUNNER_TEMP/portaki-provenance.json" "$subject"

if [ -n "${AUDIT_REPORT:-}" ] && [ -f "$AUDIT_REPORT" ]; then
  cosign attest --yes --type https://portaki.app/attestations/cargo-audit/v1 --predicate "$AUDIT_REPORT" "$subject"
  audited="attested"
else
  echo "::warning::no cargo audit report at ${AUDIT_REPORT:-(none)} — the registry will show this version as not audited."
  audited="none"
fi

echo "digest=${digest}" >>"$GITHUB_OUTPUT"
echo "image=${image}" >>"$GITHUB_OUTPUT"
echo "Signed ${subject} (provenance attested, audit: ${audited})."
