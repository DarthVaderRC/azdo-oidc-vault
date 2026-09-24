# Step 2: Vault

> The tested version of everything here is [`terraform/vault.tf`](../../terraform/vault.tf). This page is the same configuration by hand, with the reasoning.

Everything uses `curl`, so no Vault binary is required. Set these first:

```bash
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_TOKEN="<an admin token>"
export VAULT_NAMESPACE="admin"
```

## 2.1 Cluster and namespace

Create an HCP Vault cluster, then a namespace of its own for this work. A namespace keeps the mounts, roles and policies below from colliding with anything else in the cluster.

```bash
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST "${VAULT_ADDR}/v1/sys/namespaces/vault-poc"

export VAULT_NAMESPACE="admin/vault-poc"
```

## 2.2 The JWT auth mount

```bash
AZURE_TENANT_ID="<your tenant id>"
ENTRA_ISSUER="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"

# Enable the mount. "jwt", not "oidc": there is no browser and no redirect.
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST -d '{"type":"jwt","description":"Azure DevOps pipelines"}' \
  "${VAULT_ADDR}/v1/sys/auth/azdo-jwt"

# Configure it.
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST -d "{
    \"oidc_discovery_url\": \"${ENTRA_ISSUER}\",
    \"bound_issuer\": \"${ENTRA_ISSUER}\"
  }" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/config"
```

Both values are the **same Entra issuer** the service connection showed you in Step 1. Vault fetches Entra's signing keys from the discovery URL and refuses any token whose `iss` is something else.

**Do not set `default_role`.** A login that names no role gets that role and its policies, so the role a caller ends up with stops being a decision anyone made. Every pipeline names its own role.

If your service connections do not all share one issuer, one mount cannot validate them all. Check before you go further.

## 2.3 One role per pipeline

This is the heart of it.

```bash
# Exactly as the service connection page showed it, /eid1/ prefix included.
SUB_A="/eid1/c/pub/t/<tenant>/a/<azdo-app>/sc/<organisation>/<connection-a-id>"

curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST -d "{
    \"role_type\": \"jwt\",
    \"bound_audiences\": [\"fb60f99c-7a34-4190-8149-302f77469936\"],
    \"bound_claims\": { \"sub\": \"${SUB_A}\" },
    \"user_claim\": \"tid\",
    \"claim_mappings\": { \"sub\": \"pipeline_subject\" },
    \"token_policies\": [\"pipeline-a\"],
    \"token_ttl\": \"5m\",
    \"token_max_ttl\": \"5m\",
    \"token_num_uses\": 2,
    \"token_no_default_policy\": false
  }" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/role/pipeline-a"
```

Repeat for each pipeline, with that pipeline's subject, policy and role name.

Six decisions in there, and every one of them is a place the earlier guidance went wrong.

**`bound_audiences` is a GUID.** The federated credential is configured with `api://AzureADTokenExchange`, and the token arrives carrying `fb60f99c-7a34-4190-8149-302f77469936`, the application ID of the Azure Token Exchange Endpoint. Same resource, two spellings, and an Entra v2.0 token carries the app ID. It is a fixed Microsoft value, identical in every tenant, so it is safe to write literally. Bind the documented URI instead and every login fails with an audience mismatch, which sends you to inspect the federated credential rather than the token.

**`bound_claims.sub` is the authorisation.** It pins the role to one service connection. Two pipelines behind the same managed identity have different subjects, so each gets its own role, and offering one pipeline's token to another's role is refused. `bound_subject` does the same job; `bound_claims` is used here because it extends naturally when you want to pin `tid` as well. Neither accepts a glob unless you also set `bound_claims_type`, and a glob here would need to pin the organisation segment to be safe at all.

**`user_claim` is not authorisation.** It decides which Vault entity the login resolves to, and therefore your client count. `tid` puts every pipeline in the tenant into one entity. That is a licensing choice and it costs nothing in attribution, because of the next line. Conflating `user_claim` with `bound_claims` is what produces roles that are deliberately too broad.

**`claim_mappings` is the attribution.** It writes the full subject into the token's metadata, so every audit record names the exact pipeline even though the entity is shared. This is the line that lets you consolidate entities without losing the ability to answer "which pipeline read that".

**`token_ttl` of five minutes**, not the hour the old guidance suggested. The token needs to live long enough to read one credential and hand it back.

