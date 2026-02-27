# Step 2: HCP Vault Dedicated Configuration

## 2.1 Spin Up HCP Vault Cluster

1. Login to HCP Portal: https://portal.cloud.hashicorp.com
2. Navigate to Vault
3. Create a new cluster:
   - **Cluster name**: `azdo-oidc-poc`
   - **Tier**: Starter (or Plus for enterprise features)
   - **Region**: Choose closest to your Azure region
4. Wait for cluster to be ready (5-10 minutes)
5. Note down:
   - **Cluster URL**: `https://azdo-oidc-poc-vault-abc123.hashicorp.cloud:8200`
   - **Namespace**: `admin` (default)

## 2.2 Generate Admin Token

1. In HCP Portal, go to your Vault cluster
2. Click "Generate token"
3. Copy the token (you'll need it for CLI access)

```bash
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
export VAULT_TOKEN="hvs.your-admin-token"

# Test connection
vault status
```

## 2.3 Create Namespace for POC

Best practice: Use a dedicated namespace for each team/project

```bash
# Create namespace
vault namespace create azdo-poc

# Switch to the namespace
export VAULT_NAMESPACE="admin/azdo-poc"

# Verify
vault namespace list
```

## 2.4 Enable KV Secrets Engine

```bash
# Enable KV v2 secrets engine using curl
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "kv-v2"}' \
     ${VAULT_ADDR}/v1/sys/mounts/secret

# Create sample secrets for different environments
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"data": {"database_url": "postgresql://dev-db:5432/myapp", "api_key": "dev-api-key-12345", "environment": "development"}}' \
     ${VAULT_ADDR}/v1/secret/data/dev/app-config

curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"data": {"database_url": "postgresql://prod-db:5432/myapp", "api_key": "prod-api-key-67890", "environment": "production"}}' \
     ${VAULT_ADDR}/v1/secret/data/prod/app-config

# Verify secret creation
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/secret/data/dev/app-config | jq
```

## 2.5 Configure JWT Auth Method

### 2.5.1 Enable JWT Auth

```bash
# Enable JWT auth method (NOT oidc - we're using access tokens from Azure CLI)
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "jwt"}' \
     ${VAULT_ADDR}/v1/sys/auth/jwt

# Configure JWT auth with Entra ID as issuer
# Note: Access tokens use sts.windows.net as issuer, but JWKS from login.microsoftonline.com
AZURE_TENANT_ID="your-tenant-id"  # Get from Azure Portal

curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "$(cat <<EOF
{
  "oidc_discovery_url": "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0",
  "bound_issuer": "https://sts.windows.net/${AZURE_TENANT_ID}/",
  "default_role": "azdo-pipelines"
}
EOF
)" \
     ${VAULT_ADDR}/v1/auth/jwt/config
```

**Note**: 
- Replace `${AZURE_TENANT_ID}` with your Azure tenant ID
- **bound_issuer**: `sts.windows.net/{tenant}/` (access token issuer)
- **oidc_discovery_url**: `login.microsoftonline.com` (for JWKS validation)
- No `oidc_client_id` needed for JWT validation

### 2.5.2 Understand Access Token Claims and Authorization

This is KEY to reducing client count!

**Important**: Access tokens from `az account get-access-token` contain these **authorization claims**:
- `iss`: Issuer (`https://sts.windows.net/{tenant-id}/`)
- `aud`: Audience (`https://management.core.windows.net/`)
- `sub`: Managed Identity Principal ID (Object ID)
- `oid`: Same as `sub` - Managed Identity Principal ID
- `appid`: Managed Identity Client ID
- `tid`: Tenant ID

**Why Access Tokens (not ID tokens)?**
- ✅ **Reliable authorization claims**: `oid`, `appid`, `sub` all identify the managed identity
- ✅ **Microsoft-approved**: Designed for authorization decisions per [docs](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)
- ✅ **Managed-identity-level granularity**: Same as Azure auth method
- ❌ **ID tokens don't work**: `oid` doesn't match MI, no `appid` claim, `sub` changes per service connection

**Recommendation**: 
- Use **access tokens** via `az account get-access-token --resource https://management.core.windows.net/`
- Bind to specific managed identity using `sub` (principal ID), `appid` (client ID), and `tid` (tenant ID)
- Use `user_claim="sub"` for entity consolidation per managed identity

```bash
# Strategy 1: Bind to specific managed identity (RECOMMENDED)
# All pipelines/service connections using this MI share ONE entity
bound_claims = {
  "sub": "ghi13dg6-345b-4c27-4567-eab1208a5ef5",     # MI Principal ID
  "appid": "xyz456-w4-1234-9012-345678901234",   # MI Client ID
  "tid": "abc123-def4-5678-9012-345678901234"      # Tenant ID
}

# Strategy 2: Tenant-level (Less restrictive)
# All managed identities in this tenant can authenticate
bound_claims = {
  "tid": "abc123-def4-5678-9012-345678901234"      # Tenant ID only
}

# Strategy 3: Multiple managed identities with same policy (OR pattern)
# Create separate roles for different managed identities, attach same policy
# Role 1: dev-mi-role -> dev-managed-identity
# Role 2: staging-mi-role -> staging-managed-identity
# Both use same policy but different entities
```

**CRITICAL for controlling Vault Client Count**:
- **`user_claim`** determines entity consolidation and licensing
- **`bound_claims`** control authorization (which tokens can authenticate)
- **For managed identity consolidation**: Set `user_claim="sub"` (uses MI principal ID)
- **For authorization**: Use exact matches in `bound_claims` (no glob patterns needed)
- **Granularity**: Managed-identity-level (NOT service-connection or pipeline-level)

### 2.5.3 Create JWT Roles

#### Role 1: Dev Managed Identity

```bash
# Get managed identity details
DEV_MI_PRINCIPAL_ID="your-dev-mi-principal-id"      # Object ID
DEV_MI_CLIENT_ID="your-dev-mi-client-id"             # Client ID
AZURE_TENANT_ID="your-tenant-id"

# Create role using curl
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "$(cat <<EOF
{
  "role_type": "jwt",
  "bound_audiences": ["https://management.core.windows.net/"],
  "user_claim": "sub",
  "token_ttl": 3600,
  "token_max_ttl": 14400,
  "token_policies": ["dev-secrets-reader"],
  "bound_claims": {
    "sub": "${DEV_MI_PRINCIPAL_ID}",
    "appid": "${DEV_MI_CLIENT_ID}",
    "tid": "${AZURE_TENANT_ID}"
  },
  "claim_mappings": {
    "oid": "managed_identity_oid",
    "appid": "managed_identity_client_id",
    "tid": "tenant_id"
  }
}
EOF
)" \
     ${VAULT_ADDR}/v1/auth/jwt/role/dev-mi-role
```

**How to get managed identity values:**
```bash
# Option 1: Via Azure Portal
# Navigate to: Azure Active Directory > Managed Identities > [Your MI]
# - Object (principal) ID: shown on Overview
# - Application (client) ID: shown on Overview

# Option 2: Via Azure CLI
az identity show \
  --name "your-dev-managed-identity" \
  --resource-group "your-resource-group" \
  --query "{clientId: clientId, principalId: principalId}"
```

#### Role 2: Production Managed Identity

```bash
# Get production managed identity details
PROD_MI_PRINCIPAL_ID="your-prod-mi-principal-id"
PROD_MI_CLIENT_ID="your-prod-mi-client-id"
AZURE_TENANT_ID="your-tenant-id"

curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "$(cat <<EOF
{
  "role_type": "jwt",
  "bound_audiences": ["https://management.core.windows.net/"],
  "user_claim": "sub",
  "token_ttl": 1800,
  "token_max_ttl": 3600,
  "token_policies": ["prod-secrets-reader"],
  "bound_claims": {
    "sub": "${PROD_MI_PRINCIPAL_ID}",
    "appid": "${PROD_MI_CLIENT_ID}",
    "tid": "${AZURE_TENANT_ID}"
  },
  "claim_mappings": {
    "oid": "managed_identity_oid",
    "appid": "managed_identity_client_id",
    "tid": "tenant_id"
  }
}
EOF
)" \
     ${VAULT_ADDR}/v1/auth/jwt/role/prod-mi-role
```

#### Role 3: Tenant-Level (For POC/Testing)

```bash
# Less restrictive - allows any managed identity in tenant
# Use this for POC to test multiple managed identities easily
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "$(cat <<EOF
{
  "role_type": "jwt",
  "bound_audiences": ["https://management.core.windows.net/"],
  "user_claim": "sub",
  "token_ttl": 3600,
  "token_max_ttl": 14400,
  "token_policies": ["azdo-secrets-reader"],
  "bound_claims": {
    "tid": "${AZURE_TENANT_ID}"
  }
}
EOF
)" \
     ${VAULT_ADDR}/v1/auth/jwt/role/azdo-pipelines
```

**Understanding the role configuration:**
- `role_type: "jwt"` - Use JWT validation (not full OIDC flow)
- `bound_audiences` - Must match access token's `aud` claim
- `user_claim: "sub"` - Uses managed identity's principal ID for entity
- `bound_claims` - Validates specific managed identity claims:
  - `sub` - Managed identity's principal (object) ID
  - `appid` - Managed identity's client ID
  - `tid` - Azure tenant ID
- `claim_mappings` - Exports token claims as metadata for audit logging
- `ttl` - Vault tokens valid for specified duration

## 2.6 Create Policies

### Policy 1: Dev Secrets Reader

```bash
# Create policy using curl
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request PUT \
     --data "$(cat <<'EOF'
{
  "policy": "# Allow reading dev secrets\npath \"secret/data/dev/*\" {\n  capabilities = [\"read\", \"list\"]\n}\n\npath \"secret/data/shared/*\" {\n  capabilities = [\"read\", \"list\"]\n}\n\n# Allow listing secrets\npath \"secret/metadata/dev/*\" {\n  capabilities = [\"list\"]\n}"
}
EOF
)" \
     ${VAULT_ADDR}/v1/sys/policies/acl/dev-secrets-reader
```

### Policy 2: Prod Secrets Reader

```bash
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request PUT \
     --data "$(cat <<'EOF'
{
  "policy": "# Allow reading prod secrets\npath \"secret/data/prod/*\" {\n  capabilities = [\"read\", \"list\"]\n}\n\npath \"secret/data/shared/*\" {\n  capabilities = [\"read\", \"list\"]\n}\n\n# Allow listing secrets\npath \"secret/metadata/prod/*\" {\n  capabilities = [\"list\"]\n}"
}
EOF
)" \
     ${VAULT_ADDR}/v1/sys/policies/acl/prod-secrets-reader
```

### Policy 3: General AZDO Reader (POC)

```bash
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request PUT \
     --data "$(cat <<'EOF'
{
  "policy": "# Allow reading all secrets for POC\npath \"secret/data/*\" {\n  capabilities = [\"read\", \"list\"]\n}\n\npath \"secret/metadata/*\" {\n  capabilities = [\"list\"]\n}"
}
EOF
)" \
     ${VAULT_ADDR}/v1/sys/policies/acl/azdo-secrets-reader
```

## 2.7 Verify Configuration

```bash
# List auth methods
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/sys/auth | jq

# View JWT config
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/auth/jwt/config | jq

# Expected output should show:
# "oidc_discovery_url": "https://login.microsoftonline.com/<tenant-id>/v2.0"

# List JWT roles
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request LIST \
     ${VAULT_ADDR}/v1/auth/jwt/role | jq

# View specific role
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/auth/jwt/role/dev-mi-role | jq

# List policies
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request LIST \
     ${VAULT_ADDR}/v1/sys/policies/acl | jq

# Read policy
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/sys/policies/acl/dev-secrets-reader | jq
```

## 2.8 Understanding Client Count Impact

### Traditional Approach (Service Principals)
```bash
# Each service principal creates a unique entity
Entity 1: sp-app1-dev    → Client 1
Entity 2: sp-app1-prod   → Client 2
Entity 3: sp-app2-dev    → Client 3
...
Entity 400: sp-appN-prod → Client 400
```

### Access Token + Managed Identity Approach (Shared Entities)
```bash
# Multiple pipelines and service connections share entities per managed identity
Entity 1: dev-managed-identity  → Shared by 100+ pipelines using dev-mi   → Client 1
Entity 2: prod-managed-identity → Shared by 200+ pipelines using prod-mi  → Client 2
Entity 3: platform-mi          → Shared by 50+ pipelines using platform-mi → Client 3
Entity 4: staging-mi           → Shared by 50+ pipelines using staging-mi  → Client 4
...
Total: ~4-8 entities instead of 400+
Reduction: 98%
```

### How It Works

1. **First pipeline with dev-managed-identity**:
   ```
   Pipeline "app1-dev" → Access Token {sub: dev-mi-principal-id, appid: dev-mi-client-id} 
                      → Matches role "dev-mi-role"
                      → Creates Entity A with alias (oid-based)
                      → Client Count: 1
   ```

2. **Second pipeline with same managed identity** (different service connection):
   ```
   Pipeline "app2-dev" → Access Token {sub: dev-mi-principal-id, appid: dev-mi-client-id}
   (via different SC)  → Matches same role "dev-mi-role"
                      → Uses existing Entity A (new alias)
                      → Client Count: Still 1
   ```

3. **Third pipeline with different managed identity**:
   ```
   Pipeline "app1-prod" → Access Token {sub: prod-mi-principal-id, appid: prod-mi-client-id}
                       → Matches role "prod-mi-role"
                       → Creates Entity B with alias
                       → Client Count: 2
   ```

**Key Insight**: 
- Entity = Unique Managed Identity (not service connection or pipeline)
- Multiple service connections using same MI → Same entity
- Multiple pipelines using same MI → Same entity
- Granularity: **Managed-identity-level** (matches Azure auth method)

## 2.9 Enable Audit Logging (Optional but Recommended)

```bash
# Enable audit device
vault audit enable file file_path=/vault/logs/audit.log

# View audit logs to track client creation
vault audit list
```

## 2.10 Save Configuration Script

Create a script to replicate this setup:

```bash
#!/bin/bash
# save as: vault-setup.sh

set -e

echo "Configuring HCP Vault for Azure DevOps with Access Tokens..."

# Variables
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
export VAULT_TOKEN="hvs.your-admin-token"
export AZURE_TENANT_ID="your-tenant-id"  # Get from: az account show --query tenantId -o tsv
export DEV_MI_PRINCIPAL_ID="your-dev-mi-principal-id"
export DEV_MI_CLIENT_ID="your-dev-mi-client-id"

echo "Vault Address: ${VAULT_ADDR}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo "Azure Tenant ID: ${AZURE_TENANT_ID}"
echo "Dev MI Principal ID: ${DEV_MI_PRINCIPAL_ID}"
echo "Dev MI Client ID: ${DEV_MI_CLIENT_ID}"
echo ""

# Enable JWT auth
echo "Enabling JWT auth method..."
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "jwt"}' \
     ${VAULT_ADDR}/v1/sys/auth/jwt

# Configure JWT auth with Entra ID
echo "Configuring JWT auth with Entra ID..."
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"oidc_discovery_url\": \"https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0\",
       \"bound_issuer\": \"https://sts.windows.net/${AZURE_TENANT_ID}/\",
       \"default_role\": \"dev-mi-role\"
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/config

# Create JWT role with managed identity claims
echo "Creating JWT role for dev managed identity..."
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"role_type\": \"jwt\",
       \"bound_audiences\": [\"https://management.core.windows.net/\"],
       \"user_claim\": \"sub\",
       \"token_ttl\": 3600,
       \"token_policies\": [\"azdo-secrets-reader\"],
       \"bound_claims\": {
         \"sub\": \"${DEV_MI_PRINCIPAL_ID}\",
         \"appid\": \"${DEV_MI_CLIENT_ID}\",
         \"tid\": \"${AZURE_TENANT_ID}\"
       },
       \"claim_mappings\": {
         \"oid\": \"managed_identity_oid\",
         \"appid\": \"managed_identity_client_id\",
         \"tid\": \"tenant_id\"
       }
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/role/dev-mi-role

# Create policy
echo "Creating policy..."
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request PUT \
     --data '{
       "policy": "path \"secret/data/*\" {\n  capabilities = [\"read\", \"list\"]\n}"
     }' \
     ${VAULT_ADDR}/v1/sys/policies/acl/azdo-secrets-reader

# Enable KV engine
echo "Enabling KV secrets engine..."
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "kv-v2"}' \
     ${VAULT_ADDR}/v1/sys/mounts/secret

# Add test secret
echo "Creating test secret..."
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"data": {"database_url": "postgresql://dev-db:5432/myapp", "api_key": "dev-api-key-12345"}}' \
     ${VAULT_ADDR}/v1/secret/data/dev/app-config

echo ""
echo "✓ Vault configuration complete!"
echo "✓ JWT auth enabled with access token validation"
echo "✓ Issuer: https://sts.windows.net/${AZURE_TENANT_ID}/"
echo "✓ Discovery URL: https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"
echo "✓ Bound to managed identity: ${DEV_MI_PRINCIPAL_ID}"
```

## Next Steps

Proceed to [Step 3: Azure DevOps Pipeline Integration](STEP_3_PIPELINE_INTEGRATION.md)
