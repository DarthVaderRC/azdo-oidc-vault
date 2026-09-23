# Integrate Azure DevOps pipelines with Vault using Entra ID OIDC (Part 2) - Advanced config, Troublshooting and best practices

> **Corrected on 23 September 2026.** This article originally said that binding a Vault role to a
> specific service connection was not possible, and recommended one managed identity per environment
> as the finest grain available. That was wrong: the `sub` claim it quoted *is* the service
> connection. The sections below have been corrected against a tested build; see
> [DESIGN_REVIEW.md](../../DESIGN_REVIEW.md) for the measurements.

*Advanced configurations, troubleshooting and debugging tips, and security best practices for production hardening*

In part 1 you configured Vault JWT auth, created policies and roles, set up the Azure DevOps service connection, and verified secret retrieval from a pipeline. This document builds on that baseline with advanced environment configurations, practical troubleshooting and debugging workflows, and security hardening guidance for production-ready operations.

## Advanced configurations

### One role per pipeline

Bind each Vault role to the **subject of one service connection**. That subject is what Entra writes
into the token, and it names the connection rather than the managed identity behind it, so pipelines
sharing an identity remain distinguishable.

```bash
AZURE_TENANT_ID="your-tenant-id"

# Each connection's subject, exactly as the service connection page shows it.
SUB_A="/eid1/c/pub/t/<tenant>/a/<azdo-app>/sc/<organisation>/<connection-a-id>"
SUB_B="/eid1/c/pub/t/<tenant>/a/<azdo-app>/sc/<organisation>/<connection-b-id>"

vault write auth/jwt/role/pipeline-a \
    role_type="jwt" \
    policies="pipeline-a" \
    bound_audiences="fb60f99c-7a34-4190-8149-302f77469936" \
    bound_claims="sub=${SUB_A}" \
    user_claim="tid" \
    claim_mappings="sub=pipeline_subject" \
    token_ttl="5m" \
    token_num_uses=2

vault write auth/jwt/role/pipeline-b \
    role_type="jwt" \
    policies="pipeline-b" \
    bound_audiences="fb60f99c-7a34-4190-8149-302f77469936" \
    bound_claims="sub=${SUB_B}" \
    user_claim="tid" \
    claim_mappings="sub=pipeline_subject" \
    token_ttl="5m" \
    token_num_uses=2
```

Three choices in there are worth explaining.

**The audience is the application ID, not the URI.** The federated credential is configured with
`api://AzureADTokenExchange`, but an Entra v2.0 token carries `fb60f99c-7a34-4190-8149-302f77469936`,
the Azure Token Exchange Endpoint's app ID. Same resource, two spellings. It is a fixed Microsoft
value, identical in every tenant. Bind to the URI and every login is refused for an audience
mismatch, which sends you to inspect the federated credential rather than the token.

**`user_claim="tid"` puts every pipeline in one entity.** `user_claim` decides entity identity and
therefore client count; `bound_claims.sub` decides who may authenticate. They are separate knobs, and
conflating them is what produces roles that are deliberately too broad. Attribution does not suffer,
because `claim_mappings` records the full subject on every request.

**A five-minute token with two uses** is enough to read a secret and then revoke itself. Count the
calls: login does not consume a use, each read does, and revocation needs one.

### Environment isolation

Separate managed identities per environment still make sense, for blast radius in Azure rather than
for identity in Vault: a production identity that nothing else shares cannot be handed a federated
credential by someone with access to the development resource group. But the Vault role should still
bind the subject, not the identity, or every pipeline in that environment gets the same access.

```bash
vault write auth/jwt/role/prod-deploy \
    role_type="jwt" \
    policies="prod-secrets-reader" \
    bound_audiences="fb60f99c-7a34-4190-8149-302f77469936" \
    bound_claims="sub=${SUB_PROD_DEPLOY}" \
    user_claim="tid" \
    claim_mappings="sub=pipeline_subject" \
    token_ttl="5m" \
    token_num_uses=2
```

### Security boundaries

#### What the token can and cannot express

**Correction.** An earlier version of this document said binding to a specific service connection was
not possible, and recommended one managed identity per environment as the finest available grain. That
was wrong, and the evidence was already on the page: the `sub` claim shown above *is* the service
connection. Measured against a live tenant, two pipelines sharing one managed identity produce
different subjects, and a role bound to one of them refuses the other with HTTP 400.

**In the token, and therefore enforceable by Vault:**

- The **service connection**, via `sub`. One connection is one pipeline, provided you authorise
  pipelines to connections individually rather than checking "grant access to all pipelines".
- The **tenant**, via `tid`.
- The **issuer** and **audience**.

**Not in the token, at all:**

- Repository, branch, pipeline definition ID, run ID.
- The managed identity behind the connection. Its `/a/` segment is the Azure DevOps first-party
  application, the same value in every organisation.

