# Step 5: Production Recommendations

## 5.1 Production Architecture

### Recommended Bound Claims Strategy

For your 400+ pipelines, consider this hierarchical approach:

```
Level 1: By Business Unit / Department
├── oidc-role: bu-retail (50 entities)
├── oidc-role: bu-banking (40 entities)
├── oidc-role: bu-insurance (30 entities)
└── oidc-role: bu-corporate (20 entities)

Level 2: By Environment
├── oidc-role: env-production (15 entities)
├── oidc-role: env-staging (10 entities)
└── oidc-role: env-development (5 entities)

Level 3: By Application Type
├── oidc-role: app-web (20 entities)
├── oidc-role: app-api (15 entities)
└── oidc-role: app-batch (10 entities)
```

**Total Estimated Entities**: 30-50 (vs 400+)
**Client Reduction**: 87.5% - 92.5%

## 5.2 Bound Claims Implementation Guide

### Strategy 1: Tenant-Based (Simplest)

```hcl
# All managed identities in same tenant can authenticate
resource "vault_jwt_auth_backend_role" "tenant_pipelines" {
  backend         = vault_auth_backend.jwt.path
  role_name       = "tenant-pipelines"
  token_policies  = ["dev-secrets-reader"]
  
  role_type       = "jwt"
  bound_audiences = ["https://management.core.windows.net/"]
  user_claim      = "sub"
  
  bound_claims = {
    tid = var.azure_tenant_id
  }
}
```

### Strategy 2: Per Managed Identity (Recommended)

```hcl
# Separate roles per managed identity for environment isolation
resource "vault_jwt_auth_backend_role" "env_production" {
  backend         = vault_auth_backend.jwt.path
  role_name       = "env-production"
  token_policies  = ["prod-secrets-reader", "prod-secrets-writer"]
  
  role_type       = "jwt"
  bound_audiences = ["https://management.core.windows.net/"]
  user_claim      = "sub"
  
  bound_claims = {
    sub   = var.prod_mi_principal_id
    appid = var.prod_mi_client_id
    tid   = var.azure_tenant_id
  }
  
  token_ttl     = 1800  # 30 minutes
  token_max_ttl = 3600  # 1 hour
}
```

### Strategy 3: By Managed Identity with OID (Advanced)

```hcl
# Use object ID (oid) claim from managed identity
# Different managed identities for different purposes
resource "vault_jwt_auth_backend_role" "app_team_a" {
  backend         = vault_auth_backend.jwt.path
  role_name       = "team-a-apps"
  token_policies  = ["team-a-secrets"]
  
  role_type       = "jwt"
  bound_audiences = ["https://management.core.windows.net/"]
  user_claim      = "sub"
  
  bound_claims = {
    sub   = var.team_a_mi_principal_id
    appid = var.team_a_mi_client_id
    tid   = var.azure_tenant_id
  }
}
```

### Strategy 4: Hybrid Approach (Best for Scale)

```hcl
# Multi-tenant with wildcard issuer (note: different from single-tenant approach)
resource "vault_jwt_auth_backend_role" "multi_tenant" {
  backend         = vault_auth_backend.jwt.path
  role_name       = "multi-tenant-pipelines"
  token_policies  = ["shared-secrets"]
  
  role_type       = "jwt"
  bound_audiences = ["https://management.core.windows.net/"]
  user_claim      = "sub"
  
  bound_claims_type = "glob"
  bound_claims = {
    iss = "https://sts.windows.net/*/",  # Any tenant (multi-tenant)
  }
  
  token_ttl         = 1800
  token_bound_cidrs = ["10.0.0.0/8"]  # Azure pipeline agent network
}
```

## 5.3 Terraform Implementation

Create production-ready Terraform configuration:

File: `terraform/main.tf`