**`token_num_uses: 2`.** Login does not consume a use. One read, one `revoke-self`. And `token_no_default_policy` stays **false**, because `auth/token/revoke-self` is granted by the default policy: turn it on and the pipeline cannot revoke anything, which guarantees the credential lives its full TTL.

## 2.4 One policy per pipeline

```bash
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X PUT -d '{
    "policy": "path \"aws/creds/pipeline-a\" {\n  capabilities = [\"read\"]\n}"
  }' \
  "${VAULT_ADDR}/v1/sys/policies/acl/pipeline-a"
```

One path, one capability. Note what is **not** here: `revoke-self` is not granted, because it comes from the default policy, and no KV path is granted, because this pipeline does not read KV.

If you are reading secrets from KV rather than minting AWS credentials, scope it the same way:

```hcl
path "secret/data/dev/pipeline-a/*" {
  capabilities = ["read"]
}

path "secret/metadata/dev/pipeline-a/*" {
  capabilities = ["list"]
}
```

Never `secret/data/*`. A policy that reads everything never fails, so nothing ever forces you to replace it, and it will still be attached in two years.

## 2.5 The AWS secrets engine

This is the part that makes "zero standing privileges" true rather than aspirational: the credential does not exist until the pipeline asks, and it is destroyed when the pipeline finishes.

```bash
# Enable the mount.
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST -d '{"type":"aws"}' "${VAULT_ADDR}/v1/sys/mounts/aws"

# Give it a root credential to create IAM users with, and a lease ceiling.
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST -d "{
    \"access_key\": \"${AWS_ACCESS_KEY_ID}\",
    \"secret_key\": \"${AWS_SECRET_ACCESS_KEY}\",
    \"region\": \"us-east-1\"
  }" \
  "${VAULT_ADDR}/v1/aws/config/root"

curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST -d '{"default_lease_ttl":"5m","max_lease_ttl":"5m"}' \
  "${VAULT_ADDR}/v1/sys/mounts/aws/tune"
```

Then a role per pipeline, granting only what that pipeline's work needs:

```bash
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  -X POST -d '{
    "credential_type": "iam_user",
    "policy_document": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ec2:DescribeRegions\"],\"Resource\":\"*\"}]}"
  }' \
  "${VAULT_ADDR}/v1/aws/roles/pipeline-a"
```

**`credential_type` must be `iam_user`.** It is the only type Vault can revoke before it expires. `assumed_role` and `federation_token` produce STS credentials that remain valid until their own expiry no matter what you do in Vault, so "the credential is dead the moment the job ends" would become "the credential is dead within the hour". If that claim matters to you, this setting is where it is won or lost.

Two more settings you may need, depending on how constrained your AWS account is:

- **`username_template`**, set on the **mount**, not the role. Vault's default produces names like `vault-token-...`, and an account whose IAM policy conditions `iam:CreateUser` on a name prefix will deny every one of them. Keep the generated name inside IAM's 64-character limit.
- **`permissions_boundary_arn`**, set on the **role**. Some accounts deny `iam:CreateUser` unless the new user carries an exact boundary policy.

Both produce the same symptom when missing: `AccessDenied` on `CreateUser`, from Vault, at the moment a pipeline asks for a credential.

## 2.6 Verify before you leave

```bash
# The mount validates the issuer you expect.
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/config" | jq '{oidc_discovery_url:.data.oidc_discovery_url, bound_issuer:.data.bound_issuer, default_role:.data.default_role}'

# The role is pinned to one subject, and its audience is the GUID.
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/auth/azdo-jwt/role/pipeline-a" | jq '{bound_audiences:.data.bound_audiences, bound_claims:.data.bound_claims, user_claim:.data.user_claim, token_ttl:.data.token_ttl, token_num_uses:.data.token_num_uses, token_policies:.data.token_policies}'
```

Check, in order: `default_role` is empty, `bound_audiences` is the GUID and not the URI, `bound_claims.sub` is this pipeline's subject and not the managed identity's ID, and `token_policies` names one policy.

Note that the Vault UI cannot display JWT roles on a mount. The CLI and the API are the only way to read one back, which is worth knowing before you go looking for a page that does not exist.

## Next steps

[Step 3: The pipeline](STEP_3_PIPELINE_INTEGRATION.md).