So branch protection cannot come from Vault. It comes from Azure DevOps, on the connection itself:

- **Branch control check** on the service connection: the pipeline may use it only when running from
  an allowed branch, and optionally only when branch protection is enabled.
- **Required template check**: the pipeline must extend a template you control, which is how you
  guarantee a step you wrote runs before anything else.
- **Per-pipeline authorisation**: each pipeline is granted the connection explicitly.

Those checks are evaluated by Azure DevOps before the token is ever minted, so a run from the wrong
branch never reaches Vault. That is a different enforcement point from a bound claim, and worth
stating plainly to a security reviewer rather than implying Vault is checking the branch.

## Troubleshooting

### Common issues and solutions

#### Issue 1: "Permission denied" when authenticating

**Error message:**
```
Error: permission denied
```

**Causes and solutions:**

1. **JWT role not found**: Verify the role name matches
```bash
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     ${VAULT_ADDR}/v1/auth/jwt/role/azdo-pipelines | jq
```

2. **Bound claims don't match**: Check access token claims vs role configuration
```bash
# Decode access token in your pipeline
echo "${ACCESS_TOKEN}" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq
```

3. **Policy doesn't grant access**: Verify policy is attached to role
```bash
vault read auth/jwt/role/azdo-pipelines
vault policy read dev-secrets-reader
```

#### Issue 2: "Invalid token" or "Token validation failed"

**Error message:**
```
Error validating token: unable to validate token
```

**Solutions:**

1. **Check discovery URL configuration**
```bash
# Should be Entra ID endpoint
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     ${VAULT_ADDR}/v1/auth/jwt/config | jq '.data.oidc_discovery_url'

# Expected: https://login.microsoftonline.com/{tenant}/v2.0
```

2. **Verify the issuer**
```bash
vault read auth/jwt/config
# Expected: https://login.microsoftonline.com/{tenant}/v2.0
# If this says sts.windows.net, you are configured for the retiring
# access-token path. See STEP_1.
```

3. **Check the audience**
```bash
vault read auth/jwt/role/<role>
# The token's aud is the Azure Token Exchange Endpoint's application ID:
#   fb60f99c-7a34-4190-8149-302f77469936
# NOT api://AzureADTokenExchange, which is what the federated credential is
# configured with. Vault compares the literal string, and reports only an
# audience mismatch, which sends you to the wrong object.
```

4. **Check the subject**
```bash
vault read auth/jwt/role/<role>
# bound_claims.sub must equal the service connection's subject exactly, /eid1/
# prefix included. This is the most common cause by some distance, and the
# error says only that a claim did not match, not which one.
```

#### Issue 3: Service connection not working

**Error message:**
```
Failed to get access token
```

**Solutions:**

1. **Verify the service connection type**: Workload Identity Federation with a managed identity.
   Manual mode is easier to debug, because it shows you the issuer and subject it generated.

2. **Check that the pipeline is authorised to use the connection**: its Security page, not Azure
   RBAC. This is deliberate, and it is the authorisation boundary the whole design rests on.

3. **If you fetch the token from the REST API** rather than with `AzureCLI@2`, the job must reference
   the connection in some task input, even one that never runs, or the OidcToken endpoint refuses:
   *"There is no explicit reference to service connection ... from current stage."*

4. **If you use `AzureCLI@2`**, the identity needs a role assignment somewhere in the subscription, or
   `az account set` fails with *"The subscription of '...' doesn't exist in cloud 'AzureCloud'"*. Reader
   on the resource group holding the identity is enough.

#### Issue 4: Secrets not found

**Error message:**
```
Error: 404, path not found
```

**Solutions:**

1. **Check secret path**: Vault paths are case-sensitive
```bash
# List secrets to verify path
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --request LIST \
     ${VAULT_ADDR}/v1/secret/metadata/dev | jq
```

2. **Verify KV version**: KV v2 requires `/data/` in path
```bash
# KV v2 path format
/v1/secret/data/dev/app-config

# KV v1 path format (legacy)
/v1/secret/dev/app-config
```

3. **Check policy permissions**: Policy must grant read access
```bash
vault policy read dev-secrets-reader
```

### Debugging tips

#### Enable verbose logging in pipeline

Add this to your pipeline for debugging:

```yaml
- task: AzureCLI@2
  displayName: 'Debug access token'
  inputs:
    azureSubscription: 'azure-vault-connection'
    scriptType: bash
    addSpnToEnvironment: true
    inlineScript: |
      echo "=== Debugging the ID token ==="

      # addSpnToEnvironment exposes the ID token as idToken.
      # Print the payload only. The signature is what makes a token usable, so
      # it never goes in a log, and neither does $idToken itself.
      echo "$idToken" | cut -d'.' -f2 \
        | tr '_-' '/+' | base64 -d 2>/dev/null | jq '.'

      echo ""
      echo "Expected:"
      echo "- iss: https://login.microsoftonline.com/{tenant}/v2.0"
      echo "- aud: fb60f99c-7a34-4190-8149-302f77469936"
      echo "- sub: /eid1/c/pub/t/{tenant}/a/{azdo-app}/sc/{org}/{connection-id}"
      echo "- tid: {tenant}"
      echo ""
      echo "Azure DevOps masks the issuer and subject registered on THIS"
      echo "connection as *** in its own logs. That is a display filter."
      echo "Vault's audit log has the full value."
```

