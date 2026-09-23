# Step 3: The pipeline

> The tested version of everything below is [`pipelines/vault-zsp.sh`](../../pipelines/vault-zsp.sh)
> and [`pipelines/pipeline.yml.tftpl`](../../pipelines/pipeline.yml.tftpl). This page explains the
> shape so you can write your own, rather than restating a worse copy of it.

## 3.1 The shape

Five things happen, in this order, **inside one task**:

1. Get an ID token for this pipeline's service connection.
2. Exchange it for a Vault token by naming a role.
3. Get the secret or the dynamic credential.
4. Do the work.
5. Give the credential back.

Step 5 is the one that is usually missing, and it is the one that turns "short-lived" from a claim
into a fact. Everything else is plumbing.

**Inside one task** is not a stylistic preference. The moment you write the Vault token to a pipeline
variable, it stops belonging to the task that earned it and becomes readable by every later step in
the job. One task's privilege becomes the whole job's privilege, for the rest of the job.

## 3.2 Getting the ID token

Either method returns the same token. Step 1 covers the Azure permission each one costs.

**With `AzureCLI@2`.** `addSpnToEnvironment` exposes it as `idToken`:

```yaml
- task: AzureCLI@2
  displayName: 'Vault flow'
  inputs:
    azureSubscription: 'vault-pipeline-a'   # this pipeline's own connection
    scriptType: bash
    scriptLocation: inlineScript
    addSpnToEnvironment: true
    inlineScript: |
      export ID_TOKEN="$idToken"
      # ... the rest of this section ...
```

Note the task also runs `az login` and `az account set` before your script. That is where it fails if
the identity holds no role assignment, and the error names the subscription rather than the cause.

**With the OidcToken REST API.** No Azure permission at all:

```yaml
- task: AzureCLI@2
  displayName: 'Declare the service connection (never runs)'
  condition: false
  inputs:
    azureSubscription: 'vault-pipeline-a'
    scriptType: bash
    scriptLocation: inlineScript
    inlineScript: 'true'

- task: Bash@3
  displayName: 'Vault flow'
  env:
    SYSTEM_ACCESSTOKEN: $(System.AccessToken)
  inputs:
    targetType: inline
    script: |
      SC_ID='<the service connection id>'
      URL="$(System.CollectionUri)$(System.TeamProjectId)/_apis/distributedtask/hubs/build/plans/$(System.PlanId)/jobs/$(System.JobId)/oidctoken?serviceConnectionId=${SC_ID}&api-version=7.1-preview.1"

      ID_TOKEN=$(curl -sS -X POST -H "Authorization: Bearer ${SYSTEM_ACCESSTOKEN}" \
                   -H 'Content-Length: 0' "${URL}" | jq -r '.oidcToken // empty')

      if [ -z "${ID_TOKEN}" ]; then
        echo "the OidcToken API returned no token"
        exit 1
      fi
```

The task that never runs is not decoration. The set of connections a job may use is computed from
task inputs when the job is queued, so a task with `condition: false` still declares it. Without it:
*"There is no explicit reference to service connection ... from current stage."*

## 3.3 Authenticating to Vault

```bash
LOGIN=$(curl -sS -X POST \
  -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -d "{\"role\":\"${VAULT_ROLE}\",\"jwt\":\"${ID_TOKEN}\"}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/login")

VAULT_TOKEN=$(printf '%s' "${LOGIN}" | jq -r '.auth.client_token // empty')

if [ -z "${VAULT_TOKEN}" ]; then
  echo "Vault refused the login:"
  # The errors, not the body. A body that reached here because jq or the
  # response shape changed still contains a usable client_token.
  printf '%s' "${LOGIN}" | jq -r '.errors[]? // "no error detail returned"'
  exit 1
fi
```

Each pipeline names **its own role**. A pipeline that names a sibling's role is refused, because the
subject in its token does not match that role's `bound_subject`. That refusal is worth testing
deliberately, and Step 4 does.

## 3.4 Giving the credential back

