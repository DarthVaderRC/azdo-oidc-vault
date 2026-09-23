#!/usr/bin/env bash
# Print Vault audit events from CloudWatch: time, path and policies on one
# line, and the full pipeline_subject on the line below it.
# This is the server's own record, not the pipeline's account of itself, which
# is what makes it evidence.
#
#   ./watch-audit.sh          # events from the last 15 minutes, then poll
#   ./watch-audit.sh 60       # look back 60 minutes first
#
# HCP batches its delivery, so expect a lag of a minute or two. Use this AFTER
# a run rather than watching it live during one.

set -uo pipefail

# shellcheck source=/dev/null
[ -f "${HOME}/.zsp-poc.env" ] && . "${HOME}/.zsp-poc.env"

LOOKBACK_MIN="${1:-15}"
INTERVAL="${INTERVAL:-15}"
REGION="${AWS_REGION:-us-east-1}"

GROUP="${AUDIT_LOG_GROUP:-$(aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix hashicorp \
  --query 'logGroups[0].logGroupName' --output text 2>/dev/null)}"

if [ -z "$GROUP" ] || [ "$GROUP" = "None" ]; then
  cat >&2 <<'MSG'
No HCP audit log group found.

If streaming was only just enabled, the group is created on the first
delivered batch, so wait a few minutes. If it never appears, the audit IAM
user is probably missing its hcp-org-id and hcp-project-id tags: the sandbox
boundary builds the permitted log group ARN out of those, so an untagged user
has every write denied while HCP still reports streaming as healthy.
MSG
  exit 1
fi

echo "log group: $GROUP"
echo "looking back ${LOOKBACK_MIN} minutes, then polling every ${INTERVAL}s. ctrl-c to stop."
echo

START=$(( ($(date +%s) - LOOKBACK_MIN * 60) * 1000 ))
seen="$(mktemp)"
trap 'rm -f "$seen"' EXIT

while :; do
  aws logs filter-log-events --region "$REGION" --log-group-name "$GROUP" \
    --start-time "$START" --output json 2>/dev/null \
  | jq -r '.events[]?.message' 2>/dev/null \
  | jq -rc --arg jwt "${VAULT_JWT_PATH:-azdo-jwt}" --arg aws "${VAULT_AWS_PATH:-aws}" \
      'select(.type=="response" and (.request.path|test("\($jwt)/login|\($aws)/creds|revoke-self")))
      | [ .time,
          .request.path,
          # A refused login creates no token, so it has no policies and no
          # subject. Vault records the error, HMAC-hashed, which is enough
          # to say it was refused but not why: that is in the pipeline log.
          (if (.response.auth.policies // .auth.policies) then ((.response.auth.policies // .auth.policies) | join(","))
           elif .response.data.error then "REFUSED"
           else "-" end),
          # In full: the whole subject is what the Vault role is bound to, and the
          # point of showing it is that nothing about it is abbreviated.
          (.response.auth.metadata.pipeline_subject // .auth.metadata.pipeline_subject // "-")
        ] | @tsv' 2>/dev/null \
  | sort \
  | while IFS=$'\t' read -r t path policies subject; do
      key="${t}${path}${subject}"
      if ! grep -qxF "$key" "$seen" 2>/dev/null; then
        echo "$key" >> "$seen"
        printf '%s  %-28s %s\n' "${t:11:8}" "$path" "$policies"
        if [ "$subject" != "-" ]; then printf '          sub %s\n' "$subject"; fi
      fi
    done
  sleep "${INTERVAL}"
done
