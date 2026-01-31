# Step 3: Azure DevOps Pipeline Integration

## 3.1 Understanding Azure DevOps JWT Token Flow with Entra ID

**Important**: Microsoft is sunsetting Azure DevOps OAuth. Use Entra ID OAuth instead.

### Custom Claims - Quick Answer ⚠️

**Can I add custom claims to the JWT token?**
- **With Managed Identity (Recommended)**: ❌ **NO** - Cannot add custom claims
  - Managed identity is auto-created by Azure DevOps
  - Limited to standard Entra ID claims: `iss`, `sub`, `oid`, `tid`, `aud`
  - **Workaround**: Use `sub` glob patterns in `bound_claims` for authorization
  
- **With App Registration (Advanced)**: ✅ **YES** - But requires higher permissions
  - Need Application Administrator role or higher
  - Requires Entra ID Premium P1/P2 for claims mapping policies
  - More complex setup - see Section 3.4.3 for details

**Recommendation**: Stick with managed identity + standard claims for this POC. Use glob patterns on `sub` for fine-grained control.

### Managed Identity Approach (No App Registration)

Azure DevOps service connections can use **managed identity** to get JWT tokens from **Entra ID**:

1. Create Azure DevOps service connection with **Workload Identity Federation**
2. Service connection uses **managed identity** (no app registration needed)
3. Pipeline gets **JWT token from Entra ID** (not Azure DevOps)
4. JWT token has Entra ID issuer: `https://login.microsoftonline.com/{tenant-id}/v2.0`
5. Vault validates JWT against Entra ID discovery endpoint

## 3.2 Azure DevOps Pipeline with Managed Identity

### Create Service Connection

1. In Azure DevOps: **Project Settings** → **Service Connections**
2. Click **New Service Connection**
3. Select **Azure Resource Manager**
4. Choose **Workload Identity federation (automatic)**
5. Select your subscription
6. Resource group: (select or leave empty)
7. Service connection name: `vault-managed-identity`
8. Grant access to all pipelines: ✓

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
  JWT_ROLE: 'dev-pipelines'

