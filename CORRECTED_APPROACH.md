# Corrected Approach - Azure DevOps with Entra ID JWT Authentication

## \u26a0\ufe0f Critical Corrections Made

### 1. **Vault Configuration: JWT Auth (NOT OIDC with client_id)**

**WRONG** (Previous approach):
```bash
vault write auth/oidc/config \
  oidc_discovery_url="https://vstoken.dev.azure.com/<org-id>" \
  oidc_client_id="api://AzureADTokenExchange" \  # <- INCORRECT for JWT validation
  default_role="azdo-pipelines"
```

**CORRECT** (Current approach):
```bash
# Enable JWT auth method (not OIDC)
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "jwt"}' \
     ${VAULT_ADDR}/v1/sys/auth/jwt

# Configure with Entra ID discovery URL (no client_id needed)
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{
       "oidc_discovery_url": "https://login.microsoftonline.com/${TENANT_ID}/v2.0",
       "bound_issuer": "https://login.microsoftonline.com/${TENANT_ID}/v2.0",
       "default_role": "azdo-pipelines"
     }' \
     ${VAULT_ADDR}/v1/auth/jwt/config
```

**Why?**
- `oidc_client_id` is for **interactive OIDC login** (browser-based)
- We're doing **JWT token validation** from pipeline
- JWT auth validates tokens against `oidc_discovery_url` only
- No client secret, no interactive login, just JWT validation

---

### 2. **Use Managed Identity (No App Registration)**

**WRONG** (Previous approach):
```bash
# Requires app registration (needs higher permissions)
az ad app create --display-name "vault-azdo"
az ad sp create --id ${APP_ID}
```

**CORRECT** (Current approach):
```yaml
# In Azure DevOps Service Connection:
- Type: Azure Resource Manager
- Authentication: Workload Identity Federation (automatic)
- Managed identity is created automatically
- No app registration needed
- Works with contributor permissions
```

**Why?**
- User only has **contributor permissions** (cannot create app registrations)
- Managed identity is created automatically by Azure DevOps
- More secure and Microsoft-recommended approach

---

### 3. **Entra ID OAuth (Not Azure DevOps OAuth)**

**WRONG** (Previous approach - deprecated):
```yaml
# Azure DevOps OAuth (being sunset)
iss: "https://vstoken.dev.azure.com/<org-id>"
```

**CORRECT** (Current approach):
```yaml
# Entra ID OAuth (Microsoft-recommended)
iss: "https://login.microsoftonline.com/<tenant-id>/v2.0"
```

**Why?**
- Microsoft is **sunsetting Azure DevOps OAuth**
- Entra ID OAuth is the future
- Better integration with Azure ecosystem
- More secure and standardized

---

### 4. **JWT Tokens from Pipeline (Not System.AccessToken)**

**WRONG** (Previous approaches):
```yaml
# System.AccessToken - for Azure DevOps API only
SYSTEM_ACCESSTOKEN: $(System.AccessToken)

# AppRole - requires secret management
vault write auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}"
```

**CORRECT** (Current approach):
```yaml
# Get JWT token from Entra ID via managed identity
- task: AzureCLI@2
  inputs:
    azureSubscription: 'vault-managed-identity'
    scriptType: 'bash'
    addSpnToEnvironment: true
    inlineScript: |
      JWT_TOKEN=$(az account get-access-token \
        --resource api://AzureADTokenExchange \
        --query accessToken -o tsv)
```

**Why?**
- `System.AccessToken` is for Azure DevOps API, not external authentication
- AppRole requires managing secrets (defeats the purpose)
- Entra ID JWT tokens are the correct approach for federated identity

---

### 5. **Use curl Commands (No Vault CLI Binary)**

**WRONG** (Previous approach):
```bash
# Install Vault binary
curl -Lo vault.zip "https://releases.hashicorp.com/vault/1.15.0/vault_1.15.0_linux_amd64.zip"
unzip vault.zip
sudo mv vault /usr/local/bin/

# Use Vault CLI
vault auth enable jwt
vault write auth/jwt/config ...
vault kv get secret/path
```