```hcl
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 3.20"
    }
  }
}

provider "vault" {
  address   = var.vault_address
  namespace = var.vault_namespace
  token     = var.vault_token
}

# OIDC Auth Backend
resource "vault_jwt_auth_backend" "azdo" {
  description        = "Azure DevOps JWT Authentication with Entra ID"
  path              = "jwt"
  type              = "jwt"
  
  oidc_discovery_url = "https://login.microsoftonline.com/${var.azure_tenant_id}/v2.0"
  bound_issuer       = "https://sts.windows.net/${var.azure_tenant_id}/"
  default_role       = "default-azdo"
  
  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "4h"
  }
}

# KV Secrets Engine
resource "vault_mount" "kv" {
  path        = "secret"
  type        = "kv-v2"
  description = "KV v2 secrets engine for Azure DevOps pipelines"
}

# Policies
resource "vault_policy" "dev_reader" {
  name = "dev-secrets-reader"
  
  policy = <<EOT
path "secret/data/dev/*" {
  capabilities = ["read", "list"]
}

path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/dev/*" {
  capabilities = ["list"]
}
EOT
}

resource "vault_policy" "prod_reader" {
  name = "prod-secrets-reader"
  
  policy = <<EOT
path "secret/data/prod/*" {
  capabilities = ["read", "list"]
}

path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/prod/*" {
  capabilities = ["list"]
}
EOT
}

# OIDC Roles - Development
resource "vault_jwt_auth_backend_role" "dev_pipelines" {
  backend         = vault_jwt_auth_backend.azdo.path
  role_name       = "dev-pipelines"
  token_policies  = [vault_policy.dev_reader.name]
  
  role_type       = "jwt"
  bound_audiences = ["https://management.core.windows.net/"]
  user_claim      = "sub"
  
  bound_claims = {
    sub   = var.dev_mi_principal_id
    appid = var.dev_mi_client_id
    tid   = var.azure_tenant_id
  }
  
  token_ttl       = 3600
  token_max_ttl   = 7200
}

# OIDC Roles - Production
resource "vault_jwt_auth_backend_role" "prod_pipelines" {
  backend         = vault_jwt_auth_backend.azdo.path
  role_name       = "prod-pipelines"
  token_policies  = [vault_policy.prod_reader.name]
  
  role_type       = "jwt"
  bound_audiences = ["https://management.core.windows.net/"]
  user_claim      = "sub"
  
  bound_claims = {
    sub   = var.prod_mi_principal_id
    appid = var.prod_mi_client_id
    tid   = var.azure_tenant_id
  }
  
  token_ttl       = 1800
  token_max_ttl   = 3600
}

# Sample secrets
resource "vault_kv_secret_v2" "dev_config" {
  mount               = vault_mount.kv.path
  name                = "dev/app-config"
  cas                 = 1
  delete_all_versions = true
  
  data_json = jsonencode({
    database_url = "postgresql://dev-db:5432/myapp"
    api_key      = "dev-api-key-12345"
    environment  = "development"
  })
}

resource "vault_kv_secret_v2" "prod_config" {
  mount               = vault_mount.kv.path
  name                = "prod/app-config"
  cas                 = 1
  delete_all_versions = true
  
  data_json = jsonencode({
    database_url = "postgresql://prod-db:5432/myapp"
    api_key      = "prod-api-key-67890"
    environment  = "production"
  })
}
```

File: `terraform/variables.tf`

```hcl
variable "vault_address" {
  description = "HCP Vault cluster address"
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace"
  type        = string
  default     = "admin"
}

variable "vault_token" {
  description = "Vault admin token"
  type        = string
  sensitive   = true
}

variable "azure_tenant_id" {
  description = "Azure Tenant ID for Entra ID OAuth"
  type        = string
}

variable "dev_mi_principal_id" {
  description = "Dev managed identity principal (object) ID"
  type        = string
}

variable "dev_mi_client_id" {
  description = "Dev managed identity client (application) ID"
  type        = string
}

variable "prod_mi_principal_id" {
  description = "Prod managed identity principal (object) ID"
  type        = string
}

variable "prod_mi_client_id" {
  description = "Prod managed identity client (application) ID"
  type        = string
}
```

File: `terraform/outputs.tf`

```hcl
output "oidc_auth_path" {
  description = "Path to OIDC auth backend"
  value       = vault_jwt_auth_backend.azdo.path
}

output "oidc_roles" {
  description = "Created OIDC roles"
  value = {
    dev  = vault_jwt_auth_backend_role.dev_pipelines.role_name
    prod = vault_jwt_auth_backend_role.prod_pipelines.role_name
  }
}

output "policies" {
  description = "Created policies"
  value = {
    dev  = vault_policy.dev_reader.name
    prod = vault_policy.prod_reader.name
  }
}
```

