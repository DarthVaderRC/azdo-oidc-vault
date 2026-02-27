# Step 3: Azure DevOps Pipeline Integration

## 3.1 Understanding Access Token Flow with Managed Identity

**Important**: We use **access tokens** (not ID tokens) for authorization with managed identities.

### Why Access Tokens?

**Access tokens provide reliable managed identity claims:**
- ✅ `iss`: `https://sts.windows.net/{tenant}/` (correct issuer for access tokens)
- ✅ `aud`: `https://management.core.windows.net/` (Azure Resource Manager audience)
- ✅ `sub`: Managed Identity Principal ID (Object ID)
- ✅ `oid`: Same as `sub` - reliable identifier
- ✅ `appid`: Managed Identity Client ID
- ✅ `tid`: Tenant ID

**ID tokens don't work for managed identity authorization:**
- ❌ `oid` doesn't match managed identity's principal ID
- ❌ No `appid` claim to identify the managed identity
- ❌ `sub` claim changes for each service connection
- ❌ Generic audience (`api://AzureADTokenExchange`)

Per Microsoft's [access token documentation](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference), access tokens are designed for authorization decisions.

### Managed Identity Approach (No App Registration)

Azure DevOps service connections with **managed identity** enable JWT authentication:

1. Create Azure DevOps service connection with **Workload Identity Federation**
2. Service connection uses **managed identity** (no app registration needed)
3. Pipeline gets **access token via Azure CLI** (`az account get-access-token`)
4. Access token has issuer: `https://sts.windows.net/{tenant-id}/`
5. Vault validates JWT against Entra ID JWKS endpoint

## 3.2 Azure DevOps Pipeline with Managed Identity

### Create Service Connection

1. In Azure DevOps: **Project Settings** → **Service Connections**
2. Click **New Service Connection**
3. Select **Azure Resource Manager**
4. Choose **Managed Identity** (under Identity Type)
5. Select your subscription
6. Select resource group containing your managed identity
7. Select the managed identity name
8. Service connection name: `vault-managed-identity`
9. Grant access to all pipelines: ✓

**Note:** The managed identity must already exist in Azure. If you don't have one, create it first:
```bash
az identity create \
  --name "vault-dev-managed-identity" \
  --resource-group "your-resource-group"
```

### Pipeline Configuration

Create file: `azure-pipelines-vault.yml`

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
  JWT_ROLE: 'dev-mi-role'  # Match your Vault role name

steps:
  - task: AzureCLI@2
    displayName: 'Get Access Token from Azure CLI'
    inputs:
      azureSubscription: 'vault-managed-identity'  # Your service connection
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      inlineScript: |
        echo "Getting access token for managed identity..."
        
        # Get access token with Azure Resource Manager audience
        # This token contains managed identity claims (oid, appid, sub, tid)
        ACCESS_TOKEN=$(az account get-access-token \
          --resource https://management.core.windows.net/ \
          --query accessToken -o tsv)
        
        if [ -z "$ACCESS_TOKEN" ]; then
          echo "Error: Failed to get access token"
          exit 1
        fi
        
        echo "Access token obtained (length: ${#ACCESS_TOKEN})"
        
        # OPTIONAL: Debug - Decode and inspect access token claims
        echo "=== Access Token Claims ==="
        echo "${ACCESS_TOKEN}" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.' || echo "Could not decode token"
        echo "========================"
        
        # Access token contains:
        # - iss: https://sts.windows.net/{tenant}/
        # - aud: https://management.core.windows.net/
        # - sub: {managed-identity-principal-id}
        # - oid: {managed-identity-principal-id} (same as sub)
        # - appid: {managed-identity-client-id}
        # - tid: {tenant-id}
        
        # Export for next steps
        echo "##vso[task.setvariable variable=ACCESS_TOKEN;issecret=true]${ACCESS_TOKEN}"

  - task: Bash@3
    displayName: 'Authenticate to Vault using Access Token'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      ACCESS_TOKEN: $(ACCESS_TOKEN)
      JWT_ROLE: $(JWT_ROLE)
    inputs:
      targetType: 'inline'
      script: |
        echo "Authenticating to Vault using access token..."
        echo "Vault: ${VAULT_ADDR}"
        echo "Namespace: ${VAULT_NAMESPACE}"
        echo "Role: ${JWT_ROLE}"
        
        # Authenticate using access token via curl
        AUTH_RESPONSE=$(curl --silent --request POST \
          --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          --data "{\"jwt\": \"${ACCESS_TOKEN}\", \"role\": \"${JWT_ROLE}\"}" \
          ${VAULT_ADDR}/v1/auth/jwt/login)
        
        # Extract Vault token
        VAULT_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.auth.client_token')
        
        if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
          echo "Error: Failed to authenticate to Vault"
          echo "Response: $AUTH_RESPONSE"
          exit 1
        fi
        
        echo "Successfully authenticated to Vault!"
        
        # Display entity information (for client count verification)
        ENTITY_ID=$(echo "$AUTH_RESPONSE" | jq -r '.auth.entity_id')
        echo "Entity ID: ${ENTITY_ID}"
        echo "Entity Alias: Managed Identity Principal ID"
        
        # Display metadata (from claim_mappings)
        echo "Metadata:"
        echo "$AUTH_RESPONSE" | jq -r '.auth.metadata'
        
        # Export Vault token for next steps
        echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]${VAULT_TOKEN}"

  - task: Bash@3
    displayName: 'Retrieve Secrets from Vault'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      VAULT_TOKEN: $(VAULT_TOKEN)
    inputs:
      targetType: 'inline'
      script: |
        echo "Retrieving secrets from Vault..."
        
        # Read secrets using curl
        SECRET_DATA=$(curl --silent \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          ${VAULT_ADDR}/v1/secret/data/dev/app-config)
        
        # Extract values
        DATABASE_URL=$(echo "$SECRET_DATA" | jq -r '.data.data.database_url')
        API_KEY=$(echo "$SECRET_DATA" | jq -r '.data.data.api_key')
        ENVIRONMENT=$(echo "$SECRET_DATA" | jq -r '.data.data.environment')
        
        echo "Secrets retrieved:"
        echo "  Database URL: ${DATABASE_URL:0:30}..."
        echo "  Environment: ${ENVIRONMENT}"
        
        # Export as masked pipeline variables
        echo "##vso[task.setvariable variable=DATABASE_URL;issecret=true]${DATABASE_URL}"
        echo "##vso[task.setvariable variable=API_KEY;issecret=true]${API_KEY}"
        echo "##vso[task.setvariable variable=ENVIRONMENT;issecret=true]${ENVIRONMENT}"

  - task: Bash@3
    displayName: 'Deploy Application with Secrets'
    env:
      DATABASE_URL: $(DATABASE_URL)
      API_KEY: $(API_KEY)
      ENVIRONMENT: $(ENVIRONMENT)
    inputs:
      targetType: 'inline'
      script: |
        echo "Deploying application to ${ENVIRONMENT}..."
        echo "Database configured: ${DATABASE_URL:0:20}..."
        echo "API key configured (masked)"
        
        # Your deployment logic here
        echo "✓ Application deployed with secrets from Vault!"