Install the trap **immediately** after you have a token, before you do anything that can fail:

```bash
revoke() {
  [ -n "${VAULT_TOKEN}" ] || return 0
  curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
    "${VAULT_ADDR}/v1/auth/token/revoke-self"
  VAULT_TOKEN=""
}
trap revoke EXIT
```

`revoke-self` returns **204 with no body**. Do not pipe it to `jq` expecting JSON.

Revoking the Vault token also revokes every lease it created, so a dynamic AWS credential obtained
with it is destroyed at the same moment. Seconds later, AWS answers `InvalidClientTokenId` to anything
that tries to use it.

Three things make this reliable:

- **`trap ... EXIT`**, not a line at the end of the script, so it runs when the work fails too.
- **The `default` policy stays attached.** That is what grants `auth/token/revoke-self`. Setting
  `token_no_default_policy = true` takes revocation away and guarantees the credential lives its full
  TTL, which is the opposite of the intent.
- **A short TTL underneath it.** Revocation is the fast path, not the only one: if the agent is
  destroyed mid-job, the five-minute lease expires by itself.

## 3.5 Counting token uses

If you set `token_num_uses`, count carefully. Login does not consume a use; each subsequent request
does, and revocation is a request. Reading one secret and then revoking needs `token_num_uses=2`. Get
this wrong and the failure arrives at the revoke, which is exactly where you stop watching.

## 3.6 What not to do

| | Why |
|---|---|
| `##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]` | Promotes the token to job scope, readable by every later step, for the rest of the job |
| `isOutput=true` on it | A secret crossing a job boundary is not masked in the job that receives it |
| `echo "Token is: $(VAULT_TOKEN)"` | Use `auth/token/lookup-self` to confirm a token works. `issecret` masks one exact string, not anything derived from it |
| `echo "$ID_TOKEN"` | The payload is harmless and useful to print. The signature is what makes it usable, so print `cut -d'.' -f2` and never the whole token |
| Printing the login response body on error | It contains `client_token` whenever the failure was something other than a refused login |

## 3.7 The whole thing

```yaml
steps:
  - task: AzureCLI@2
    displayName: 'Vault flow'
    inputs:
      azureSubscription: 'vault-pipeline-a'
      scriptType: bash
      scriptLocation: inlineScript
      addSpnToEnvironment: true
      inlineScript: |
        set -euo pipefail

        VAULT_ADDR='https://your-cluster.hashicorp.cloud:8200'
        VAULT_NAMESPACE='admin/your-namespace'
        VAULT_ROLE='pipeline-a'
        VAULT_TOKEN=''

        revoke() {
          [ -n "${VAULT_TOKEN}" ] || return 0
          curl -sS -o /dev/null -X POST \
            -H "X-Vault-Token: ${VAULT_TOKEN}" \
            -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
            "${VAULT_ADDR}/v1/auth/token/revoke-self"
          VAULT_TOKEN=''
        }

        LOGIN=$(curl -sS -X POST -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          -d "{\"role\":\"${VAULT_ROLE}\",\"jwt\":\"${idToken}\"}" \
          "${VAULT_ADDR}/v1/auth/azdo-jwt/login")

        VAULT_TOKEN=$(printf '%s' "${LOGIN}" | jq -r '.auth.client_token // empty')
        [ -n "${VAULT_TOKEN}" ] || { printf '%s' "${LOGIN}" | jq -r '.errors[]?'; exit 1; }
        trap revoke EXIT

        SECRET=$(curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" \
          -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          "${VAULT_ADDR}/v1/secret/data/dev/app-config" | jq -r '.data.data.api_key')

        # ... use $SECRET here, in this task, without exporting it ...
```

For the version with dynamic AWS credentials, the negative test and the proof that revocation worked,
read [`pipelines/vault-zsp.sh`](../../pipelines/vault-zsp.sh). It is the script the acceptance tests
in [VALIDATION.md](../VALIDATION.md) were run against.

## Next steps

[Step 4: Testing](STEP_4_TESTING.md).