Apply Terraform:
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## 5.4 Azure DevOps Pipeline Template

Create reusable pipeline template:

File: `templates/vault-integration.yml`

```yaml
parameters:
  - name: vaultAddr
    type: string
  - name: vaultNamespace
    type: string
  - name: oidcRole
    type: string
  - name: secretPath
    type: string

steps:
  - task: AzureCLI@2
    displayName: 'Get Access Token'
    inputs:
      azureSubscription: '$(azureServiceConnection)'
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      inlineScript: |
        # Get access token with Azure Resource Manager audience
        TOKEN=$(az account get-access-token \
          --resource https://management.core.windows.net/ \
          --query accessToken -o tsv)
        
        echo "##vso[task.setvariable variable=ACCESS_TOKEN;issecret=true]${TOKEN}"

  - task: Bash@3
    displayName: 'Authenticate to Vault'
    env:
      VAULT_ADDR: ${{ parameters.vaultAddr }}
      VAULT_NAMESPACE: ${{ parameters.vaultNamespace }}
      ACCESS_TOKEN: $(ACCESS_TOKEN)
    inputs:
      targetType: 'inline'
      script: |
        AUTH_RESPONSE=$(curl --silent --request POST \
          --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          --data "{\"jwt\": \"${ACCESS_TOKEN}\", \"role\": \"${{ parameters.oidcRole }}\"}" \
          ${VAULT_ADDR}/v1/auth/jwt/login)
        
        VAULT_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.auth.client_token')
        
        if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
          echo "Error: Failed to authenticate to Vault"
          echo "Response: $AUTH_RESPONSE"
          exit 1
        fi
        
        echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true;isOutput=true]${VAULT_TOKEN}"

  - task: Bash@3
    displayName: 'Retrieve Secrets'
    env:
      VAULT_ADDR: ${{ parameters.vaultAddr }}
      VAULT_NAMESPACE: ${{ parameters.vaultNamespace }}
      VAULT_TOKEN: $(VAULT_TOKEN)
    inputs:
      targetType: 'inline'
      script: |
        # Read secrets using curl
        SECRET_DATA=$(curl --silent \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
          ${VAULT_ADDR}/v1/${{ parameters.secretPath }})
        
        # Export each key as a masked pipeline variable
        echo "$SECRET_DATA" | jq -r '.data.data | to_entries[] | "##vso[task.setvariable variable=\(.key);issecret=true]\(.value)"'
```

Use the template in pipelines:

File: `azure-pipelines-prod.yml`

```yaml
trigger:
  branches:
    include:
      - main

pool:
  vmImage: 'ubuntu-latest'

variables:
  - group: vault-config  # Variable group with Vault settings

stages:
  - stage: Deploy
    jobs:
      - job: DeployApp
        steps:
          - template: templates/vault-integration.yml
            parameters:
              vaultAddr: $(VAULT_ADDR)
              vaultNamespace: $(VAULT_NAMESPACE)
              oidcRole: 'prod-pipelines'
              secretPath: 'secret/prod/app-config'
          
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

## 5.5 Security Best Practices

### 1. Token TTL Configuration

```hcl
resource "vault_jwt_auth_backend_role" "secure_role" {
  # Short-lived tokens
  token_ttl       = 1800   # 30 minutes
  token_max_ttl   = 3600   # 1 hour
  
  # Prevent token renewal beyond max TTL
  token_no_default_policy = true
  
  # Limit token usage
  token_num_uses = 1  # Single-use token
}
```

### 2. Network Restrictions

```hcl
resource "vault_jwt_auth_backend_role" "network_restricted" {
  # Restrict to Azure DevOps agent IP ranges
  token_bound_cidrs = [
    "20.0.0.0/8",     # Azure DevOps agents
    "40.0.0.0/8",     # Azure DevOps agents
    "your-vpn-cidr"   # Your corporate VPN
  ]
}
```

### 3. Audit Everything

```bash
# Enable audit logging
vault audit enable file \
  file_path=/vault/logs/audit.log \
  log_raw=false \
  format=json