**CORRECT** (Current approach):
```bash
# No binary installation needed - pure curl/REST API

# Enable JWT auth
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --request POST \
     --data '{"type": "jwt"}' \
     ${VAULT_ADDR}/v1/sys/auth/jwt

# Authenticate
curl --request POST \
     --data '{"jwt": "...", "role": "..."}' \
     ${VAULT_ADDR}/v1/auth/jwt/login

# Read secrets
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     ${VAULT_ADDR}/v1/secret/data/path
```

**Why?**
- No binary installation overhead in pipeline
- Faster pipeline execution
- More explicit and transparent
- Easier to debug

---

## \u2705 Correct Architecture Flow

```
1. Azure DevOps Pipeline
   \u2193
2. AzureCLI@2 Task with Managed Identity Service Connection
   \u2193
3. Get JWT Token from Entra ID
   - Issuer: login.microsoftonline.com/{tenant}/v2.0
   - Audience: api://AzureADTokenExchange
   - Claims: sub, oid, tid, etc.
   \u2193
4. Authenticate to Vault via curl
   - POST to /v1/auth/jwt/login
   - Send JWT token + role name
   - Receive Vault token
   \u2193
5. Vault Validates JWT
   - Checks issuer against oidc_discovery_url
   - Validates signature via JWKS endpoint
   - Matches bound_claims
   - Creates/updates entity (client count!)
   \u2193
6. Use Vault Token to Read Secrets
   - GET /v1/secret/data/{path}
   - curl with X-Vault-Token header
   \u2193
7. Deploy Application with Secrets
```

---

## \ud83d\udee0\ufe0f Complete Working Example

### Step 1: Create Service Connection

In Azure DevOps:
1. Project Settings \u2192 Service Connections
2. New Service Connection \u2192 Azure Resource Manager
3. Workload Identity Federation (automatic)
4. Select subscription
5. Name: `vault-managed-identity`

### Step 2: Configure Vault (Using curl)

```bash
# Set environment variables
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
export VAULT_TOKEN="hvs.your-admin-token"
export AZURE_TENANT_ID="your-tenant-id"

# Enable JWT auth
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "jwt"}' \
     ${VAULT_ADDR}/v1/sys/auth/jwt

# Configure JWT auth with Entra ID
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
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"role_type\": \"jwt\",
       \"bound_audiences\": [\"api://AzureADTokenExchange\"],
       \"user_claim\": \"sub\",
       \"token_ttl\": 3600,
       \"token_policies\": [\"dev-secrets-reader\"],
       \"bound_claims_type\": \"glob\",
       \"bound_claims\": {
         \"iss\": \"https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0\"
       }
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/role/dev-pipelines

# Create policy
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request PUT \
     --data '{
       "policy": "path \"secret/data/dev/*\" {\n  capabilities = [\"read\", \"list\"]\n}"
     }' \
     ${VAULT_ADDR}/v1/sys/policies/acl/dev-secrets-reader

# Enable KV engine
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"type": "kv-v2"}' \
     ${VAULT_ADDR}/v1/sys/mounts/secret

# Create test secret
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data '{"data": {"database_url": "postgresql://db:5432/app", "api_key": "secret-key-123"}}' \
     ${VAULT_ADDR}/v1/secret/data/dev/app-config
```

### Step 3: Create Pipeline

