# Sample Pipeline Templates and Scripts

This directory contains reusable templates and scripts for Azure DevOps + Vault integration.

## Directory Structure

```
samples/
├── pipelines/
│   ├── basic-vault-integration.yml
│   ├── multi-stage-deployment.yml
│   └── template-vault-auth.yml
├── scripts/
│   ├── install-vault.sh
│   ├── vault-auth.sh
│   └── get-secrets.sh
└── terraform/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

## Pipeline Templates

### 1. Basic Vault Integration

File: `pipelines/basic-vault-integration.yml`

```yaml
# Simple pipeline demonstrating Vault secret retrieval
trigger:
  branches:
    include:
      - main

pool:
  vmImage: 'ubuntu-latest'

variables:
  VAULT_ADDR: 'https://your-cluster.hashicorp.cloud:8200'
  VAULT_NAMESPACE: 'admin'
  VAULT_ROLE: 'azdo-pipelines'

steps:
  - checkout: self

  - task: Bash@3
    displayName: 'Install Vault CLI'
    inputs:
      filePath: 'scripts/install-vault.sh'

  - task: Bash@3
    displayName: 'Authenticate to Vault'
    inputs:
      filePath: 'scripts/vault-auth.sh'
      arguments: '$(VAULT_ADDR) $(VAULT_NAMESPACE) $(VAULT_ROLE)'

  - task: Bash@3
    displayName: 'Get Secrets'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      VAULT_TOKEN: $(VAULT_TOKEN)
    inputs:
      targetType: 'inline'
      script: |
        vault kv get -format=json secret/my-app/config | \
          jq -r '.data.data | to_entries[] | 
          "##vso[task.setvariable variable=\(.key);issecret=true]\(.value)"'

  - task: Bash@3
    displayName: 'Deploy Application'
    env:
      DATABASE_URL: $(database_url)
      API_KEY: $(api_key)
    inputs:
      targetType: 'inline'
      script: |
        echo "Deploying with secrets from Vault..."
        # Your deployment logic here
```

### 2. Multi-Stage Deployment with Vault

File: `pipelines/multi-stage-deployment.yml`

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

stages:
  - stage: Build
    displayName: 'Build Application'
    jobs:
      - job: BuildJob
        displayName: 'Build and Test'
        steps:
          - template: template-vault-auth.yml
            parameters:
              vaultRole: 'dev-pipelines'
              secretPath: 'secret/dev/build-config'
          
          - task: Bash@3
            displayName: 'Build Application'
            inputs:
              targetType: 'inline'
              script: |
                echo "Building application..."
                # Build steps here

  - stage: DeployDev
    displayName: 'Deploy to Development'
    dependsOn: Build
    condition: succeeded()
    jobs:
      - deployment: DeployDevJob
        displayName: 'Deploy to Dev Environment'
        environment: 'development'
        strategy:
          runOnce:
            deploy:
              steps:
                - template: template-vault-auth.yml
                  parameters:
                    vaultRole: 'dev-pipelines'
                    secretPath: 'secret/dev/app-config'
                
                - task: Bash@3
                  displayName: 'Deploy to Dev'
                  env:
                    DATABASE_URL: $(database_url)
                    API_KEY: $(api_key)
                  inputs:
                    targetType: 'inline'
                    script: |
                      echo "Deploying to development..."
                      # Deployment steps

  - stage: DeployProd
    displayName: 'Deploy to Production'
    dependsOn: DeployDev
    condition: succeeded()
    jobs:
      - deployment: DeployProdJob
        displayName: 'Deploy to Production Environment'
        environment: 'production'
        strategy:
          runOnce:
            deploy:
              steps:
                - template: template-vault-auth.yml
                  parameters:
                    vaultRole: 'prod-pipelines'
                    secretPath: 'secret/prod/app-config'
                
                - task: Bash@3
                  displayName: 'Deploy to Production'
                  env:
                    DATABASE_URL: $(database_url)
                    API_KEY: $(api_key)
                  inputs:
                    targetType: 'inline'
                    script: |
                      echo "Deploying to production..."
                      # Production deployment steps
```

### 3. Reusable Vault Authentication Template

File: `pipelines/template-vault-auth.yml`