# For HCP Vault, audit logs are automatic
# Access via: Portal → Vault Cluster → Logs
```

### 4. Least Privilege Policies

```hcl
# Bad: Too permissive
path "secret/*" {
  capabilities = ["read", "list", "create", "update", "delete"]
}

# Good: Specific and limited
path "secret/data/prod/app-name/*" {
  capabilities = ["read"]
}

path "secret/metadata/prod/app-name/*" {
  capabilities = ["list"]
}
```

### 5. Rotation Strategy

```bash
# Rotate secrets regularly
vault kv put secret/prod/app-config \
  database_url="new-connection-string" \
  api_key="new-api-key" \
  environment="production"

# Use Vault's dynamic secrets where possible
vault secrets enable database

vault write database/config/myapp \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres:5432/myapp" \
  allowed_roles="prod-role" \
  username="vault" \
  password="vault-password"
```

## 5.6 Monitoring and Alerting

### Client Count Monitoring

```bash
# Create script to monitor client count
#!/bin/bash

THRESHOLD=100
CURRENT_COUNT=$(vault read -field=clients sys/internal/counters/activity/monthly)

if [ ${CURRENT_COUNT} -gt ${THRESHOLD} ]; then
  echo "Alert: Client count (${CURRENT_COUNT}) exceeds threshold (${THRESHOLD})"
  # Send alert to monitoring system
fi
```

### Key Metrics to Track

1. **Active Clients**: Monthly unique entities
2. **Authentication Rate**: Logins per hour
3. **Token Usage**: Average token lifetime
4. **Policy Violations**: Failed auth attempts
5. **Secret Access**: Read operations per secret

## 5.7 Migration Plan

### Phase 1: Pilot (Weeks 1-2)
- Select 5-10 non-critical pipelines
- Implement OIDC authentication
- Validate functionality
- Gather metrics

### Phase 2: Dev/Test (Weeks 3-4)
- Migrate all development pipelines
- Monitor client count reduction
- Fine-tune bound claims
- Update documentation

### Phase 3: Production (Weeks 5-8)
- Migrate production pipelines in batches
- 24/7 monitoring
- Rollback plan ready
- Post-migration validation

### Phase 4: Cleanup (Week 9)
- Decommission service principals
- Finalize cost savings report
- Update runbooks
- Team training

## 5.8 Troubleshooting Guide

### Issue 1: Authentication Failures

```bash
# Check JWT configuration
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/auth/jwt/config | jq

# Verify role configuration
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/auth/jwt/role/your-role | jq

# Test with verbose output - decode JWT token first
echo "${JWT_TOKEN}" | cut -d'.' -f2 | base64 -d | jq

# Check if issuer matches
# JWT iss claim should match bound_issuer in JWT config
# Expected for access tokens: https://sts.windows.net/<tenant-id>/
```

### Issue 2: Client Count Not Reducing

```bash
# List all entities
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request LIST \
     ${VAULT_ADDR}/v1/identity/entity/id | jq

# Check entity aliases (should see multiple aliases per entity if working)
ENTITY_ID="your-entity-id"
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/identity/entity/id/${ENTITY_ID} | jq '.data.aliases'

# Verify bound claims are working
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/auth/jwt/role/your-role | jq '.data.bound_claims'

# Expected: Multiple aliases per entity
# If each pipeline creates new entity, bound_claims aren't matching
# Verify JWT issuer: https://sts.windows.net/<tenant-id>/
```

### Issue 3: Permission Denied

```bash
# Check assigned policies
vault token lookup

# Verify policy contents
vault policy read your-policy

# Test policy
vault policy test your-policy secret/data/prod/app-config
```

## 5.9 Success Criteria

✅ **Client Count Reduction**: 85%+ reduction from baseline
✅ **Cost Savings**: $1,500+ annual savings
✅ **Authentication Success**: 99%+ success rate
✅ **Performance**: <3s authentication time
✅ **Security**: No exposed credentials, short-lived tokens
✅ **Operational**: Simplified credential management

## Next Steps

- Review [Common Pitfalls](COMMON_PITFALLS.md)
- Explore [Advanced Configurations](ADVANCED_CONFIG.md)
- Join HashiCorp Community for support
