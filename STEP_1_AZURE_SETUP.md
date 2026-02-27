# Step 1: Azure DevOps Setup

## 1.1 Enable Workload Identity Federation in Azure DevOps

Azure DevOps supports Workload Identity Federation natively. We use **managed identity service connections** to obtain **access tokens** from Azure Entra ID. These access tokens contain claims about the managed identity (`sub`, `appid`, `tid`, `oid`) that Vault can validate via JWT auth.

**Key Concept**: Instead of using Azure DevOps OIDC ID tokens (which have generic audiences and unreliable claims for managed identities), we obtain **access tokens** via `az account get-access-token --resource https://management.core.windows.net/`. These access tokens:
- Are issued by `https://sts.windows.net/{tenant-id}/`
- Contain managed-identity-level claims suitable for authorisation
- Are validated by Vault against Entra ID's JWKS endpoint

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

## 1.5 Understand Access Token Acquisition

Azure DevOps provides access tokens through managed identity service connections:

### Azure DevOps Service Connection with Managed Identity

**The Correct Approach** (No app registration, no contributor limitation issues):

1. **Create Service Connection** in Azure DevOps with **Workload Identity Federation (automatic)**
2. Azure DevOps automatically creates a **managed identity** in your subscription
3. Pipeline uses `AzureCLI@2` task with the service connection
4. Task gets **access token from Entra ID** via `az account get-access-token --resource https://management.core.windows.net/`
5. This access token is used to authenticate to Vault via JWT auth

**Key Benefits**:
- ✅ No app registration needed (works with contributor permissions)
- ✅ Managed identity created automatically
- ✅ Access token from Entra ID contains reliable MI claims (`sub`, `appid`, `tid`)
- ✅ Token includes proper claims for Vault bound claims
- ✅ Microsoft-recommended approach

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

1. **Use Managed Identity** (No app registration needed - works with contributor permissions)
2. **Azure DevOps Service Connection** federates with Entra ID
3. **Access tokens issued by Entra ID** (issuer: `https://sts.windows.net/{tenant-id}/`)
4. **Vault validates Entra access tokens** via JWT auth method

**This approach**:
- ✅ No app registrations required (uses managed identity)
- ✅ Uses Entra OAuth (not deprecated Azure DevOps OAuth)
- ✅ Access tokens from pipeline via Azure CLI
- ✅ Works with contributor permissions
- ✅ Production-ready and Microsoft-recommended

## Next Steps

Proceed to [Step 2: HCP Vault Configuration](STEP_2_VAULT_SETUP.md)