```yaml
parameters:
  - name: vaultRole
    type: string
    default: 'azdo-pipelines'
  - name: secretPath
    type: string
    default: 'secret/app/config'

steps:
  - task: Bash@3
    displayName: 'Install Vault CLI'
    inputs:
      targetType: 'inline'
      script: |
        if ! command -v vault &> /dev/null; then
          VAULT_VERSION="1.15.0"
          echo "Installing Vault ${VAULT_VERSION}..."
          curl -Lo vault.zip "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"
          unzip -o vault.zip
          sudo mv vault /usr/local/bin/
          rm vault.zip
        fi
        vault version

  - task: Bash@3
    displayName: 'Authenticate to Vault'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      VAULT_ROLE: ${{ parameters.vaultRole }}
    inputs:
      targetType: 'inline'
      script: |
        echo "Authenticating to Vault..."
        echo "  Address: ${VAULT_ADDR}"
        echo "  Namespace: ${VAULT_NAMESPACE}"
        echo "  Role: ${VAULT_ROLE}"
        
        # For POC: Using pre-configured token
        # In production: Use Azure AD federated identity
        export VAULT_TOKEN="$(VAULT_POC_TOKEN)"
        
        # Verify authentication
        vault token lookup
        
        # Make token available for subsequent steps
        echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true;isOutput=true]${VAULT_TOKEN}"

  - task: Bash@3
    displayName: 'Retrieve Secrets'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_NAMESPACE: $(VAULT_NAMESPACE)
      VAULT_TOKEN: $(VAULT_TOKEN)
      SECRET_PATH: ${{ parameters.secretPath }}
    inputs:
      targetType: 'inline'
      script: |
        echo "Retrieving secrets from: ${SECRET_PATH}"
        
        # Get all secrets and set as pipeline variables
        vault kv get -format=json "${SECRET_PATH}" | \
          jq -r '.data.data | to_entries[] | 
          "##vso[task.setvariable variable=\(.key);issecret=true]\(.value)"'
        
        echo "Secrets retrieved successfully"
```

## Scripts

### 1. Install Vault CLI

File: `scripts/install-vault.sh`

```bash
#!/bin/bash
set -e

VAULT_VERSION="${VAULT_VERSION:-1.15.0}"
VAULT_ZIP="vault_${VAULT_VERSION}_linux_amd64.zip"
VAULT_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/${VAULT_ZIP}"

echo "=========================================="
echo "Installing Vault CLI v${VAULT_VERSION}"
echo "=========================================="

# Check if already installed
if command -v vault &> /dev/null; then
    INSTALLED_VERSION=$(vault version | head -1 | awk '{print $2}' | sed 's/v//')
    if [ "${INSTALLED_VERSION}" = "${VAULT_VERSION}" ]; then
        echo "Vault ${VAULT_VERSION} is already installed"
        exit 0
    fi
fi

# Download and install
echo "Downloading Vault from ${VAULT_URL}..."
curl -Lo vault.zip "${VAULT_URL}"

echo "Installing Vault..."
unzip -o vault.zip
sudo mv vault /usr/local/bin/
rm vault.zip

# Verify installation
echo ""
echo "Vault installed successfully:"
vault version

echo "=========================================="
```

### 2. Vault Authentication

File: `scripts/vault-auth.sh`

```bash
#!/bin/bash
set -e

VAULT_ADDR="${1}"
VAULT_NAMESPACE="${2}"
OIDC_ROLE="${3}"

if [ -z "${VAULT_ADDR}" ] || [ -z "${VAULT_NAMESPACE}" ] || [ -z "${OIDC_ROLE}" ]; then
    echo "Usage: $0 <vault-addr> <vault-namespace> <oidc-role>"
    exit 1
fi

echo "=========================================="
echo "Authenticating to Vault"
echo "=========================================="
echo "Address: ${VAULT_ADDR}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo "Role: ${OIDC_ROLE}"
echo ""

export VAULT_ADDR
export VAULT_NAMESPACE

# Method 1: Using Azure AD token (production)
if [ -n "${AZURE_TOKEN}" ]; then
    echo "Using Azure AD token for authentication..."
    
    VAULT_TOKEN=$(vault write -field=token auth/oidc/login \
        role="${OIDC_ROLE}" \
        jwt="${AZURE_TOKEN}")
    
    if [ -z "${VAULT_TOKEN}" ]; then
        echo "Error: Failed to authenticate with Azure AD token"
        exit 1
    fi
    
    echo "Successfully authenticated with Azure AD!"

# Method 2: Using pre-configured token (POC)
elif [ -n "${VAULT_POC_TOKEN}" ]; then
    echo "Using pre-configured token for POC..."
    VAULT_TOKEN="${VAULT_POC_TOKEN}"
    
    # Verify token
    export VAULT_TOKEN
    vault token lookup > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "Token is valid"
    else
        echo "Error: Invalid token"
        exit 1
    fi

else
    echo "Error: No authentication method available"
    echo "Set either AZURE_TOKEN or VAULT_POC_TOKEN environment variable"
    exit 1
fi

# Export token for subsequent steps
export VAULT_TOKEN
echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]${VAULT_TOKEN}"

echo ""
echo "Authentication successful!"
echo "=========================================="
```