```

## 3.3 Create Vault Authentication Script

For reusable authentication logic, create a helper script that uses curl (no Vault CLI needed):

Create file: `scripts/vault-auth.sh`

```bash
#!/bin/bash
set -e

# Vault Configuration
VAULT_ADDR="${1}"
VAULT_NAMESPACE="${2}"
JWT_ROLE="${3}"
ACCESS_TOKEN="${4}"

echo "Authenticating to Vault using access token..."
echo "Vault Address: ${VAULT_ADDR}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo "Role: ${JWT_ROLE}"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: No access token provided"
    echo "Usage: vault-auth.sh <vault-addr> <namespace> <role> <access-token>"
    exit 1
fi

# Authenticate to Vault using JWT auth with curl
AUTH_RESPONSE=$(curl --silent --request POST \
  --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  --data "{\"jwt\": \"${ACCESS_TOKEN}\", \"role\": \"${JWT_ROLE}\"}" \
  ${VAULT_ADDR}/v1/auth/jwt/login)

# Extract Vault token
VAULT_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.auth.client_token')

if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
    echo "Error: Failed to authenticate to Vault"
    echo "Response: $AUTH_RESPONSE"
    exit 1
fi

echo "Successfully authenticated to Vault!"

# Export token for subsequent steps
echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]${VAULT_TOKEN}"

export VAULT_TOKEN
```

## 3.4 Passing Pipeline Context to Vault

While access tokens don't contain pipeline-specific claims (like project name or branch), you can pass Azure DevOps built-in variables as custom headers in Vault API calls for audit logging:

```yaml
- task: Bash@3
  displayName: 'Authenticate with Pipeline Context'
  env:
    VAULT_ADDR: $(VAULT_ADDR)
    VAULT_NAMESPACE: $(VAULT_NAMESPACE)
    ACCESS_TOKEN: $(ACCESS_TOKEN)
  inputs:
    targetType: 'inline'
    script: |
      # Authenticate with JWT and include pipeline metadata
      curl --request POST \
        --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
        --header "X-Pipeline-ID: $(Build.BuildId)" \
        --header "X-Repository: $(Build.Repository.Name)" \
        --header "X-Branch: $(Build.SourceBranchName)" \
        --data "{
          \"jwt\": \"${ACCESS_TOKEN}\",
          \"role\": \"dev-mi-role\"
        }" \
        ${VAULT_ADDR}/v1/auth/jwt/login
      
      # These custom headers will appear in Vault audit logs!
```

**Result:** Vault audit logs will show:
- JWT token identity (managed identity's principal ID from `sub` claim)
- Custom headers with pipeline context
- Complete audit trail linking Vault access to specific pipeline runs

## 3.5 Configure Pipeline Variables

In Azure DevOps:

1. Go to Pipelines → Select your pipeline → Edit → Variables
2. Add the following variables:
   - `VAULT_ADDR`: Your HCP Vault cluster URL
   - `VAULT_NAMESPACE`: `admin` (or your namespace)
   - `JWT_ROLE`: `dev-mi-role`

No stored secrets needed — the access token is obtained automatically at runtime via the managed identity service connection.

## Next Steps

Proceed to [Step 4: Testing and Validation](STEP_4_TESTING.md)