```yaml
trigger:
  branches:
    include:
      - main

pool:
  vmImage: 'ubuntu-latest'

variables:
  VAULT_ADDR: 'https://your-cluster.hashicorp.cloud:8200'
  VAULT_NAMESPACE: 'admin'

steps:
  - task: AzureCLI@2
    displayName: 'Get Entra JWT Token'
    inputs:
      azureSubscription: 'vault-managed-identity'
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      addSpnToEnvironment: true
      inlineScript: |
        # Get JWT from Entra ID (NOT Azure DevOps OAuth)
        JWT_TOKEN=$(az account get-access-token \
          --resource api://AzureADTokenExchange \
          --query accessToken -o tsv)
        
        echo "JWT obtained (length: ${#JWT_TOKEN})"
        echo "##vso[task.setvariable variable=JWT_TOKEN;issecret=true]${JWT_TOKEN}"

  - task: Bash@3
    displayName: 'Authenticate to Vault'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      JWT_TOKEN: $(JWT_TOKEN)
    inputs:
      targetType: 'inline'
      script: |
        # Authenticate using JWT (curl only, no vault binary)
        VAULT_TOKEN=$(curl --silent --request POST \
          --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          --data "{\"jwt\": \"${JWT_TOKEN}\", \"role\": \"dev-pipelines\"}" \
          ${VAULT_ADDR}/v1/auth/jwt/login | jq -r '.auth.client_token')
        
        if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
          echo "Authentication failed"
          exit 1
        fi
        
        echo "\u2713 Authenticated to Vault!"
        echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]${VAULT_TOKEN}"

  - task: Bash@3
    displayName: 'Get Secrets'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      VAULT_TOKEN: $(VAULT_TOKEN)
    inputs:
      targetType: 'inline'
      script: |
        # Read secrets using curl
        SECRET_DATA=$(curl --silent \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          ${VAULT_ADDR}/v1/secret/data/dev/app-config)
        
        DATABASE_URL=$(echo "$SECRET_DATA" | jq -r '.data.data.database_url')
        API_KEY=$(echo "$SECRET_DATA" | jq -r '.data.data.api_key')
        
        echo "\u2713 Secrets retrieved!"
        echo "##vso[task.setvariable variable=DATABASE_URL;issecret=true]${DATABASE_URL}"
        echo "##vso[task.setvariable variable=API_KEY;issecret=true]${API_KEY}"

  - task: Bash@3
    displayName: 'Deploy'
    env:
      DATABASE_URL: $(DATABASE_URL)
      API_KEY: $(API_KEY)
    inputs:
      targetType: 'inline'
      script: |
        echo "Deploying with secrets..."
        echo "Database: ${DATABASE_URL:0:20}..."
        echo "\u2713 Deployed!"
```

---

## \ud83d\udcca Client Count Reduction - How It Works

### With Correct JWT Auth + Bound Claims

```bash
# First pipeline run (Pipeline 1)
JWT: { "iss": "login.microsoftonline.com/tenant/v2.0", "sub": "pipeline-1", ... }
\u2192 Matches role "dev-pipelines" (bound_claims: iss matches)
\u2192 Creates Entity A with Alias 1
\u2192 Client Count: 1

# Second pipeline run (Pipeline 2) - SAME PROJECT/ENVIRONMENT
JWT: { "iss": "login.microsoftonline.com/tenant/v2.0", "sub": "pipeline-2", ... }
\u2192 Matches SAME role "dev-pipelines" (bound_claims: iss matches)
\u2192 Uses Entity A, creates Alias 2
\u2192 Client Count: STILL 1 (shared entity!)

# Multiple pipelines with same bound claims = ONE CLIENT
```

**This is why bound claims are critical for client reduction!**

---

## \u2705 Verification Checklist

After implementation, verify:

- [ ] Vault JWT auth enabled (not OIDC with client_id)
- [ ] `oidc_discovery_url` points to Entra ID (login.microsoftonline.com)
- [ ] No `oidc_client_id` in JWT auth config
- [ ] Service connection uses Workload Identity Federation (automatic)
- [ ] No app registration created (managed identity used)
- [ ] Pipeline gets JWT from Entra ID (not System.AccessToken)
- [ ] All commands use curl (no vault binary)
- [ ] JWT authentication works (POST to /v1/auth/jwt/login)
- [ ] Multiple pipelines share same entity (check with curl to /v1/identity/entity/id)
- [ ] Client count reduced (check HCP Vault dashboard)

---

## \ud83d\udcde Support

If you encounter issues:
1. Check JWT claims: `echo $JWT_TOKEN | cut -d'.' -f2 | base64 -d | jq`
2. Verify issuer matches Vault config
3. Check bound_claims match JWT claims
4. Review [COMMON_PITFALLS.md](COMMON_PITFALLS.md)

---

**This is the correct, production-ready approach that:**
- \u2705 Works with contributor permissions (managed identity)
- \u2705 Uses Entra ID OAuth (not deprecated Azure DevOps OAuth)
- \u2705 Uses JWT auth correctly (no oidc_client_id)
- \u2705 Uses curl only (no vault binary)
- \u2705 Gets JWT tokens from pipeline (not System.AccessToken)
- \u2705 Reduces client count via bound claims

**Start with [STEP_1_AZURE_SETUP.md](STEP_1_AZURE_SETUP.md) for detailed implementation!**
