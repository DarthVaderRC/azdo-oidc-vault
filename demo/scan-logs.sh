#!/usr/bin/env bash
# Acceptance test 7, live: download a run's logs from Azure DevOps and search
# them for credential material. The same check the README records, run in
# front of the room instead of asserted on a slide.
#
#   ./scan-logs.sh            # the latest completed run of each zsp pipeline
#   ./scan-logs.sh 84 85      # specific build IDs
#
# Searches every log part of the run, not only the task that talks to Vault.
# Patterns, and what a match would mean:
#   hvs.                      a Vault service token
#   AKIA / ASIA + 16 chars    an AWS access key ID, long lived or session
#   eyJ + 20 chars            a raw JWT, which would be the ID token itself
#
# Uses the PAT and the project from ~/.zsp-poc.env. Read only.
# env-from-terraform.sh prints the project and prefix this build actually used.

set -uo pipefail

# shellcheck source=/dev/null
[ -f "${HOME}/.zsp-poc.env" ] && . "${HOME}/.zsp-poc.env"

: "${AZDO_ORG_SERVICE_URL:?source ~/.zsp-poc.env first}"
: "${AZDO_PERSONAL_ACCESS_TOKEN:?no PAT; source ~/.zsp-poc.env first}"
# Required rather than defaulted: someone else's project name produces a 404
# that reads like a permissions problem.
: "${AZDO_PROJECT:?not set. Run: eval \"\$(./env-from-terraform.sh)\"}"
PROJECT="${AZDO_PROJECT}"
API="${AZDO_ORG_SERVICE_URL%/}/${PROJECT}/_apis/build/builds"
PATTERN='hvs\.|A[KS]IA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}'

get() { curl -sSf -u ":${AZDO_PERSONAL_ACCESS_TOKEN}" "$1"; }

if [ "$#" -gt 0 ]; then
  builds=("$@")
else
  mapfile_compat() { while IFS= read -r l; do builds+=("$l"); done; }
  builds=()
  mapfile_compat < <(get "${API}?statusFilter=completed&queryOrder=finishTimeDescending&\$top=50&api-version=7.1" |
    jq -r --arg p "${NAME_PREFIX:-zsp}-" '[.value[] | select(.definition.name | startswith($p))]
           | group_by(.definition.name) | map(max_by(.id)) | .[].id')
fi

if [ "${#builds[@]}" -eq 0 ]; then
  echo "no completed ${NAME_PREFIX:-zsp}- pipeline runs found in project ${PROJECT}" >&2
  exit 1
fi

total_hits=0
for id in "${builds[@]}"; do
  name="$(get "${API}/${id}?api-version=7.1" | jq -r '"\(.definition.name) #\(.buildNumber)"')"
  parts=0; lines=0; hits=0
  for log_id in $(get "${API}/${id}/logs?api-version=7.1" | jq -r '.value[].id'); do
    text="$(get "${API}/${id}/logs/${log_id}?api-version=7.1")"
    parts=$((parts + 1))
    lines=$((lines + $(printf '%s\n' "${text}" | wc -l)))
    n="$(printf '%s\n' "${text}" | grep -cE "${PATTERN}")"
    if [ "${n}" -gt 0 ]; then
      # Show where, never what: the match itself would be the leak.
      printf '  build %s log %s: %s matching line(s)\n' "${id}" "${log_id}" "${n}"
      hits=$((hits + n))
    fi
  done
  printf 'build %-5s %-28s %3d log parts %6d lines   %d matches\n' "${id}" "${name}" "${parts}" "${lines}" "${hits}"
  total_hits=$((total_hits + hits))
done

echo
if [ "${total_hits}" -eq 0 ]; then
  echo "PASS: no Vault token, AWS key or raw JWT in any log"
else
  echo "FAIL: ${total_hits} line(s) contain credential material"
  exit 1
fi
