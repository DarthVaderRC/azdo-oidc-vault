# Common pitfalls

Symptoms, causes, and the reasoning. Ordered by how much time each one costs before you find it.

## 1. Every login fails with an audience mismatch

```
error validating token: invalid audience (aud) claim
```

The federated credential is configured with `api://AzureADTokenExchange`, and that is the value
everyone binds the Vault role to. The token that arrives carries something else:

```
aud = fb60f99c-7a34-4190-8149-302f77469936
```

That is the application ID of the Azure Token Exchange Endpoint. Same resource, two spellings, and an
Entra v2.0 token carries the app ID. It is a fixed Microsoft value, identical in every tenant.

Bind the GUID. The reason this one costs a day is that the error names the audience, so you go and
inspect the federated credential, where `api://AzureADTokenExchange` is sitting exactly as documented.

```bash
# What the role expects
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/role/pipeline-a" | jq -r '.data.bound_audiences[]'
```

## 2. The subject does not match

```
claim "sub" does not match any associated bound claim values
```

Usually one of four things:

- The subject was copied with a segment trimmed. It begins with `/eid1/` and there is no leading
  `https://`.
- The service connection was deleted and recreated. Its ID changed, so its subject changed, and both
  the federated credential and the Vault role need the new one.
- You bound the managed identity's principal ID, from the older access-token design. The identity does
  not appear in this subject at all.
- The connection is federating through the retiring Azure DevOps issuer, so the subject begins
  `https://vstoken.dev.azure.com/`. Recreate it, and check your organisation is connected to Entra.

Compare them directly rather than by eye:

```bash
# What the role expects
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/role/pipeline-a" | jq -r '.data.bound_claims.sub'

# What the token carries, from a pipeline task. Payload only: the signature is
# what makes a token usable, so it never goes in a log, and neither does
# $idToken itself.
echo "$idToken" | cut -d'.' -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.sub'
```

Azure DevOps masks this connection's own issuer and subject as `***` in its own build log. That is a
display filter, not redaction: Vault's audit record holds the full value.

## 3. `There is no explicit reference to service connection`

You are fetching the token from the OidcToken REST API, and the job never mentions the connection.
The set of connections a job may use is computed from task inputs when the job is **queued**, so a
task with `condition: false` still declares it and a variable holding its ID does not.

```yaml
- task: AzureCLI@2
  displayName: 'Declare the service connection (never runs)'
  condition: false
  inputs:
    azureSubscription: 'vault-pipeline-a'
    scriptType: bash
    scriptLocation: inlineScript
    inlineScript: 'true'
```

## 4. `The subscription of '...' doesn't exist in cloud 'AzureCloud'`

`AzureCLI@2` signs in and then runs `az account set`. A subscription the identity holds no role
assignment in does not appear in its account list at all, so selection fails. The sign-in itself
succeeded, which is why the error is confusing.

Either grant the identity Reader on the resource group holding it, which is the smallest grant that
satisfies the check, or switch to the REST method, which needs no Azure permission whatsoever.

## 5. The pipeline queues forever with no error

No parallel job in the organisation. New organisations often have none, Microsoft grants free
Microsoft-hosted parallelism on request, and the request takes days. Organisation settings, Parallel
jobs. Nothing in the pipeline log says this.

## 6. Authentication works, reading the secret does not

```
Error: 403 permission denied
```

The role authenticated, the policy did not permit the path. Check the actual path, not the one you
meant:

```bash
# KV v2 inserts /data/ into the API path but not the CLI path. A policy on
# secret/dev/* grants nothing to a read of secret/data/dev/...
path "secret/data/dev/app-config" {
  capabilities = ["read"]
}
```

Check the mount path too. A policy naming `aws/creds/...` grants nothing if the engine is mounted at
`aws-dev/`.

## 7. Revocation fails, and everything else worked

Two causes, both configuration rather than code:

- **`token_no_default_policy = true`**. `auth/token/revoke-self` is granted by the default policy.
  Removing it silently converts every credential into one that lives its full TTL.
- **`token_num_uses` exhausted.** Login does not consume a use; each subsequent request does, and the
  revoke is a request. One read plus one revoke needs `token_num_uses = 2`.

Both fail at the end of the job, where nobody is watching, and neither fails the build.

Also: `revoke-self` answers **204 with no body**. Piping it to `jq` and expecting JSON produces a
confusing error from a call that succeeded.

## 8. `AccessDenied` on `CreateUser`, reported by Vault

The AWS secrets engine is trying to create a dynamic IAM user, and your account will not let it. In a
constrained account this is almost always one of two settings:

- **`username_template`**, which belongs on the **mount**, not the role. Vault's default generates
  `vault-token-...` names, which an account that conditions `iam:CreateUser` on a name prefix denies.
  Keep the generated name within IAM's 64-character limit.
- **`permissions_boundary_arn`**, which belongs on the **role**. Some accounts deny `CreateUser`
  unless the new user carries an exact boundary.

## 9. Keeping the token out of the logs

The habits, in order of how much they matter:

**Do not promote the Vault token to a pipeline variable.**
`##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]` moves it from the task that earned it to
the whole job, readable by every later step. Keep the token, the credential and the work inside one
task. `isOutput=true` is worse: a secret crossing a job boundary is not masked in the job that
receives it.

**Do not echo a token to check it arrived.** `issecret=true` masks one exact string. Anything derived
from it, split, re-encoded, or concatenated, prints unmasked. To confirm a token works:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/auth/token/lookup-self"
```

**Do not print a response body on failure.** The login response contains `client_token`, and a failure
that reached your error branch for some reason other than a refused login still has one in it. Print
`.errors[]` instead.

**Printing the token's payload is fine, and useful.** `cut -d'.' -f2` is the claims; the signature is
what makes a token usable. Never print the whole token.

## 10. You cannot test any of this from your laptop

The token is minted for a service connection, by Azure DevOps, inside a job it has authorised.
`az account get-access-token` on your machine returns a token for *you*, with a different issuer,
audience and subject, and Vault will refuse it. There is no local equivalent, and time spent looking
for one is time lost.

Debug from a pipeline run, and read the result from Vault's audit log rather than the build log.

## Quick checks

```bash
# The mount validates the issuer you expect, and has no default_role
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/config" \
  | jq '{oidc_discovery_url:.data.oidc_discovery_url, bound_issuer:.data.bound_issuer, default_role:.data.default_role}'

# The role is pinned to one subject, with the GUID audience
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/role/pipeline-a" \
  | jq '{bound_audiences:.data.bound_audiences, sub:.data.bound_claims.sub, user_claim:.data.user_claim, token_num_uses:.data.token_num_uses, token_policies:.data.token_policies}'

# Nothing is left behind between runs
aws iam list-users --query "Users[?contains(UserName,'vault-')].UserName"
```

The Vault UI cannot display JWT roles on a mount, so the API is the only way to read one back.