#### You cannot test this token from your laptop

Worth saying plainly, because it is the first thing everyone tries. The token is minted for a service
connection, by Azure DevOps, inside a job it has authorised. `az account get-access-token` on your
machine returns a token for *you*, with a different issuer, audience and subject, and Vault will
refuse it. There is no local equivalent.

Debug from a pipeline run instead, with the task above, and read the result from Vault's audit log
rather than from the build log.

```bash
# What the server saw, which is the account that matters
vault read sys/internal/counters/activity   # or your audit log destination
```

#### Check Vault audit logs

Enable audit logging to see detailed authentication attempts:

```bash
# Enable file audit device
vault audit enable file file_path=/vault/logs/audit.log

# View recent authentications
tail -f /vault/logs/audit.log | jq 'select(.type=="response" and .request.path=="auth/jwt/login")'
```

## Security best practices

### Token management

1. **Use short TTLs.** Minutes, not hours. The tested build uses `token_ttl=5m` with
   `token_num_uses=2`, which is enough to read a secret and then revoke.
2. **Revoke rather than renew.** Have the job call `auth/token/revoke-self` in an `EXIT` trap, so the
   credential dies with the job whether it succeeded or failed. Renewal keeps a credential alive; it
   is the opposite of what you want here. Leave the `default` policy attached, since that is what
   grants `revoke-self`.
3. **Mask secrets in logs**, with `issecret=true`. Understand its limit: it filters one exact string,
   so anything derived from the secret, split, re-encoded or concatenated, prints unmasked.

```yaml
# Good: Secret masked in logs
echo "##vso[task.setvariable variable=SECRET;issecret=true]${SECRET_VALUE}"

# Bad: Secret visible in logs
echo "##vso[task.setvariable variable=SECRET]${SECRET_VALUE}"
```

### Access control

1. **Principle of least privilege**: Grant minimum necessary permissions
2. **Separate policies per environment**: Dev, staging, prod should have different policies
3. **Bind the subject, not the identity.** This is the whole point: a role bound to the managed
   identity is a role every pipeline behind that identity can use.

```hcl
# Good: this role belongs to exactly one service connection
bound_audiences = ["fb60f99c-7a34-4190-8149-302f77469936"]
bound_claims    = { sub = "/eid1/c/pub/t/<tenant>/a/<azdo-app>/sc/<organisation>/<connection-id>" }
user_claim      = "tid"
claim_mappings  = { sub = "pipeline_subject" }

# Not acceptable: every workload in the tenant satisfies this, including
# virtual machines, function apps and other teams' pipelines
bound_claims = {
  tid = "<tenant>"
}
```

   Tenant-level validation was described as "acceptable" in an earlier version of this document. It is
   not. `tid` is identical in every token your tenant issues, so a role bound to `tid` alone is a
   tenant role wearing a pipeline's name.

4. **Do not set `default_role` on the mount.** A login that names no role gets it, and whatever it can
   reach, without ever having asked.

### Audit and monitoring

1. **Enable Vault audit logs**: Track all authentication and secret access
2. **Monitor failed authentications**: Alert on repeated failures
3. **Review access patterns**: Regularly audit which pipelines access which secrets

```bash
# Query audit logs for failed attempts
cat /vault/logs/audit.log | \
  jq 'select(.error != null and .request.path == "auth/jwt/login")' | \
  jq -r '[.time, .request.remote_address, .error] | @csv'
```

### Network security

1. **Use HTTPS only**: Never use unencrypted Vault connections
2. **Restrict network access**: Use Azure NSGs or firewall rules
3. **Consider private endpoints**: For production, use Azure Private Link

## Wrap up

You now have practical guidance to harden and operate this integration in production. Revisit part 1 anytime you need the foundational setup and end-to-end verification flow.

### Additional resources

- [HashiCorp Vault documentation](https://www.vaultproject.io/docs)
- [Vault JWT/OIDC auth method](https://www.vaultproject.io/docs/auth/jwt)
- [Azure workload identity federation](https://learn.microsoft.com/en-us/azure/active-directory/workload-identities/workload-identity-federation)
- [Azure DevOps service connections](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints)
- [HCP Vault](https://cloud.hashicorp.com/products/vault)
- [ID token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference)
- [Workload identity federation considerations](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-considerations)

