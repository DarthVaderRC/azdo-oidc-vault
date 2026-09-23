# Integrate Azure DevOps pipelines with Vault using Entra ID OIDC (Part 2) - Advanced config, Troublshooting and best practices

*Advanced configurations, troubleshooting and debugging tips, and security best practices for production hardening*

In [part 1](placeholder for medium blog), you configured Vault JWT auth, created policies and roles, set up the Azure DevOps service connection, and verified secret retrieval from a pipeline. This document builds on that baseline with advanced environment configurations, practical troubleshooting and debugging workflows, and security hardening guidance for production-ready operations.

## Advanced configurations

### Multiple managed identities for different environments

Create separate managed identities and Vault roles for different environments. This approach provides environment-level isolation using different managed identities for production and development pipelines.


```bash
# Get managed identity details for each environment
PROD_MI_CLIENT_ID="prod-managed-identity-client-id"
PROD_MI_PRINCIPAL_ID="prod-managed-identity-principal-id"

DEV_MI_CLIENT_ID="dev-managed-identity-client-id"
DEV_MI_PRINCIPAL_ID="dev-managed-identity-principal-id"

AZURE_TENANT_ID="your-tenant-id"

# Production role - stricter policies with shorter TTL
vault write auth/jwt/role/prod-pipelines \
    role_type="jwt" \
    policies="prod-secrets-reader" \
    bound_audiences="https://management.core.windows.net/" \
    user_claim="sub" \
    bound_claims="sub=${PROD_MI_PRINCIPAL_ID},appid=${PROD_MI_CLIENT_ID},tid=${AZURE_TENANT_ID}" \
    claim_mappings="oid=managed_identity_oid,appid=managed_identity_client_id,tid=tenant_id" \
    ttl="30m" \
    max_ttl="1h"

# Development role - longer TTL for convenience
vault write auth/jwt/role/dev-pipelines \
    role_type="jwt" \
    policies="dev-secrets-reader" \
    bound_audiences="https://management.core.windows.net/" \
    user_claim="sub" \
    bound_claims="sub=${DEV_MI_PRINCIPAL_ID},appid=${DEV_MI_CLIENT_ID},tid=${AZURE_TENANT_ID}" \
    claim_mappings="oid=managed_identity_oid,appid=managed_identity_client_id,tid=tenant_id" \
    ttl="1h"
```

### Security Boundaries

#### Understanding identity granularity

This integration provides **managed-identity-level authorization**, which matches the granularity of Azure's native auth method. It's important to understand what this means:

**What you get:**
- Identity tied to specific managed identity (via `oid`, `appid`, `sub` claims)
- Different managed identities can have different Vault access
- Reliable, consistent claims that don't change
- Microsoft-approved authorization claims
- Same granularity as Azure auth method

**What you don't get:**
- Pipeline-execution-level identity (no pipeline_id, repository, or branch in token)
- Per-repository or per-branch access control at the token level

**Why we used access tokens instead of ID tokens:**

We initially explored using ID tokens (from `addSpnToEnvironment: true`), which contain a structured `sub` claim:
```json
{
  "sub": "/eid1/c/pub/t/{tenant}/a/{azdo-app}/sc/{org-id}/{federated-credential-id}",
  "aud": "api://AzureADTokenExchange"
}
```

However, ID tokens have significant limitations. There are only a handful of claims that can be used for authentication and authorization but doesn't provide sufficient level of fine-grained controls. For example:
- The `oid` claim doesn't match the managed identity's principal ID
- The `sub` claim changes for each service connection (i.e.federated credential)
- No `appid` claim to bind to the managed identity's client ID
- The audience is generic (`api://AzureADTokenExchange`)

Access tokens, by contrast, provide reliable managed identity claims:
```json
{
  "aud": "https://management.core.windows.net/",
  "appid": "{managed-identity-client-id}",
  "oid": "{managed-identity-principal-id}",
  "sub": "{managed-identity-principal-id}"
}
```

These claims are explicitly designed for authorization decisions per Microsoft's [documentation](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference#payload-claims).

**Practical implications:**

```hcl
# POSSIBLE: Bind to specific managed identity
path "secret/data/prod/*" {
  capabilities = ["read"]
  # Only this managed identity can access
}

# POSSIBLE: Different managed identities for different environments
# prod-managed-identity -> prod secrets
# dev-managed-identity -> dev secrets

# NOT POSSIBLE: Bind to specific service connection
# Multiple service connections can use the same managed identity

# NOT POSSIBLE: Bind to specific repository or branch
# The token doesn't contain repository or branch information
```

