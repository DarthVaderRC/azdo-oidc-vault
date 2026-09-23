#!/usr/bin/env bash
# Watch dynamic IAM users appear and disappear, for a side terminal during the
# demo. This is the moment worth showing: the audience sees the credential
# come into existence and then cease to exist while the pipeline runs.
#
#   ./watch-iam.sh            # poll until interrupted
#   ./watch-iam.sh 300        # stop after 300 seconds
#
# Uses the presenter's own AWS credentials, not the pipeline's.

set -uo pipefail

# shellcheck source=/dev/null
[ -f "${HOME}/.zsp-poc.env" ] && . "${HOME}/.zsp-poc.env"

# The name prefix is whatever aws_user_prefix was set to, so it is not
# assumed here: matching on the suffix alone is correct in any account, and
# IAM_PREFIX narrows it on an account with unrelated users.
PREFIX="${IAM_PREFIX:-${AWS_USER_PREFIX:-}}"

# Not an environment value. Vault's dynamic users are named after the root
# user, which locals.tf:32 fixes as <aws_user_prefix>-vault-root.
MATCH="${IAM_MATCH:--vault-root-}"
INTERVAL="${INTERVAL:-2}"
DEADLINE=$(( $(date +%s) + ${1:-0} ))

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials are not working. Refresh them, then try again." >&2
  exit 1
fi

printf 'watching IAM for %s*%s, every %ss. ctrl-c to stop.\n\n' "${PREFIX}" "${MATCH}" "${INTERVAL}"

previous=""
while :; do
  current="$(aws iam list-users \
    --query "Users[?starts_with(UserName,'${PREFIX}') && contains(UserName,'${MATCH}')].UserName" \
    --output text 2>/dev/null | tr '\t' '\n' | sort | grep -v '^$' || true)"

  # comm needs sorted input on both sides; empty strings are valid here.
  while IFS= read -r u; do
    [ -n "$u" ] && printf '%s  \033[32m+ created \033[0m %s\n' "$(date +%H:%M:%S)" "$u"
  done < <(comm -13 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") 2>/dev/null)

  while IFS= read -r u; do
    [ -n "$u" ] && printf '%s  \033[31m- deleted \033[0m %s\n' "$(date +%H:%M:%S)" "$u"
  done < <(comm -23 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") 2>/dev/null)

  previous="$current"
  [ "${1:-0}" -gt 0 ] 2>/dev/null && [ "$(date +%s)" -ge "$DEADLINE" ] && break
  sleep "${INTERVAL}"
done

printf '\nno dynamic users remain: '
aws iam list-users --query "Users[?contains(UserName,'${MATCH}')].UserName" --output text 2>/dev/null \
  | grep -q . && echo "FALSE, some are still present" || echo "confirmed"
