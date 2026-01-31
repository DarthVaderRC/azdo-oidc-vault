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
# Enable JWT auth method (NOT oidc - we're using JWT tokens from pipelines)
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "jwt"}' \
     ${VAULT_ADDR}/v1/sys/auth/jwt

# Configure JWT auth with Entra ID as issuer
# Note: Using Entra ID (not Azure DevOps OAuth which is being sunset)
AZURE_TENANT_ID="your-tenant-id"  # Get from Azure Portal

curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "$(cat <<EOF
{
  "oidc_discovery_url": "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0",
  "bound_issuer": "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0",
  "default_role": "azdo-pipelines"
}
EOF
)" \
     ${VAULT_ADDR}/v1/auth/jwt/config
```

**Note**: 
- Replace `${AZURE_TENANT_ID}` with your Azure tenant ID
- Using Entra ID OAuth (Microsoft is sunsetting Azure DevOps OAuth)
- No `oidc_client_id` needed for JWT validation

### 2.5.2 Understand Bound Claims Strategy

This is KEY to reducing client count!

**Important**: JWT tokens from Entra ID contain these **standard claims**:
- `iss`: Issuer (login.microsoftonline.com/{tenant}/v2.0)
- `sub`: Subject (unique identifier for the service principal/managed identity)
- `oid`: Object ID of the identity
- `tid`: Tenant ID
- `aud`: Audience (api://AzureADTokenExchange)

**Custom Claims** ⚠️:
- **With Managed Identity (Workload Identity Federation)**: ❌ Cannot add custom claims
  - The managed identity is auto-created by Azure DevOps
  - No direct access to app registration or token configuration
  - Limited to standard Entra ID claims listed above
  
- **With App Registration (Manual Setup)**: ✅ Can add custom claims
  - Requires Application Administrator or higher permissions
  - Need to create app registration with federated credentials
  - Can configure optional claims via Token Configuration blade
  - Can add custom claims via Claims Mapping Policy (requires Premium P1/P2)
  
**Recommendation**: 
- For this POC, use **managed identity** with standard claims only
- Use `sub` with glob patterns in `bound_claims` for authorization
- Use `user_claim="iss"` for entity consolidation
- If you need custom claims for production, see Alternative Approach in STEP_3

```bash
# Strategy 1: By Issuer (Simple - All pipelines in tenant)
# All pipelines in same tenant share an entity
bound_claims = {
  "iss": "https://login.microsoftonline.com/<tenant-id>/v2.0"
}

# Strategy 2: By Tenant + Additional Standard Claim
# Using standard claims available in all Entra tokens
bound_claims = {
  "iss": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "aud": "api://AzureADTokenExchange"  # Verify audience
}

# Strategy 3: Wildcard Issuer (Multiple Tenants)
# Use glob pattern for multiple tenants
bound_claims_type = "glob"
bound_claims = {
  "iss": "https://login.microsoftonline.com/*/v2.0"
}

# Strategy 4: By Object ID Pattern (Advanced)
# Group by object ID patterns if your managed identities follow naming convention
bound_claims = {
  "iss": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "oid": "*"  # Accept any object ID from this tenant
}

# Strategy 5: By Service Connection Pattern (Using sub with glob)
# If your service connection IDs follow a pattern
bound_claims_type = "glob"
bound_claims = {
  "sub": "sc:<service-connection-id>:*"  # Match specific service connection
}
# Example: "sub": "*/sc/862fd60f-3424-5f4d-b52b-ca8280f603a8/*"
# This authorizes all pipelines using this service connection
```

**CRITICAL for Client Count Reduction**:
- **`user_claim`** determines entity consolidation and licensing
- **`bound_claims`** only control authorization (which tokens can authenticate)
- **For consolidation**: Set `user_claim="iss"` or `user_claim="tid"` (NOT "sub"!)
- **For authorization**: Use `bound_claims` with glob patterns to match multiple pipelines

### 2.5.3 Create JWT Roles

#### Role 1: Dev Pipelines (All dev projects)

```bash
# Get your Azure tenant ID and subscription ID
AZURE_TENANT_ID="your-tenant-id"
AZURE_SUBSCRIPTION_ID="your-subscription-id"

# Create role using curl
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "$(cat <<EOF
{
  "role_type": "jwt",
  "bound_audiences": ["api://AzureADTokenExchange"],
  "user_claim": "iss",
  "token_ttl": 3600,
  "token_max_ttl": 14400,
  "token_policies": ["dev-secrets-reader"],
  "bound_claims": {
    "iss": "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"
  }
}
EOF
)" \
     ${VAULT_ADDR}/v1/auth/jwt/role/dev-pipelines
```

#### Role 2: Production Pipelines (Specific tenant)

```bash
# Get your tenant ID first
AZURE_TENANT_ID="your-tenant-id"

curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "$(cat <<EOF
{
  "role_type": "jwt",
  "bound_audiences": ["api://AzureADTokenExchange"],
  "user_claim": "iss",
  "token_ttl": 1800,
  "token_max_ttl": 3600,
  "token_policies": ["prod-secrets-reader"],
  "bound_claims": {
    "iss": "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"
  }
}
EOF
)" \
     ${VAULT_ADDR}/v1/auth/jwt/role/prod-pipelines
```

#### Role 3: Wildcard for POC (For testing multiple pipelines)

```bash
# Wildcard issuer for any tenant (use specific tenant ID in production)
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{
  "role_type": "jwt",
  "bound_audiences": ["api://AzureADTokenExchange"],
  "user_claim": "iss",
  "token_ttl": 3600,
  "token_max_ttl": 14400,
  "token_policies": ["azdo-secrets-reader"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "iss": "https://login.microsoftonline.com/*/v2.0"
  }
}' \
     ${VAULT_ADDR}/v1/auth/jwt/role/azdo-pipelines
```

#### Role 4: Specific Service Connection (Using sub with glob)

```bash
# Authorize only pipelines using a specific service connection
# Use this when you want fine-grained control per service connection
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{
  "role_type": "jwt",
  "bound_audiences": ["api://AzureADTokenExchange"],
  "user_claim": "iss",
  "token_ttl": 3600,
  "token_max_ttl": 14400,
  "token_policies": ["shared-secrets-reader"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "sub": "*/sc/862fd60f-3424-5f4d-b52b-ca8280f603a8/*"
  }
}' \
     ${VAULT_ADDR}/v1/auth/jwt/role/specific-service-connection

# Note: Replace 862fd60f-3424-5f4d-b52b-ca8280f603a8 with your service connection ID
# All pipelines using this service connection will:
# 1. Be authorized by matching the sub glob pattern
# 2. Share ONE entity because user_claim="iss" (same tenant issuer)
```

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
vault policy write prod-secrets-reader - <<EOF
# Allow reading prod secrets
path "secret/data/prod/*" {
  capabilities = ["read", "list"]
}

path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}

# Allow listing secrets
path "secret/metadata/prod/*" {
  capabilities = ["list"]
}
EOF
```

### Policy 3: General AZDO Reader (POC)

```bash
vault policy write azdo-secrets-reader - <<EOF
# Allow reading all secrets for POC
path "secret/data/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF
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
     ${VAULT_ADDR}/v1/auth/jwt/role/dev-pipelines | jq

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

### OIDC Approach (Shared Entities via Bound Claims)
```bash
# Multiple pipelines can share entities based on bound claims
Entity 1: azdo-dev-pipelines  → Shared by 100+ dev pipelines   → Client 1
Entity 2: azdo-prod-pipelines → Shared by 80+ prod pipelines   → Client 2
Entity 3: azdo-infra-pipelines→ Shared by 50+ infra pipelines  → Client 3
...
Total: ~10-20 entities instead of 400+
```

### How It Works

1. **First pipeline run**:
   ```
   Pipeline "app1-dev" → JWT with claims {project: "dev"} 
                      → Matches role "dev-pipelines"
                      → Creates Entity A with alias
                      → Client Count: 1
   ```

2. **Second pipeline run** (different pipeline, same project):
   ```
   Pipeline "app2-dev" → JWT with claims {project: "dev"}
                      → Matches same role "dev-pipelines"
                      → Uses existing Entity A (new alias)
                      → Client Count: Still 1
   ```

3. **Third pipeline run** (different project):
   ```
   Pipeline "app1-prod" → JWT with claims {project: "prod"}
                       → Matches role "prod-pipelines"
                       → Creates Entity B with alias
                       → Client Count: 2
   ```

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

echo "Configuring HCP Vault for Azure DevOps with Entra ID JWT..."

# Variables
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
export VAULT_TOKEN="hvs.your-admin-token"
export AZURE_TENANT_ID="your-tenant-id"  # Get from: az account show --query tenantId -o tsv

echo "Vault Address: ${VAULT_ADDR}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo "Azure Tenant ID: ${AZURE_TENANT_ID}"
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
       \"bound_issuer\": \"https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0\",
       \"default_role\": \"azdo-pipelines\"
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/config

# Create JWT role
echo "Creating JWT role..."
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"role_type\": \"jwt\",
       \"bound_audiences\": [\"api://AzureADTokenExchange\"],
       \"user_claim\": \"iss\",
       \"token_ttl\": 3600,
       \"token_policies\": [\"azdo-secrets-reader\"],
       \"bound_claims\": {
         \"iss\": \"https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0\"
       }
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/role/azdo-pipelines

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
echo "✓ JWT auth enabled with Entra ID issuer"
echo "✓ Discovery URL: https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"
```

## Next Steps

Proceed to [Step 3: Azure DevOps Pipeline Integration](STEP_3_PIPELINE_INTEGRATION.md)
