Step 1: Create an Azure DevOps Project

This process is completed through the web portal.

1. Create an Azure DevOps Organization (If you don't have one)
	1. Navigate to the Azure DevOps website: https://azure.microsoft.com/en-us/services/devops/ and click "Start free" or go directly to https://dev.azure.com.
	2. Sign in using the Microsoft Account (MSA) associated with your Azure subscription or a work/school account (Microsoft Entra ID).
	3. You will be prompted to Create a new organization.
		○ Enter a unique URL for your organization (e.g., https://dev.azure.com/YourOrganizationName).
		○ Select the hosting location (closest to your region).
		○ Click Continue.

2. Create the New Project
Once you are inside your organization's home page:
	1. In the top-right corner, click the "New project" button.
	2. Fill in the project details in the form that appears:
		○ Project name: Choose a descriptive name for your POC, like Vault-OIDC-POC. (Avoid special characters.)
		○ Description (Optional): Add a short summary (e.g., "POC for HCP Vault OIDC integration with AZDO").
		○ Visibility: Set this to Private (recommended for production projects and the POC).
		○ Advanced:
			§ Version control: Choose Git (this is the standard and what we'll use for the pipeline code).
			§ Work item process: You can leave the default (Agile or Scrum) as it doesn't impact the pipeline integration, or select Basic for the simplest setup.
	3. Click "Create".
You now have a functional Azure DevOps project and are ready to move on to the next phase: configuring the trust relationship between this project and your HCP Vault cluster.


Step 2: Create a Service Connection with Workload Identity Federation (WIF)

This service connection is what your pipeline will use to signal its identity to Azure, which in turn gives it the credentials (a JWT) to talk to Vault. Since your goal is to reduce client count, this service connection will represent the general identity that all your federated pipelines will use.
	1. In your Azure DevOps project, navigate to Project settings (bottom left).
	2. Under the "Pipelines" section, click Service connections.
	3. Click New service connection.
	4. Select Azure Resource Manager and click Next.
	5. Select Workload Identity Federation (automatic) and click Next.
	6. Configure the connection details:
		○ Scope level: Select Subscription.
		○ Subscription: Choose the Azure subscription you have access to.
		○ Resource group: You can select a resource group, or leave it blank if you want the SP to have subscription-wide access (though you should narrow this down later).
		○ Service connection name: Enter a descriptive name, like Vault-OIDC-Federation-SP.
	7. Ensure the "Grant access permissions to all pipelines" box is checked for the POC simplicity.
	8. Click Save.
This action automatically creates an Azure AD Application Registration (Service Principal) and the federated credential (the trust rule) in Microsoft Entra ID.


Step 3: Crete managed identity and setup integration

Instructions --> https://learn.microsoft.com/en-au/azure/devops/pipelines/release/configure-workload-identity?view=azure-devops&tabs=managed-identity

Create managed identity in azure portal by following -> https://learn.microsoft.com/en-au/azure/devops/pipelines/release/configure-workload-identity?view=azure-devops&tabs=managed-identity#create-a-managed-identity-in-azure-portal

Details of Managed Identity that was created
Name: demo-rcb-azdo-poc-test-mi
Subscription (move) : demo-rcb-azdo-poc-test
Subscription ID : b231ee89-XXXX-XXXX-XXXX-XXXXXXXXXXXX
Client ID : f5380f15-XXXX-XXXX-XXXX-XXXXXXXXXXXX
Object (principal) ID : 6dff7a8b-XXXX-XXXX-XXXX-XXXXXXXXXXXX

{
    "apiVersion": "2024-11-30",
    "id": "/subscriptions/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/resourceGroups/demo-rcb-azdo-poc-test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/demo-rcb-azdo-poc-test-mi",
    "name": "demo-rcb-azdo-poc-test-mi",
    "type": "microsoft.managedidentity/userassignedidentities",
    "location": "eastus",
    "tags": {},
    "properties": {
        "isolationScope": "None",
        "tenantId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
        "principalId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
        "clientId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
    }
}

Name: demo-rcb-azdo-poc-test-mi2
Resource group : demo-rcb-azdo-poc-test-rg
Subscription : demo-rcb-azdo-poc-test
Subscription ID : XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
Client ID : XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
Object (principal) ID : XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

Your AZDO project is not detecting your Azure subscription? Do this.
https://docs.prod.secops.hashicorp.services/doormat/azure/tangential_services/
There are several Azure-tangential services (e.g. Azure DevOps) where resources are managed both within both the normal Azure portal and a separate Microsoft-owned website. Logging into the separate Microsoft-owned website can be tricky since hashicorp.services users are SAML-asserted into the Doormat-enabled tenants.


Create a service connection in the AZDO project.

^ This was successful.

Vault-OIDC-Federation-WIF-test
ID: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
Issuer: https://login.microsoftonline.com/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/v2.0
Subject identifier: /eid1/c/pub/t/XXXXXXXXXXXXXXXXXXXX/a/XXXXXXXXXXXXXXXXXXXX/sc/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

Organisation Details
URL:  https://dev.azure.com/your-organization/

Retrieve organisation ID
Get PAT:
Generate a Personal Access Token (PAT):
	• In Azure DevOps, click your User icon (top right) > Personal access tokens.
	• Click New Token.
	• Give it a name (e.g., GetOrgGUID).
	• Set the Organization to "All accessible organizations".
	• Set the Expiration to a short time (e.g., 1 day).
	• Under Scopes, select Custom Defined and grant Read access for the "All Scopes" group, or at least Graph (Read) and Identity (Read).
	• Click Create and immediately copy the PAT (it cannot be viewed again).

AZDO_PAT: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

curl -u :XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX 'https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=6.0'
{"displayName":"XXXXX.XXXXXXX","publicAlias":"XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX","emailAddress":"XXXXX.XXXXXXX@XXXXXXXX.XXXXXXXX","coreRevision":506581276,"timeStamp":"2026-01-20T05:01:16.2833333+00:00","id":"XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX","revision":506581276}%                       

AZDO_ORG_ID ="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
oidc_discovery_url ="https://vstoken.dev.azure.com/${AZDO_ORG_ID}"


Get project GUID
curl -u :XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX 'https://dev.azure.com/your-organization/_apis/projects?api-version=7.1'

curl -u :XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX 'https://dev.azure.com/your-organization/_apis/projects?api-version=7.1'
{"count":1,"value":[{"id":"XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX","name":"Vault-OIDC-POC","url":"https://dev.azure.com/your-organization/_apis/projects/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX","state":"wellFormed","revision":11,"visibility":"private","lastUpdateTime":"2025-11-19T01:34:24.75Z"}]}%   

AZDO_PROJECT_ID="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
AZURE_TENANT_ID="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
OIDC_ISSUER="https://login.microsoftonline.com/${AZURE_TENANT_ID}"
OIDC_DISCOVERY_URL="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"
JWKS_URI="https://login.microsoftonline.com/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/discovery/v2.0/keys"

vault write auth/oidc/config \
    oidc_discovery_url="https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0" \
    bound_issuer="https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0"

Important: JWT tokens from Entra ID contain these claims:
https://learn.microsoft.com/en-us/entra/identity-platform/id-tokens
https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference
        • iss: Issuer (login.microsoftonline.com/{tenant}/v2.0)
        • sub: Subject (unique identifier for the service principal/managed identity)
        • oid: Object ID of the identity
        • tid: Tenant ID
        • aud: Audience (api://AzureADTokenExchange)

vault write auth/oidc/role/azdo-integration-role1 -<<EOF
{
  "role_type": "jwt",
  "policies": ["app1-read-policy"],
  "bound_audiences": ["https://management.core.windows.net/", 
     "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"],
  "user_claim": "tid",
  "bound_claims_type": "glob",
  "bound_claims": {
    "sub": "*/sc/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/*"
  },
  "ttl":"1h"
}
EOF




Vault Setup
export VAULT_ADDR="https://vault-poc-cluster-public-vault-XXXXXXXX.XXXXXXXX.z1.hashicorp.cloud:8200";
export VAULT_NAMESPACE="admin"

vault policy write azdo-policy policy.hcl

vault write auth/jwt/config oidc_discovery_url="https://vstoken.dev.azure.com/${AZDO_ORG_ID}" bound_issuer="https://vstoken.dev.azure.com/${AZDO_ORG_ID}" 

vault write auth/jwt/role/azdo-project-role \
    role_type=jwt \
    policies="azdo-policy" \
    bound_audiences="api://AzureADTokenExchange" \
    bound_claims='{"projectid": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"}' \
    user_claim="sub" \
    ttl="60m"

OR 
vault write auth/jwt/config \
    oidc_discovery_url="https://login.microsoftonline.com/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/v2.0" \
    bound_issuer="https://login.microsoftonline.com/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/v2.0"

vault write auth/jwt/role/azdo-project-role1 \
    role_type="jwt" \
    bound_audiences="api://AzureADTokenExchange" \
    user_claim="sub" \
    bound_claims='{"sub": "sc://your-organization/Vault-OIDC-POC/Vault-OIDC-Federation-WIF-test"}' \
    policies="azdo-policy" \
    ttl="1h"

OR
vault write auth/jwt/config \
    oidc_discovery_url="https://login.microsoftonline.com/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/v2.0" \
    bound_issuer="https://sts.windows.net/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/" # Microsoft Entra ID

vault write auth/jwt/role/azdo-project-role2 \
    role_type="jwt" \
    bound_audiences="https://management.core.windows.net/" \ # Microsoft Entra Id
    user_claim="sub" \
    bound_claims='{"sub": "sc://your-organization/Vault-OIDC-POC/Vault-OIDC-Federation-WIF-test"}' \
    policies="azdo-policy" \
    ttl="1h"

vault write auth/jwt/role/azdo-project-role3 \
    role_type="jwt" \
    bound_audiences="https://management.core.windows.net/" \ # Microsoft Entra Id
    user_claim="tid" \ #tenant_id/org-id
    bound_claims='{"sub": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"}' \ $ GUID of the managed identity demo-rcb-azdo-poc-test-mi
    policies="azdo-policy" \
    ttl="1h"

vault write auth/jwt/role/azdo-project-role4 \
    role_type="jwt" \
    bound_audiences="https://management.core.windows.net/" \ # Microsoft Entra Id
    user_claim="tid" \ #tenant_id/org-id
    bound_claims='{"sub": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"}' \ $ GUID of the managed identity demo-rcb-azdo-poc-test-mi2
    policies="azdo-policy" \
    ttl="1h"

vault write auth/jwt/role/azdo-project-role5 -<<EOF
{
  "role_type": "jwt",
  "policies": ["azdo-policy"],
  "bound_audiences": ["https://management.core.windows.net/"],
  "user_claim": "sub",
  "bound_claims_type": "glob",
  "bound_claims": {
    "sub": "*/sc/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/*"
  },
  "ttl":"1h"
}
EOF

Findings:
	1. Using microsoft entra ID as an IDP and entra ID access token as a JWT, user_claim as tenant id (organisation's dedicated entra instance) - limits the entity count to one regardless of the project or pipeline. Options available for bound_claims are: sub (which is managed identity associated with the service principal and tenant_id)
	
Note about idToken:
https://learn.microsoft.com/en-us/azure/devops/release-notes/roadmap/2025/workload-identity-federation
Workload identity federation (WIF) enables deployment from Azure Pipelines to Azure without using secrets. The current implementation of WIF relies on an ID token issued by Azure DevOps, which is then exchanged for an Entra-issued access token. In the new revision, the ID token is also issued by Entra instead of Azure DevOps. This change will enhance security by leveraging all the mechanisms available in Entra to protect the ID tokens. This feature has rolled out, all newly created service connections use Entra-issued ID tokens.

Pipeline:

# Starter pipeline
# Start with a minimal pipeline that you can customize to build and deploy your code.
# Add steps that build, run tests, deploy, and more:
# https://aka.ms/yaml
trigger:
- none
pool:
  vmImage: ubuntu-latest
variables:
  # 1. Your HCP Vault Dedicated address
  VAULT_ADDR: 'https://vault-poc-cluster-public-vault-XXXXXXXX.XXXXXXXX.z1.hashicorp.cloud:8200'
  # 2. The namespace you created
  VAULT_NAMESPACE: 'admin'
  # 3. The name of the Service Connection created in Step 1
  AZDO_SVC_CONN: 'Vault-OIDC-Federation-WIF-test' 
  # 4. The Vault OIDC Role name created in Step 6
  VAULT_ROLE: 'azdo-project-role3' 
  
  # Set up a secret variable for the token (for later use)
  vaultToken: ''
stages:
- stage: RetrieveSecrets
  displayName: 'Retrieve Secret using OIDC via Script'
  jobs:
  - job: SecretRetrievalJob
    steps:
    
    # ----------------------------------------------------
    # STEP 1: Execute Azure CLI Task to get the OIDC Token
    # This task is critical. By referencing the AZDO Service Connection, 
    # it causes AZDO to inject the OIDC token (JWT) into the environment.
    # We will use an obscure Azure CLI command to trigger the token flow 
    # without doing any actual Azure work, just to capture the JWT.
    # ----------------------------------------------------
    - task: AzureCLI@2
      displayName: 'Trigger OIDC Token Generation'
      inputs:
        azureSubscription: '$(AZDO_SVC_CONN)'
        scriptType: 'bash'
        scriptLocation: 'inlineScript'
        # CRITICAL: This enables the $idToken variable
        addSpnToEnvironment: true
        # The AZDO runner environment variable that holds the JWT
        inlineScript: |
          # What is idToken? - The $idToken variable provided by the AzureCLI@2 task (when addSpnToEnvironment is true) is the Entra ID Access Token.
          # This is the token Entra ID gave back to the agent after it verified the AZDO token. It is signed by Microsoft's Entra ID keys, not by Azure DevOps.
          # We need to use the raw OIDC token issued by Azure DevOps. This is stored in an environment variable named AZURE_FEDERATED_TOKEN.
          # TOKEN=$AZURE_FEDERATED_TOKEN
          TOKEN=$(az account get-access-token --query accessToken -o tsv) # obtain Entra ID access token.
          
          # Decode the payload (the second part of the JWT)
          # This will output the JSON claims so you can see the "iss" value
          echo "Decoding Token Payload:"
          echo $TOKEN | cut -d. -f2 | base64 --decode | jq .
          if [ -z "$TOKEN" ]; then
            echo "##vso[task.logissue type=error]TOKEN not found."
            exit 1
          fi
          echo "AZDO Federated JWT token successfully obtained."
          echo "AZURE_FEDERATED_TOKEN is: $TOKEN"
          
          # Pass the OIDC token as an environment variable for the next step
          echo "##vso[task.setvariable variable=OIDC_TOKEN;isSecret=true]$TOKEN"
          
    # ----------------------------------------------------
    # STEP 2: Authenticate to Vault using Curl and the OIDC Token
    # Use the captured OIDC_TOKEN (JWT) to log in to Vault.
    # ----------------------------------------------------
    - script: |
        VAULT_ADDR_VAR="$VAULT_ADDR"
        VAULT_NAMESPACE_VAR="$VAULT_NAMESPACE"
        VAULT_ROLE_VAR="$VAULT_ROLE"
        JWT=$OIDC_TOKEN # Accessing the secret variable from previous step
        
        echo "Attempting OIDC login to Vault at $VAULT_ADDR_VAR in namespace $VAULT_NAMESPACE_VAR with OIDC_TOKEN: $JWT ..."
        # Curl command to hit the JWT login endpoint
        VAULT_RESPONSE=$(curl -s --request POST "$VAULT_ADDR_VAR/v1/auth/jwt/login" --header "X-Vault-Namespace: $VAULT_NAMESPACE_VAR" --data "{\"role\":\"$VAULT_ROLE_VAR\", \"jwt\":\"$JWT\"}" | jq)
          #--header "X-Vault-Namespace: $VAULT_NAMESPACE_VAR"
        echo "AUTH RESPOSE: $VAULT_RESPONSE"
        # Extract the Vault client token using jq (standard tool on agents)
        VAULT_CLIENT_TOKEN=$(echo "$VAULT_RESPONSE" | jq -r '.auth.client_token')
        if [ "$VAULT_CLIENT_TOKEN" = "null" ] || [ -z "$VAULT_CLIENT_TOKEN" ]; then
            echo "##vso[task.logissue type=error]Vault login failed. Response: $VAULT_RESPONSE"
            exit 1
        fi
        echo "Vault login successful! Setting token variable."
        
        # Set the retrieved Vault token as a secret variable for the next step
        echo "##vso[task.setvariable variable=vaultToken;isSecret=true]$VAULT_CLIENT_TOKEN"
      displayName: 'Vault OIDC Login via Curl'
      env:
        # Pass the secret OIDC token to the script environment
        OIDC_TOKEN: $(OIDC_TOKEN)
    # ----------------------------------------------------
    # STEP 3: Retrieve the Secret using the Vault Token
    # Use the Vault token from the previous step to read the KV secret.
    # ----------------------------------------------------
    - script: |
        VAULT_ADDR_VAR="$(VAULT_ADDR)"
        VAULT_NAMESPACE_VAR="$(VAULT_NAMESPACE)"
        TOKEN="$vaultToken"
        
        echo "Retrieving secret secret/sample-secret..."
        # Curl command to read the secret using the retrieved client token
        SECRET_RESPONSE=$(curl -s --request GET "$VAULT_ADDR_VAR/v1/secret/data/sample-secret" --header "X-Vault-Token: $TOKEN" --header "X-Vault-Namespace: $VAULT_NAMESPACE_VAR" | jq)
        # Extract the 'my_key' value
        echo "SECRET_RESPONSE: $SECRET_RESPONSE"
        SECRET_VALUE=$(echo "$SECRET_RESPONSE" | jq -r '.data.data["first-secret"]')
        
        if [ "$SECRET_VALUE" = "null" ] || [ -z "$SECRET_VALUE" ]; then
            echo "##vso[task.logissue type=error]Secret retrieval failed. Response: $SECRET_RESPONSE"
            exit 1
        fi
        
        echo "Successfully retrieved secret value (masked): $SECRET_VALUE"
        
        # Output the value masked by AZDO for security
        echo "##vso[task.setvariable variable=SECRET_FROM_VAULT;isSecret=true]$SECRET_VALUE"
        echo "Secret from Vault: $SECRET_FROM_VAULT"
      displayName: 'Retrieve KV Secret via Curl'
      env:
        # Pass the secret Vault token to the script environment
        vaultToken: $(vaultToken)
