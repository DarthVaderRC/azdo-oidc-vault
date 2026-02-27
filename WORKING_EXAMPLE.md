## Complete Working Example

### Step 1: Create Service Connection

In Azure DevOps:
1. Project Settings Service Connections
2. New Service Connection Azure Resource Manager
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
       \"bound_issuer\": \"https://sts.windows.net/${AZURE_TENANT_ID}/\",
       \"default_role\": \"azdo-pipelines\"
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/config

# Create JWT role
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"role_type\": \"jwt\",
       \"bound_audiences\": [\"https://management.core.windows.net/\"],
       \"user_claim\": \"sub\",
       \"token_ttl\": 3600,
       \"token_policies\": [\"dev-secrets-reader\"],
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
        # Get access token from Entra ID (NOT Azure DevOps OAuth)
        JWT_TOKEN=$(az account get-access-token \
          --resource https://management.core.windows.net/ \
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
          --data "{\"jwt\": \"${JWT_TOKEN}\", \"role\": \"dev-mi-role\"}" \
          ${VAULT_ADDR}/v1/auth/jwt/login | jq -r '.auth.client_token')
        
        if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
          echo "Authentication failed"
          exit 1
        fi
        
        echo "Authenticated to Vault!"
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
        
        echo "Secrets retrieved!"
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
        echo "Deployed!"
```

---

## erification Checklist

After implementation, verify:

- [ ] `bound_issuer` set to `https://sts.windows.net/{tenant-id}/`
- [ ] `oidc_discovery_url` points to Entra ID (login.microsoftonline.com)
- [ ] No `oidc_client_id` in JWT auth config
- [ ] Service connection uses Workload Identity Federation (automatic)
- [ ] No app registration created (managed identity used)
- [ ] Pipeline gets access token from Entra ID via `az account get-access-token --resource https://management.core.windows.net/`
- [ ] All commands use curl (no vault binary)
- [ ] JWT authentication works (POST to /v1/auth/jwt/login)
- [ ] Multiple pipelines share same entity (check with curl to /v1/identity/entity/id)
- [ ] Client count reduced (check HCP Vault dashboard)

---


**Start with [STEP_1_AZURE_SETUP.md](STEP_1_AZURE_SETUP.md) for detailed implementation!**
