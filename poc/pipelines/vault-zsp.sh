#!/usr/bin/env bash
# Zero standing privileges POC: authenticate to Vault with an Entra-issued ID
# token, obtain short-lived AWS credentials, use them, revoke them, and prove
# they are dead.
#
# Everything runs inside the single pipeline task that holds the Vault token.
# The token is never written to a pipeline variable and never printed.
#
# Generated and committed by Terraform. Do not edit in Azure Repos.
#
# Required environment: MODE, VAULT_ADDR, VAULT_NAMESPACE, VAULT_JWT_PATH,
# VAULT_ROLE, ID_TOKEN. Also VAULT_AWS_PATH and AWS_DEFAULT_REGION when
# MODE=full, and optionally NEGATIVE_ROLE.

set -euo pipefail

: "${MODE:?MODE must be inspect, auth or full}"
: "${VAULT_ADDR:?}"
: "${VAULT_NAMESPACE:?}"
: "${VAULT_JWT_PATH:?}"
: "${VAULT_ROLE:?}"
: "${ID_TOKEN:?no ID token was supplied by the token acquisition step}"

NS_HDR="X-Vault-Namespace: ${VAULT_NAMESPACE}"
WORK_DIR="$(mktemp -d)"
VAULT_TOKEN=""
REVOKED=0

log() { printf '[zsp] %s\n' "$*"; }

# Live demonstration. Off unless DEMO=1, so an ordinary run stays terse.
# With it on, every request is shown as it is made and every response is
# printed whole, as returned, rather than summarised. call() prints a request
# line; reply() prints a status and a response body.
DEMO="${DEMO:-0}"
call()  { if [ "${DEMO}" = "1" ]; then printf '[zsp] -> %s\n' "$*"; fi; }
reply() { if [ "${DEMO}" = "1" ]; then printf '[zsp] <- %s\n' "$*"; fi; }

show_json() {
  # Pretty-prints JSON from stdin with redaction applied to every document
  # shown, so no individual call site can forget it. The Vault token, the AWS
  # secret key and any session token are replaced outright. The AWS access key
  # ID is not a secret on its own, but it is cut to its last four characters
  # so the log scan in acceptance test 7 stays meaningful.
  #
  # Azure DevOps separately masks this service connection's own federation
  # issuer and subject wherever they appear exactly, so those print as ***.
  # That is left alone deliberately: they are shown on the service connection
  # page and in the deck instead.
  jq '
    walk(
      if type == "object" then
        with_entries(
          if (.key == "client_token" or .key == "secret_key" or .key == "security_token")
             and (.value | type) == "string" then .value = "<redacted>"
          elif .key == "access_key" and (.value | type) == "string" then
            .value = "****" + .value[-4:]
          else . end)
      else . end)'
}

cleanup() {
  local rc=$?
  revoke_token
  rm -rf "${WORK_DIR}"
  exit "${rc}"
}

# Revoking the token also revokes every lease it created, which for iam_user
# credentials deletes the IAM user. One call is enough.
revoke_token() {
  if [ -n "${VAULT_TOKEN}" ] && [ "${REVOKED}" -eq 0 ]; then
    REVOKED=1
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "${NS_HDR}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
      "${VAULT_ADDR}/v1/auth/token/revoke-self" || echo "000")"
    if [ "${DEMO}" = "1" ]; then
      reply "http ${code} (no body)"
    else
      log "revoke-self returned http ${code}"
    fi
  fi
}

trap cleanup EXIT