**Recommendation:** For finer-grained access control:
1. Use different managed identities for different environments (dev, staging, prod)
2. Use Azure DevOps pipeline permissions to control which pipelines can use which service connections
3. Implement additional authorization in your application code
4. Combine with Azure RBAC for resource-level access control

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

2. **Verify bound issuer matches access token issuer**
```bash
# Access token issuer claim must match bound_issuer in config
vault read auth/jwt/config
# Expected bound_issuer: https://sts.windows.net/{tenant}/
```

3. **Check audience claim**
```bash
# Access token aud claim must match bound_audiences in role
# Should be: https://management.core.windows.net/
```

#### Issue 3: Service connection not working

**Error message:**
```
Failed to get access token
```

**Solutions:**

1. **Verify service connection type**: Must be "Workload Identity federation (automatic)"

2. **Check Azure permissions**: Need at least Contributor role

3. **Test connection in Azure DevOps**:
   - Go to service connection settings
   - Click "Verify" button
   - Check error messages

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
      echo "=== Debugging Access Token ==="
      
      # Get access token
      ACCESS_TOKEN=$(az account get-access-token \
        --resource https://management.core.windows.net/ \
        --query accessToken -o tsv)
      
      echo "Token length: ${#ACCESS_TOKEN}"
      echo ""
      echo "Decoded claims:"
      echo "${ACCESS_TOKEN}" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.'
      echo ""
      echo "Expected claims:"
      echo "- iss: https://sts.windows.net/{tenant}/"
      echo "- aud: https://management.core.windows.net/"
      echo "- appid: {managed-identity-client-id}"
      echo "- oid: {managed-identity-principal-id}"
      echo "- sub: {managed-identity-principal-id}"
```

#### Test authentication manually

You can test Vault authentication outside the pipeline using the access token:

```bash
# Get access token using Azure CLI
ACCESS_TOKEN=$(az account get-access-token \
  --resource https://management.core.windows.net/ \
  --query accessToken -o tsv)

# Test authentication
curl -X POST \
  -H "X-Vault-Namespace: admin" \
  -d "{\"jwt\": \"${ACCESS_TOKEN}\", \"role\": \"azdo-pipelines\"}" \
  https://your-vault.com:8200/v1/auth/jwt/login | jq
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

1. **Use short TTLs**: Set `token_ttl` to the minimum needed (30-60 minutes)
2. **Enable token renewal**: For long-running jobs, implement token renewal
3. **Mask secrets in logs**: Always use `issecret=true` when setting variables

```yaml
# Good: Secret masked in logs
echo "##vso[task.setvariable variable=SECRET;issecret=true]${SECRET_VALUE}"

# Bad: Secret visible in logs
echo "##vso[task.setvariable variable=SECRET]${SECRET_VALUE}"
```

### Access control

1. **Principle of least privilege**: Grant minimum necessary permissions
2. **Separate policies per environment**: Dev, staging, prod should have different policies
3. **Use appropriate claims for bound claims**: Restrict which service connections can use which roles

```hcl
# Good: Specific managed identity with all required claims
bound_audiences = ["https://management.core.windows.net/"]
bound_claims = {
  sub   = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"  # MI principal ID
  appid = "YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY"  # MI client ID
  tid   = "2ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ"  # Tenant ID
}

# Acceptable: Tenant-level validation only
bound_audiences = ["https://management.core.windows.net/"]
bound_claims = {
  tid = "2ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ"
}

# Best: Combine with bound_issuer for defense in depth
bound_issuer = "https://sts.windows.net/2ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ/"
bound_audiences = ["https://management.core.windows.net/"]
bound_claims = {
  sub   = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
  appid = "YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY"
}
```

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

You now have practical guidance to harden and operate this integration in production. Revisit [part 1](./medium-blog-v0.1.md) anytime you need the foundational setup and end-to-end verification flow.

### Additional resources

- [HashiCorp Vault documentation](https://www.vaultproject.io/docs)
- [Vault JWT/OIDC auth method](https://www.vaultproject.io/docs/auth/jwt)
- [Azure workload identity federation](https://learn.microsoft.com/en-us/azure/active-directory/workload-identities/workload-identity-federation)
- [Azure DevOps service connections](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints)
- [HCP Vault](https://cloud.hashicorp.com/products/vault)
- [Access tokens in Microsoft identity platform](https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens)
- [Access token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)