### 3. Get Secrets Helper

File: `scripts/get-secrets.sh`

```bash
#!/bin/bash
set -e

SECRET_PATH="${1}"

if [ -z "${SECRET_PATH}" ]; then
    echo "Usage: $0 <secret-path>"
    echo "Example: $0 secret/prod/app-config"
    exit 1
fi

if [ -z "${VAULT_ADDR}" ] || [ -z "${VAULT_TOKEN}" ]; then
    echo "Error: VAULT_ADDR and VAULT_TOKEN must be set"
    exit 1
fi

echo "=========================================="
echo "Retrieving Secrets from Vault"
echo "=========================================="
echo "Path: ${SECRET_PATH}"
echo ""

# Get secrets
SECRET_DATA=$(vault kv get -format=json "${SECRET_PATH}")

if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve secrets"
    exit 1
fi

echo "Secrets retrieved successfully!"
echo ""

# Parse and export secrets
echo "${SECRET_DATA}" | jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' | while IFS='=' read -r key value; do
    # Mask sensitive values
    echo "  ${key}: ****"
    
    # Set as pipeline variable (masked)
    echo "##vso[task.setvariable variable=${key};issecret=true]${value}"
done

echo ""
echo "All secrets exported as pipeline variables"
echo "=========================================="
```

## Usage Examples

### Example 1: Simple Secret Retrieval

```yaml
steps:
  - template: template-vault-auth.yml
    parameters:
      vaultRole: 'my-app-role'
      secretPath: 'secret/my-app/config'

  - script: |
      echo "Using secrets: $(database_url)"
    displayName: 'Use Secrets'
```

### Example 2: Multiple Secret Paths

```yaml
steps:
  - template: template-vault-auth.yml
    parameters:
      vaultRole: 'app-role'
      secretPath: 'secret/shared/common'

  - bash: |
      vault kv get -format=json secret/my-app/specific | \
        jq -r '.data.data | to_entries[] | 
        "##vso[task.setvariable variable=\(.key);issecret=true]\(.value)"'
    env:
      VAULT_ADDR: $(VAULT_ADDR)
      VAULT_TOKEN: $(VAULT_TOKEN)
    displayName: 'Get Additional Secrets'
```

### Example 3: Dynamic Secret Selection

```yaml
parameters:
  - name: environment
    type: string
    default: 'dev'
    values:
      - dev
      - staging
      - prod

steps:
  - template: template-vault-auth.yml
    parameters:
      vaultRole: '${{ parameters.environment }}-pipelines'
      secretPath: 'secret/${{ parameters.environment }}/app-config'
```

## Making Scripts Executable

```bash
chmod +x scripts/*.sh
```

## Testing Locally

```bash
# Set environment variables
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
export VAULT_POC_TOKEN="hvs.your-token"

# Test installation
./scripts/install-vault.sh

# Test authentication
./scripts/vault-auth.sh "${VAULT_ADDR}" "${VAULT_NAMESPACE}" "azdo-pipelines"

# Test secret retrieval
./scripts/get-secrets.sh "secret/dev/app-config"
```

## Best Practices

1. **Always use templates** for common operations (DRY principle)
2. **Mask sensitive variables** using `issecret=true`
3. **Use short-lived tokens** (30-60 minutes)
4. **Re-authenticate per stage** for long-running pipelines
5. **Log operations** but never log secrets
6. **Handle errors gracefully** with proper exit codes
7. **Use parameters** for flexibility across environments

## Troubleshooting

### Script fails with "command not found"
```bash
# Ensure scripts are executable
chmod +x scripts/*.sh

# Or call with bash explicitly
bash scripts/install-vault.sh
```

### Secrets not available in next step
```yaml
# Make sure to use ##vso[task.setvariable]
echo "##vso[task.setvariable variable=MY_SECRET;issecret=true]${VALUE}"

# Access in next step
env:
  MY_SECRET: $(MY_SECRET)
```

### Token expires during pipeline
```yaml
# Re-authenticate in each stage
stages:
  - stage: Build
    jobs:
      - job: BuildJob
        steps:
          - template: template-vault-auth.yml  # Auth for build

  - stage: Deploy
    jobs:
      - job: DeployJob
        steps:
          - template: template-vault-auth.yml  # Re-auth for deploy
```