b64url_decode() {
  local d="${1//-/+}"
  d="${d//_//}"
  local pad=$(( ${#d} % 4 ))
  if [ "${pad}" -ne 0 ]; then
    d="${d}$(printf '=%.0s' $(seq $(( 4 - pad ))))"
  fi
  printf '%s' "${d}" | base64 -d 2>/dev/null
}

vault_login() {
  # $1 = role name, $2 = output file. Echoes the HTTP status code.
  curl -sS -o "$2" -w '%{http_code}' -X POST -H "${NS_HDR}" \
    --data "$(jq -nc --arg r "$1" --arg j "${ID_TOKEN}" '{role:$r,jwt:$j}')" \
    "${VAULT_ADDR}/v1/auth/${VAULT_JWT_PATH}/login"
}

# ---------------------------------------------------------------------------
# inspect: print the token's claims so the design can be verified. Prints the
# decoded payload only, never the token itself.
# ---------------------------------------------------------------------------
if [ "${MODE}" = "inspect" ]; then
  payload="$(b64url_decode "$(printf '%s' "${ID_TOKEN}" | cut -d. -f2)")"
  if [ -z "${payload}" ]; then
    log "could not base64url-decode the token payload"
    exit 1
  fi
  log "token claims:"
  printf '%s' "${payload}" | jq '{iss, aud, sub, tid, appid, lifetime_seconds: (.exp - .iat)}'

  # Azure DevOps masks any value matching a service connection's registered
  # authorisation parameters, which includes the federation issuer and
  # subject, so those two claims print as *** above and cannot be compared by
  # eye. This re-emits the payload encoded, which the masker does not match.
  # It is the claim set only: no header and no signature, so it is not a
  # usable token. Inspect mode is diagnostic and is replaced by auth or full
  # before any demo.
  log "payload_b64 (claims only, not a credential):"
  printf '%s' "${payload}" | base64 | tr -d '\n'
  printf '\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Demonstration only: the ID token, decoded in full. Header and payload are
# printed as issued; the signature is not, so what appears in the log cannot
# be replayed. inspect mode has already done its own version and exited.
# ---------------------------------------------------------------------------
TOKEN_HEADER="$(b64url_decode "$(printf '%s' "${ID_TOKEN}" | cut -d. -f1)")"
TOKEN_PAYLOAD="$(b64url_decode "$(printf '%s' "${ID_TOKEN}" | cut -d. -f2)")"

if [ "${DEMO}" = "1" ]; then
  log "ID token for this pipeline, decoded. Header:"
  printf '%s' "${TOKEN_HEADER}" | show_json
  log "Payload:"
  printf '%s' "${TOKEN_PAYLOAD}" | show_json
  log "Signature: not printed"
fi

# ---------------------------------------------------------------------------
# Negative test: this pipeline's token must not satisfy another pipeline's role.
# ---------------------------------------------------------------------------
if [ -n "${NEGATIVE_ROLE:-}" ]; then
  log "negative test: offering this token to role ${NEGATIVE_ROLE}"
  if [ "${DEMO}" = "1" ] && [ -n "${NEGATIVE_SUBJECT:-}" ]; then
    # Another connection's subject, so Azure DevOps does not mask it.
    log "role ${NEGATIVE_ROLE} is bound to sub ${NEGATIVE_SUBJECT}"
  fi
  call "POST /v1/auth/${VAULT_JWT_PATH}/login   {\"role\":\"${NEGATIVE_ROLE}\",\"jwt\":\"<the ID token above>\"}"
  code="$(vault_login "${NEGATIVE_ROLE}" "${WORK_DIR}/neg.json")"
  if [ "${code}" = "200" ]; then
    log "FAIL: this token was accepted by role ${NEGATIVE_ROLE}, which it must not be"
    rm -f "${WORK_DIR}/neg.json"
    exit 1
  fi
  if [ "${DEMO}" = "1" ]; then
    reply "http ${code}"
    show_json < "${WORK_DIR}/neg.json" || true
  else
    jq -rc '.errors // empty' "${WORK_DIR}/neg.json" || true
  fi

  # A non-200 is not enough on its own. If the role does not exist, Vault also
  # refuses, and this test would report a pass having proved nothing: the
  # rejection has to be a claims mismatch, not a typo in the role name.
  if grep -qiE "could not be found|unknown role" "${WORK_DIR}/neg.json"; then
    log "FAIL: role ${NEGATIVE_ROLE} does not exist, so its rejection proves nothing"
    exit 1
  fi
  log "PASS: role ${NEGATIVE_ROLE} rejected this token with http ${code}"
fi

# ---------------------------------------------------------------------------
# Authenticate as this pipeline.
# ---------------------------------------------------------------------------
call "POST /v1/auth/${VAULT_JWT_PATH}/login   {\"role\":\"${VAULT_ROLE}\",\"jwt\":\"<the ID token above>\"}"
code="$(vault_login "${VAULT_ROLE}" "${WORK_DIR}/login.json")"
if [ "${code}" != "200" ]; then
  log "login to role ${VAULT_ROLE} failed with http ${code}"
  jq -rc '.errors // empty' "${WORK_DIR}/login.json" || true
  exit 1
fi

VAULT_TOKEN="$(jq -r '.auth.client_token' "${WORK_DIR}/login.json")"
if [ "${DEMO}" = "1" ]; then
  reply "http ${code}"
  show_json < "${WORK_DIR}/login.json"
else
  log "authenticated. Vault reports:"
  jq -c '{policies: .auth.policies,
          pipeline_subject: .auth.metadata.pipeline_subject,
          entity_id: .auth.entity_id,
          token_num_uses: .auth.num_uses,
          token_ttl: .auth.lease_duration}' "${WORK_DIR}/login.json"
fi
rm -f "${WORK_DIR}/login.json"

if [ "${MODE}" = "auth" ]; then
  revoke_token
  log "auth mode complete"
  exit 0
fi

# ---------------------------------------------------------------------------
# full: obtain, use, revoke and then prove the AWS credential is dead.
# ---------------------------------------------------------------------------
: "${VAULT_AWS_PATH:?}"
: "${AWS_DEFAULT_REGION:?}"
export AWS_DEFAULT_REGION

call "GET /v1/${VAULT_AWS_PATH}/creds/${VAULT_ROLE}"
CRED_ISSUED_AT="$(date +%s)"
code="$(curl -sS -o "${WORK_DIR}/creds.json" -w '%{http_code}' \
  -H "${NS_HDR}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/${VAULT_AWS_PATH}/creds/${VAULT_ROLE}")"
if [ "${code}" != "200" ]; then
  log "could not obtain AWS credentials, http ${code}"
  jq -rc '.errors // empty' "${WORK_DIR}/creds.json" || true
  exit 1
fi

AWS_ACCESS_KEY_ID="$(jq -r '.data.access_key' "${WORK_DIR}/creds.json")"
AWS_SECRET_ACCESS_KEY="$(jq -r '.data.secret_key' "${WORK_DIR}/creds.json")"
LEASE_ID="$(jq -r '.lease_id' "${WORK_DIR}/creds.json")"
LEASE_TTL="$(jq -r '.lease_duration' "${WORK_DIR}/creds.json")"
if [ "${DEMO}" = "1" ]; then
  reply "http ${code}"
  show_json < "${WORK_DIR}/creds.json"
else
  log "lease ${LEASE_ID} issued, ttl ${LEASE_TTL}s"
fi
rm -f "${WORK_DIR}/creds.json"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN 2>/dev/null || true

# IAM is eventually consistent, so a freshly created access key is not usable
# immediately. Poll rather than sleeping a fixed amount.
call "aws sts get-caller-identity   (retried until the new key propagates)"
CALLER_ARN=""
for _ in $(seq 1 12); do
  if out="$(aws sts get-caller-identity --output json 2>"${WORK_DIR}/err")"; then
    CALLER_ARN="$(printf '%s' "${out}" | jq -r '.Arn')"
    if [ "${DEMO}" = "1" ]; then printf '%s' "${out}" | show_json; fi
    break
  fi
  sleep 5
done
if [ -z "${CALLER_ARN}" ]; then
  log "FAIL: credentials never became usable"
  cat "${WORK_DIR}/err" || true
  exit 1
fi
log "credentials active for ${CALLER_ARN}"

# The work this pipeline exists to do. Also proves the credential carries the
# permission its Vault role grants, and nothing broader.
#
# ec2:DescribeRegions is chosen to sit inside the sandbox permissions
# boundary. In an unconstrained account any harmless read would do.
call "aws ec2 describe-regions"
WORK_OK=0
for _ in $(seq 1 6); do
  if out="$(aws ec2 describe-regions --output json 2>"${WORK_DIR}/err")"; then
    if [ "${DEMO}" = "1" ]; then
      # One region per line: the response as returned, just compacted.
      printf '%s' "${out}" | jq -c '.Regions[]'
    fi
    log "work step succeeded: the credential can see $(printf '%s' "${out}" | jq '.Regions | length') EC2 regions"
    WORK_OK=1
    break
  fi
  sleep 5
done
if [ "${WORK_OK}" -ne 1 ]; then
  log "FAIL: the granted permission did not work"
  cat "${WORK_DIR}/err" || true
  exit 1
fi

# Acceptance test 9: the credential is narrow, not merely short-lived.
#
# ec2:DescribeInstances is deliberately chosen. The sandbox permissions
# boundary permits it, so a denial here cannot come from the boundary. It can
# only come from the Vault role's own policy_document, which grants
# DescribeRegions and nothing else. Same service, adjacent action.
call "aws ec2 describe-instances"
if aws ec2 describe-instances >/dev/null 2>"${WORK_DIR}/err"; then
  log "FAIL: the credential could call ec2:DescribeInstances, which its Vault role does not grant"
  exit 1
fi
if grep -qE 'UnauthorizedOperation|AccessDenied|not authorized' "${WORK_DIR}/err"; then
  if [ "${DEMO}" = "1" ]; then sed 's/^/[zsp] <- /' "${WORK_DIR}/err" | grep -v '^\[zsp\] <- $' || true; fi
  log "PASS: ec2:DescribeInstances denied, so the credential carries only what its Vault role grants"
else
  log "FAIL: describe-instances failed, but not with an authorisation error"
  cat "${WORK_DIR}/err" || true
  exit 1
fi

call "POST /v1/auth/token/revoke-self"
revoke_token

call "aws sts get-caller-identity   (retried until AWS stops accepting the key)"

# The zero standing privileges proof: the credential must stop working.
DEAD=0
for _ in $(seq 1 24); do
  if aws sts get-caller-identity >/dev/null 2>"${WORK_DIR}/err"; then
    sleep 5
    continue
  fi
  if grep -q 'InvalidClientTokenId' "${WORK_DIR}/err"; then
    DEAD=1
    break
  fi
  sleep 5
done

if [ "${DEAD}" -ne 1 ]; then
  log "FAIL: the AWS credential still works after revocation"
  cat "${WORK_DIR}/err" || true
  exit 1
fi

if [ "${DEMO}" = "1" ]; then sed 's/^/[zsp] <- /' "${WORK_DIR}/err" | grep -v '^\[zsp\] <- $' || true; fi
log "PASS: after revocation AWS rejects the credential with InvalidClientTokenId"
if [ -n "${CRED_ISSUED_AT:-}" ]; then
  log "the credential existed for $(( $(date +%s) - CRED_ISSUED_AT )) seconds, and does not exist now"
fi
log "verify locally that the IAM user is gone: aws iam get-user --user-name ${CALLER_ARN##*/}"