steps:
  - task: AzureCLI@2
    displayName: 'Get Entra ID JWT Token'
    inputs:
      azureSubscription: 'vault-managed-identity'  # Your service connection
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      addSpnToEnvironment: true
      inlineScript: |
        echo "Getting JWT token from Entra ID..."
        
        # Get JWT token - this is the token we'll use with Vault
        # Note: Using idToken (not accessToken) for OIDC federation
        JWT_TOKEN=$(az account get-access-token --resource api://AzureADTokenExchange --query accessToken -o tsv)
        
        # Alternatively, for federated identity:
        # JWT_TOKEN=$AZURE_FEDERATED_TOKEN
        
        echo "JWT token obtained (length: ${#JWT_TOKEN})"
        
        # OPTIONAL: Debug - Decode and inspect JWT claims
        echo "=== JWT Token Claims ==="
        echo "${JWT_TOKEN}" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.' || echo "Could not decode JWT"
        echo "========================"
        
        # Available standard claims from Entra ID:
        # - iss: https://login.microsoftonline.com/{tenant}/v2.0
        # - sub: Unique identifier (e.g., sc:{service-connection-id})
        # - aud: api://AzureADTokenExchange
        # - tid: Tenant ID (GUID)
        # - oid: Object ID of managed identity
        # No custom claims available with managed identity!
        
        # Export for next steps
        echo "##vso[task.setvariable variable=JWT_TOKEN;issecret=true]${JWT_TOKEN}"

  - task: Bash@3
    displayName: 'Authenticate to Vault using JWT'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      JWT_TOKEN: $(JWT_TOKEN)
      JWT_ROLE: $(JWT_ROLE)
    inputs:
      targetType: 'inline'
      script: |
        echo "Authenticating to Vault using JWT..."
        echo "Vault: ${VAULT_ADDR}"
        echo "Namespace: ${VAULT_NAMESPACE}"
        echo "Role: ${JWT_ROLE}"
        
        # Authenticate using JWT token via curl
        VAULT_TOKEN=$(curl --silent --request POST \
          --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          --data "{\"jwt\": \"${JWT_TOKEN}\", \"role\": \"${JWT_ROLE}\"}" \
          ${VAULT_ADDR}/v1/auth/jwt/login | jq -r '.auth.client_token')
        
        if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
          echo "Error: Failed to authenticate to Vault"
          exit 1
        fi
        
        echo "Successfully authenticated to Vault!"
        
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

Azure DevOps **does** provide access to JWT tokens through the `SYSTEM_ACCESSTOKEN` and service connections.

Create file: `scripts/vault-auth.sh`

```bash
#!/bin/bash
set -e

# Vault Configuration
VAULT_ADDR="${1}"
VAULT_NAMESPACE="${2}"
OIDC_ROLE="${3}"

echo "Authenticating to Vault using OIDC..."
echo "Vault Address: ${VAULT_ADDR}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo "Role: ${OIDC_ROLE}"

# For Azure DevOps, we need to use a JWT token
# The challenge: AZDO doesn't expose System.AccessToken as a JWT for external OIDC

# Solution: Use Azure AD Workload Identity Federation
# This requires an Azure AD app registration federated with AZDO

# We'll use the azure-cli to get a token
# First, install azure-cli if not present
if ! command -v az &> /dev/null; then
    echo "Installing Azure CLI..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

# Login using workload identity (requires service connection configured)
echo "Getting JWT token from Azure AD..."

# The JWT token will be provided via the pipeline's federated identity
# This is set up through Azure DevOps service connection

# For now, we'll use a placeholder approach
# In real implementation, you'd get the token from the service connection

JWT_TOKEN="${AZURE_OIDC_TOKEN}"

if [ -z "$JWT_TOKEN" ]; then
    echo "Error: No JWT token found"
    echo "Make sure AZURE_OIDC_TOKEN environment variable is set"
    exit 1
fi

# Authenticate to Vault using OIDC
echo "Authenticating to Vault..."

VAULT_TOKEN=$(vault write -field=token auth/oidc/login \
    role="${OIDC_ROLE}" \
    jwt="${JWT_TOKEN}")

if [ -z "$VAULT_TOKEN" ]; then
    echo "Error: Failed to get Vault token"
    exit 1
fi

echo "Successfully authenticated to Vault!"

# Export token for subsequent steps
echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]${VAULT_TOKEN}"

export VAULT_TOKEN
```

## 3.4 Practical Solution: Using Azure Service Connection

Since Azure DevOps OIDC tokens are primarily for Azure resources, the most practical approach is:

### Step 3.4.1: Create Azure AD App Registration

```bash
# Login to Azure
az login

# Create App Registration
APP_NAME="vault-azdo-oidc"
APP_ID=$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)

echo "App ID: ${APP_ID}"

# Create Service Principal
SP_ID=$(az ad sp create --id ${APP_ID} --query id -o tsv)

echo "Service Principal ID: ${SP_ID}"

# Get your Azure DevOps Organization ID
AZDO_ORG="your-org-name"
AZDO_ORG_URL="https://dev.azure.com/${AZDO_ORG}"

# Note: You'll need the organization ID from AZDO
# Get it from: https://dev.azure.com/{org}/_settings/organizationOverview
```

### Step 3.4.2: Configure Federated Identity Credential

```bash
# Create federated credential for AZDO
cat > federated-credential.json <<EOF
{
  "name": "azdo-vault-federation",
  "issuer": "https://vstoken.dev.azure.com/<YOUR_ORG_ID>",
  "subject": "sc://<ORG>/<PROJECT>/<SERVICE_CONNECTION_ID>",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
EOF

# Add federated credential
az ad app federated-credential create \
  --id ${APP_ID} \
  --parameters @federated-credential.json
```

### Step 3.4.3: Add Custom Claims (Optional)

If you need custom claims in JWT tokens (e.g., environment, team, project tags):

#### Option A: Optional Claims (Basic - Free)

```bash
# Add optional claims via Azure Portal or CLI
# Go to: Azure Portal → App Registrations → Your App → Token Configuration

# Add optional claims to ID token:
# - email
# - preferred_username  
# - groups (requires Directory.Read.All permission)

# Via Azure CLI - update app manifest
az ad app update --id ${APP_ID} --optional-claims '{
  "idToken": [
    {
      "name": "email",
      "essential": false
    },
    {
      "name": "preferred_username",
      "essential": false
    }
  ]
}'
```

#### Option B: Custom Extension Attributes (Advanced - Requires Premium P1/P2)

```bash
# 1. Create extension attribute in Entra ID
# Go to: Azure Portal → Enterprise Applications → Your App → Properties
# Add custom attributes to user/service principal

# 2. Add claims mapping policy (requires Premium)
# This allows you to inject custom claims like "environment", "team", etc.

cat > claims-mapping.json <<'EOF'
{
  "ClaimsMappingPolicy": {
    "Version": 1,
    "IncludeBasicClaimSet": "true",
    "ClaimsSchema": [
      {
        "Source": "user",
        "ID": "extensionattribute1",
        "JwtClaimType": "environment"
      },
      {
        "Source": "user",
        "ID": "extensionattribute2",
        "JwtClaimType": "team"
      }
    ]
  }
}
EOF

# Create the policy
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/policies/claimsMappingPolicies" \
  --body @claims-mapping.json \
  --headers "Content-Type=application/json"

# Get policy ID and assign to service principal
POLICY_ID="<policy-id-from-output>"
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/claimsMappingPolicies/\$ref" \
  --body "{\"@odata.id\":\"https://graph.microsoft.com/v1.0/policies/claimsMappingPolicies/${POLICY_ID}\"}"
```

#### Option C: Use Standard Claims with Tags (Simplest)

**Recommended Alternative**: Instead of custom claims, use what's already available:

```yaml
# In your pipeline, extract info from Azure DevOps variables
- script: |
    # Standard Azure DevOps variables you can use:
    echo "Project: $(System.TeamProject)"
    echo "Repo: $(Build.Repository.Name)"
    echo "Branch: $(Build.SourceBranchName)"
    echo "Build ID: $(Build.BuildId)"
    echo "Environment: $(Environment.Name)"  # For deployment jobs
    
    # These can be passed as metadata to Vault via API calls
    # Or used in your authorization logic
  displayName: 'Available Pipeline Variables'
```

**Note**: Since managed identity approach doesn't support custom claims, you have two options:
1. ✅ **Recommended**: Use `sub` glob patterns + standard claims for authorization
2. ⚠️ **Advanced**: Create app registration with custom claims (requires higher permissions)

## 3.5 Simpler Approach for POC: Direct JWT Method

For a quick POC, let's use a more direct approach:

### Create Azure Pipeline with Vault Integration

File: `azure-pipelines-vault.yml`

```yaml
trigger:
  branches:
    include:
      - main

pool:
  vmImage: 'ubuntu-latest'

variables:
  VAULT_ADDR: 'https://your-cluster.hashicorp.cloud:8200'
  VAULT_NAMESPACE: 'admin/azdo-poc'
  OIDC_ROLE: 'azdo-pipelines'

stages:
  - stage: Setup
    displayName: 'Setup and Install Vault'
    jobs:
      - job: InstallVault
        displayName: 'Install Vault CLI'
        steps:
          - task: Bash@3
            displayName: 'Install Vault'
            inputs:
              targetType: 'inline'
              script: |
                VAULT_VERSION="1.15.0"
                echo "Installing Vault ${VAULT_VERSION}..."
                
                curl -Lo vault.zip "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"
                unzip -o vault.zip
                sudo mv vault /usr/local/bin/
                rm vault.zip
                
                vault version

  - stage: AuthenticateVault
    displayName: 'Authenticate to Vault'
    dependsOn: Setup
    jobs:
      - job: VaultAuth
        displayName: 'Vault OIDC Authentication'
        steps:
          - task: AzureCLI@2
            displayName: 'Get Azure AD Token'
            inputs:
              azureSubscription: 'your-service-connection-name'
              scriptType: 'bash'
              scriptLocation: 'inlineScript'
              addSpnToEnvironment: true
              inlineScript: |
                echo "Getting Azure AD token..."
                
                # Get token for Vault audience
                TOKEN=$(az account get-access-token \
                  --resource ${APP_ID} \
                  --query accessToken -o tsv)
                
                echo "##vso[task.setvariable variable=AZURE_TOKEN;issecret=true]${TOKEN}"

          - task: Bash@3
            displayName: 'Authenticate to Vault'
            env:
              VAULT_ADDR: $(VAULT_ADDR)
              VAULT_NAMESPACE: $(VAULT_NAMESPACE)
              AZURE_TOKEN: $(AZURE_TOKEN)
            inputs:
              targetType: 'inline'
              script: |
                echo "Authenticating to Vault..."
                
                # Use the Azure AD token to authenticate to Vault
                VAULT_TOKEN=$(vault write -field=token auth/oidc/login \
                  role="${OIDC_ROLE}" \
                  jwt="${AZURE_TOKEN}")
                
                if [ -z "$VAULT_TOKEN" ]; then
                  echo "Error: Failed to authenticate to Vault"
                  exit 1
                fi
                
                echo "Successfully authenticated!"
                echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true;isOutput=true]${VAULT_TOKEN}"

  - stage: RetrieveSecrets
    displayName: 'Retrieve Secrets from Vault'
    dependsOn: AuthenticateVault
    jobs:
      - job: GetSecrets
        displayName: 'Fetch KV Secrets'
        variables:
          VAULT_TOKEN: $[ stageDependencies.AuthenticateVault.VaultAuth.outputs['VAULT_TOKEN'] ]
        steps:
          - task: Bash@3
            displayName: 'Read Dev Secrets'
            env:
              VAULT_ADDR: $(VAULT_ADDR)
              VAULT_NAMESPACE: $(VAULT_NAMESPACE)
              VAULT_TOKEN: $(VAULT_TOKEN)
            inputs:
              targetType: 'inline'
              script: |
                echo "Reading secrets from Vault..."
                
                # Read dev secrets
                vault kv get -format=json secret/dev/app-config | jq -r '.data.data'
                
                # Extract specific values
                DB_URL=$(vault kv get -field=database_url secret/dev/app-config)
                API_KEY=$(vault kv get -field=api_key secret/dev/app-config)
                
                echo "Database URL retrieved (not showing for security)"
                echo "API Key retrieved (not showing for security)"
                
                # Set as pipeline variables (masked)
                echo "##vso[task.setvariable variable=DATABASE_URL;issecret=true]${DB_URL}"
                echo "##vso[task.setvariable variable=API_KEY;issecret=true]${API_KEY}"

          - task: Bash@3
            displayName: 'Use Secrets in Application'
            env:
              DATABASE_URL: $(DATABASE_URL)
              API_KEY: $(API_KEY)
            inputs:
              targetType: 'inline'
              script: |
                echo "Using secrets in application..."
                echo "Database URL: ${DATABASE_URL:0:20}..." # Show only first 20 chars
                echo "API Key: ${API_KEY:0:10}..." # Show only first 10 chars
                
                # Your application deployment logic here
                echo "Application deployed successfully with secrets from Vault!"
```

## 3.6 Simplified POC Approach (Recommended to Start)

For initial POC validation, use Vault's JWT auth directly:

File: `azure-pipelines-simple.yml`

```yaml
trigger:
  branches:
    include:
      - main

pool:
  vmImage: 'ubuntu-latest'

variables:
  VAULT_ADDR: 'https://your-cluster.hashicorp.cloud:8200'
  VAULT_NAMESPACE: 'admin/azdo-poc'

steps:
  - task: Bash@3
    displayName: 'Install Vault CLI'
    inputs:
      targetType: 'inline'
      script: |
        # Install Vault
        VAULT_VERSION="1.15.0"
        curl -Lo vault.zip "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"
        unzip -o vault.zip
        sudo mv vault /usr/local/bin/
        vault version

  - task: Bash@3
    displayName: 'Authenticate to Vault with JWT'
    env:
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
    inputs:
      targetType: 'inline'
      script: |
        echo "Pipeline context:"
        echo "  Organization: $(System.TeamFoundationCollectionUri)"
        echo "  Project: $(System.TeamProject)"
        echo "  Repository: $(Build.Repository.Name)"
        echo "  Branch: $(Build.SourceBranch)"
        echo "  Pipeline: $(Build.DefinitionName)"
        
        # For this POC, we'll use a pre-generated token
        # In production, you'd use the Azure AD federated identity
        
        # Placeholder: Use Vault AppRole or pre-generated token for initial testing
        echo "For POC: Using pre-configured authentication"

  - task: Bash@3
    displayName: 'Retrieve Secrets from Vault'
    inputs:
      targetType: 'inline'
      script: |
        # For POC, authenticate with a limited-time token
        export VAULT_ADDR="$(VAULT_ADDR)"
        export VAULT_NAMESPACE="$(VAULT_NAMESPACE)"
        export VAULT_TOKEN="$(VAULT_POC_TOKEN)"  # Set this in pipeline variables
        
        # Retrieve secret
        vault kv get secret/dev/app-config
        
        # Use in application
        DB_URL=$(vault kv get -field=database_url secret/dev/app-config)
        echo "Retrieved database URL successfully"
```

## 3.7 Configure Pipeline Variables

In Azure DevOps:

1. Go to Pipelines → Select your pipeline → Edit → Variables
2. Add the following variables:
   - `VAULT_ADDR`: Your HCP Vault cluster URL
   - `VAULT_NAMESPACE`: `admin/azdo-poc`
   - `VAULT_POC_TOKEN`: A temporary token from Vault (for initial testing)
   - Mark `VAULT_POC_TOKEN` as **Secret**

Generate POC token in Vault:
```bash
vault token create -policy=azdo-secrets-reader -ttl=24h
```

## Next Steps

Proceed to [Step 4: Testing and Validation](STEP_4_TESTING.md)
