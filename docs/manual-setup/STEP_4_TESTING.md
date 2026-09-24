# Step 4: Testing

> These are the nine tests the tested build was measured against. Results from a live run are in [VALIDATION.md](../VALIDATION.md); this page is how to run them yourself.

The old version of this page measured whether Vault's client count went down. That is a licensing question, not a security one, and it told you nothing about whether the design worked. These nine do.

Four of them can fail while everything still looks healthy. Those are marked **silent**, and they are the reason to run this list rather than trusting a green pipeline.

## The list

| # | Test | How | Pass |
|---|---|---|---|
| 1 | The pipeline gets only its own policy | Audit log, `auth.policies` | `["default","pipeline-a"]`, nothing else |
| 2 | It obtains a working credential | Pipeline log | The credential does the work it was granted |
| 3 | **The credential dies with the run** | Below | `InvalidClientTokenId`, then `NoSuchEntity` |
| 4 | **One pipeline cannot use another's role** (silent) | Below | HTTP 400, `claim "sub" does not match` |
| 5 | Access is attributed to one pipeline | Audit log, `pipeline_subject` | Distinct per pipeline, matching the connection ID |
| 6 | Entity consolidation works as intended | `identity/entity/id` | One entity across many logins |
| 7 | **No credential reaches the logs** (silent) | Below | Zero matches |
| 8 | **No unneeded standing privilege** (silent) | Below | The role assignments you expect, and no others |
| 9 | **The credential cannot exceed its policy** (silent) | Below | A denied call alongside a permitted one |

## Test 3: the credential dies with the run

The one the whole design exists for. Two halves, and the second is the one people skip.

In the pipeline, after revoking:

```bash
aws sts get-caller-identity 2>&1 | grep -q 'InvalidClientTokenId' \
  && echo "PASS: AWS rejects the credential after revocation"
```

Then from your own machine, after the run has finished:

```bash
aws iam get-user --user-name <the user name from the log>
# An error occurred (NoSuchEntity) ... cannot be found.

aws iam list-users --query "Users[?contains(UserName,'vault-')].UserName"
# empty between runs
```

AWS is eventually consistent, so allow a few seconds and retry rather than concluding on the first answer. If the user still exists minutes later, revocation did not happen: check that the `EXIT` trap is installed before the first thing that can fail, that `token_no_default_policy` is false, and that `token_num_uses` left a use for the revoke.

## Test 4: one pipeline cannot use another's role

**Silent, and the most important test on this page.** If this fails, every other test still passes and you have per-pipeline roles that are not actually per-pipeline.

Add a step to pipeline B that offers its own token to pipeline A's role:

```bash
CODE=$(curl -sS -o /tmp/neg.json -w '%{http_code}' -X POST \
  -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -d "{\"role\":\"pipeline-a\",\"jwt\":\"${ID_TOKEN}\"}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/login")

# A rejection proves nothing if the role does not exist. Check the reason.
if grep -qiE 'could not be found|unknown role' /tmp/neg.json; then
  echo "FAIL: role pipeline-a does not exist, so its refusal proves nothing"
  exit 1
fi

if [ "${CODE}" = "400" ] && grep -q 'does not match' /tmp/neg.json; then
  echo "PASS: refused on a claims mismatch"
else
  echo "FAIL: got ${CODE}"; exit 1
fi
```

The guard matters more than the assertion. A misspelled role name also produces a non-200, so a test that accepts any failure reports PASS while proving nothing. Read the reason, not the status.

## Test 7: no credential reaches the logs

**Silent.** Nothing fails when a token is printed; you simply have a token in a log with a long retention period.

Download every log part of a run and search it. Counts only, never the matched text:

```bash
curl -sS -u ":${AZDO_PAT}" \
  "${ORG}/${PROJECT}/_apis/build/builds/${BUILD}/logs?api-version=7.0" \
  | jq -r '.value[].id' \
  | while read -r id; do
      curl -sS -u ":${AZDO_PAT}" \
        "${ORG}/${PROJECT}/_apis/build/builds/${BUILD}/logs/${id}?api-version=7.0"
    done \
  | grep -cE 'hvs\.|A[KS]IA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}'
```

Expect `0`. [`demo/scan-logs.sh`](../../demo/scan-logs.sh) does this across every pipeline's latest run.

Run it against your **most verbose** build, not a quiet one. A debug step added for an afternoon and removed is still in that run's logs, and those logs outlive the step.

## Test 8: no unneeded standing privilege

**Silent**, because standing privilege never causes a failure. That is the whole problem with it.

```bash
PRINCIPAL_ID=$(az identity show --name mi-vault-poc --resource-group rg-vault-poc \
  --query principalId -o tsv)

az role assignment list --assignee "${PRINCIPAL_ID}" --all -o table
```

Expect nothing at all if your pipelines fetch the token from the REST API, or exactly one Reader assignment scoped to the resource group holding the identity if they use `AzureCLI@2`. Anything else is a privilege nobody decided to grant, and you should be able to name the reason for the one that remains.

## Test 9: the credential cannot exceed its policy

**Silent**, because a credential that can do too much does everything you asked of it.

Have the pipeline attempt one call its Vault role does not grant, next to one it does:

```bash
aws ec2 describe-regions >/dev/null && echo "permitted call succeeded"

if aws ec2 describe-instances 2>&1 | grep -q 'UnauthorizedOperation'; then
  echo "PASS: denied what the policy does not grant"
else
  echo "FAIL: the credential can do more than its role allows"; exit 1
fi
```

Both halves are needed. A denial on its own could mean the credential is broken rather than scoped.

## Tests 1, 5 and 6: read the server's account, not the pipeline's

A pipeline log says what the pipeline believes. The audit log says what Vault did, and it is the record that matters in an incident.

```bash
# Per login: the policies granted, and which pipeline asked.
jq 'select(.type=="response" and (.request.path|endswith("/login")))
    | {policies: .auth.policies,
       sub: .auth.metadata.pipeline_subject,
       entity: .auth.entity_id}'
```

Check that policies hold exactly one pipeline policy plus `default`, that `pipeline_subject` ends in the right service connection ID, and, if you set `user_claim = "tid"`, that `entity_id` is identical across pipelines. Different policies, different attribution, same entity is the intended result, not a bug.

Note that Azure DevOps masks a connection's own issuer and subject as `***` in its own logs. That is a display filter on the build log. Vault's audit record has the full value, which is exactly why attribution should be read there.

## Before you call it done

Run tests 3, 4, 7, 8 and 9 once more after your **final** configuration change. Each is silent, and the most likely time to break one is while fixing something else.
