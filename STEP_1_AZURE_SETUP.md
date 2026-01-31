# Step 1: Azure DevOps Setup

## 1.1 Enable Workload Identity Federation in Azure DevOps

Azure DevOps supports OIDC federation natively. The key is that AZDO issues JWT tokens with claims that Vault can validate.

### AZDO OIDC Token Structure

Azure DevOps JWT tokens contain these important claims:
```json
{
  "sub": "sc://<org>/<project>/<service-connection-id>",
  "aud": "api://AzureADTokenExchange",
  "iss": "https://vstoken.dev.azure.com/<org-id>",
  "project": "<project-name>",
  "pipeline": "<pipeline-name>",
  "repository": "<repo-name>",
  "branch": "<branch-name>",
  "environment": "<environment-name>"
}
```

## 1.2 Create Azure DevOps Organization & Project

If you don't already have one:

1. Go to https://dev.azure.com
2. Create a new organization (or use existing)
3. Create a new project: `vault-oidc-poc`

## 1.3 Create Sample Repository

1. In your Azure DevOps project, create a new repository: `vault-integration-demo`
2. Clone it locally or use the web editor

## 1.4 Create Azure Pipeline (Initial)

Create a file: `azure-pipelines.yml`

```yaml
trigger:
  branches:
    include:
      - main

pool:
  vmImage: 'ubuntu-latest'

steps:
  - task: Bash@3
    displayName: 'Display OIDC Token Claims'
    inputs:
      targetType: 'inline'
      script: |
        echo "=== Azure DevOps OIDC Token Information ==="
        echo "System.TeamFoundationCollectionUri: $(System.TeamFoundationCollectionUri)"
        echo "System.TeamProject: $(System.TeamProject)"
        echo "Build.Repository.Name: $(Build.Repository.Name)"
        echo "Build.SourceBranch: $(Build.SourceBranch)"
        echo "Build.DefinitionName: $(Build.DefinitionName)"
        echo "System.JobId: $(System.JobId)"
        
        # The OIDC token will be accessed via service connection
        echo "Next: We'll configure Vault OIDC authentication"

  - task: Bash@3
    displayName: 'Test Step - Placeholder for Vault Integration'
    inputs:
      targetType: 'inline'
      script: |
        echo "This step will be replaced with Vault secret retrieval"
```

## 1.5 Understand AZDO OIDC Token Access

Azure DevOps provides OIDC tokens through:

### Azure DevOps Service Connection with Managed Identity

**The Correct Approach** (No app registration, no contributor limitation issues):

1. **Create Service Connection** in Azure DevOps with **Workload Identity Federation (automatic)**
2. Azure DevOps automatically creates a **managed identity** in your subscription
3. Pipeline uses `AzureCLI` task with the service connection
4. Task gets **JWT token from Entra ID** (issuer: `https://login.microsoftonline.com/{tenant}/v2.0`)
5. This JWT token is used to authenticate to Vault

**Key Benefits**:
- ✅ No app registration needed (works with contributor permissions)
- ✅ Managed identity created automatically
- ✅ JWT token from Entra ID (not deprecated Azure DevOps OAuth)
- ✅ Token includes proper claims for Vault bound claims
- ✅ Microsoft-recommended approach

### Recommended Approach: Manual Token Extraction

For POC purposes, we'll use a workaround that works with Vault:

1. Azure DevOps will generate a JWT token
2. We'll use the pipeline's identity claims
3. Vault will validate against AZDO's OIDC discovery endpoint

## 1.6 Get Your Azure Tenant Configuration Details

You'll need these values for Vault configuration:

```bash
# Get your Azure Tenant ID
# Method 1: From Azure Portal
# Go to Azure Active Directory → Properties → Tenant ID

# Method 2: Using Azure CLI
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Tenant ID: ${AZURE_TENANT_ID}"

# Entra ID OIDC Issuer (NOT Azure DevOps)
OIDC_ISSUER="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"

# Discovery URL (Entra ID)
OIDC_DISCOVERY_URL="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0/.well-known/openid-configuration"

echo "OIDC Issuer: ${OIDC_ISSUER}"
echo "Discovery URL: ${OIDC_DISCOVERY_URL}"
```

Verify the discovery URL:
```bash
curl "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0/.well-known/openid-configuration" | jq
```

Expected output:
```json
{
  "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "jwks_uri": "https://login.microsoftonline.com/<tenant-id>/discovery/v2.0/keys",
  "subject_types_supported": ["pairwise"],
  "response_types_supported": ["code", "id_token", "token"],
  "token_endpoint": "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token",
  ...
}
```

## 1.7 Understanding the Challenge

**Important Note**: Azure DevOps OIDC tokens are primarily designed for Azure resource access (e.g., deploying to Azure). For **generic OIDC** to external systems like Vault, we need to:

### Recommended Approach: Managed Identity with Entra OAuth

**Important**: Microsoft is sunsetting Azure DevOps OAuth in favor of Entra OAuth.

1. **Use Managed Identity** (No app registration needed - works with contributor permissions)
2. **Azure DevOps Service Connection** federates with Entra ID
3. **JWT tokens issued by Entra ID** (not Azure DevOps)
4. **Vault validates Entra JWT** tokens

**This approach**:
- ✅ No app registrations required (uses managed identity)
- ✅ Uses Entra OAuth (not deprecated Azure DevOps OAuth)
- ✅ JWT tokens from pipeline (not System.AccessToken)
- ✅ Works with contributor permissions
- ✅ Production-ready and Microsoft-recommended

## Next Steps

Proceed to [Step 2: HCP Vault Configuration](STEP_2_VAULT_SETUP.md)
