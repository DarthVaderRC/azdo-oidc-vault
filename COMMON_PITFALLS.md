# Common Pitfalls and Solutions

## 1. Azure DevOps OIDC Token Access

### Problem
Azure DevOps doesn't expose raw JWT tokens directly in pipeline steps.

### Solution Options

#### Option A: Azure AD Federation (Recommended for Production)
```yaml
steps:
  - task: AzureCLI@2
    inputs:
      azureSubscription: 'your-service-connection'
      scriptType: 'bash'
      addSpnToEnvironment: true
      inlineScript: |
        # Get token from Azure AD (federated with AZDO)
        TOKEN=$(az account get-access-token --resource <app-id> -o tsv --query accessToken)
        echo "##vso[task.setvariable variable=JWT_TOKEN;issecret=true]${TOKEN}"
```

#### Option B: System.AccessToken (Limited Use)
```yaml
steps:
  - task: Bash@3
    env:
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
    inputs:
      targetType: 'inline'
      script: |
        # System.AccessToken is for AZDO API, not external OIDC
        # Only use for internal AZDO operations
```

#### Option C: Pre-configured AppRole (POC Only)
```bash
# For POC, use Vault AppRole temporarily
vault auth enable approle

vault write auth/approle/role/azdo-poc \
  token_policies="azdo-secrets-reader" \
  token_ttl=1h

ROLE_ID=$(vault read -field=role_id auth/approle/role/azdo-poc/role-id)
SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/azdo-poc/secret-id)

# Use in pipeline
vault write auth/approle/login \
  role_id="${ROLE_ID}" \
  secret_id="${SECRET_ID}"
```

### Recommendation
For production, use **Option A** with Azure AD app registration federated with AZDO.

---

## 2. Bound Claims Not Matching

### Problem
OIDC authentication fails with "permission denied" even though role exists.

### Diagnosis
```bash
# Get JWT token claims
echo "${JWT_TOKEN}" | cut -d'.' -f2 | base64 -d | jq

# Check actual claims vs bound claims
vault read auth/oidc/role/your-role

# Common mismatches:
# - Issuer URL format
# - Audience value
# - Claim names (case-sensitive)
```

### Solution
```hcl
# Use glob patterns for flexibility
bound_claims_type = "glob"
bound_claims = {
  iss = "https://vstoken.dev.azure.com/*"  # Match any org
}

# Or be specific
bound_claims = {
  iss     = "https://vstoken.dev.azure.com/<exact-org-id>"
  project = "your-project-name"
}
```

---

## 3. Client Count Not Reducing as Expected

### Problem
Each pipeline run creates a new entity instead of sharing.

### Root Cause
Different `sub` claims or insufficient bound claims matching.

### Diagnosis
```bash
# List entities
vault list identity/entity/id

# Check entity aliases
for entity in $(vault list -format=json identity/entity/id | jq -r '.[]'); do
  echo "Entity: ${entity}"
  vault read -format=json identity/entity/id/${entity} | jq '.data.aliases'
done

# If you see many entities with single aliases each, bound claims aren't working
```

### Solution
```hcl
# Ensure role uses shared identifiers in bound claims
resource "vault_jwt_auth_backend_role" "shared" {
  # Use project or environment, not pipeline-specific claims
  bound_claims = {
    project = "shared-project"  # All pipelines in this project share entity
  }
  
  # Critical: Use the same user_claim for grouping
  user_claim = "sub"  # or "oid" for Azure AD
}
```

---

## 4. Token Expiration During Long-Running Jobs

### Problem
Pipeline job takes 2+ hours, but Vault token expires after 1 hour.

### Solution

#### Option A: Token Renewal
```bash
# Renew token periodically
while true; do
  vault token renew
  sleep 1800  # Renew every 30 minutes
done &

RENEW_PID=$!

# Your long-running job
./deploy-application.sh

# Cleanup
kill ${RENEW_PID}
```

#### Option B: Longer TTL (Not Recommended)
```hcl
resource "vault_jwt_auth_backend_role" "long_running" {
  token_ttl     = 7200   # 2 hours
  token_max_ttl = 14400  # 4 hours
}
```

#### Option C: Re-authenticate (Recommended)
```yaml
stages:
  - stage: Build
    jobs:
      - job: BuildJob
        steps:
          - template: vault-auth.yml  # Authenticate
          - script: ./build.sh
  
  - stage: Deploy
    jobs:
      - job: DeployJob
        steps:
          - template: vault-auth.yml  # Re-authenticate for new stage
          - script: ./deploy.sh
```

---

## 5. OIDC Discovery URL Not Accessible

### Problem
```
Error: failed to verify token: error validating token: unable to verify token signature
```

### Diagnosis
```bash
# Check if Vault can reach OIDC discovery URL
curl https://vstoken.dev.azure.com/<org-id>/.well-known/openid-configuration

# From HCP Vault cluster, verify network access
# HCP Vault needs internet access to AZDO's OIDC endpoint
```

### Solution
```bash
# For HCP Vault: No action needed (has internet access)

# For self-hosted Vault: Ensure firewall allows outbound HTTPS
# Allow: vault-server → vstoken.dev.azure.com:443

# Verify in Vault
vault read auth/oidc/config
# Should show: oidc_discovery_url
```

---

## 6. Multiple Namespaces Causing Client Multiplication

### Problem
Same pipeline authenticating to multiple namespaces creates multiple clients.

### Explanation
Each namespace counts clients separately:
```
admin/team-a → Entity 1 → Client 1
admin/team-b → Entity 2 → Client 2
```

### Solution

#### Option A: Consolidate Namespaces
```bash
# Use single namespace with path-based separation
admin/
  ├── secret/team-a/*
  ├── secret/team-b/*
  └── secret/shared/*
```

#### Option B: Accept Multiple Clients
```
# If isolation is required, this is expected behavior
# 400 pipelines × 3 namespaces = up to 1,200 clients (worst case)
# With OIDC: 15 entities × 3 namespaces = 45 clients
# Still 96% reduction!
```

---

## 7. Policy Permissions Too Restrictive

### Problem
Pipeline can authenticate but can't read secrets.

### Diagnosis
```bash
# Check assigned policies
vault token lookup

# Test policy
vault policy test your-policy secret/data/prod/app-config

# Check actual secret path
vault kv list secret/
vault kv list secret/prod/
```

### Solution
```hcl
# Ensure policy matches KV v2 path structure
# Wrong:
path "secret/prod/*" {
  capabilities = ["read"]
}

# Correct for KV v2:
path "secret/data/prod/*" {
  capabilities = ["read"]
}

path "secret/metadata/prod/*" {
  capabilities = ["list"]
}
```

---

## 8. Azure DevOps Service Connection Issues

### Problem
Service connection authentication fails or doesn't provide JWT token.

### Solution
```bash
# Create service connection with manual configuration
1. Go to: Project Settings → Service Connections
2. New Service Connection → Azure Resource Manager
3. Choose: Workload Identity Federation (manual)
4. Configure:
   - Issuer: https://vstoken.dev.azure.com/<org-id>
   - Subject: sc://<org>/<project>/<connection-name>
   - Audience: api://AzureADTokenExchange
```

---

## 9. Client Count Reporting Delays

### Problem
Client count metrics not updating immediately after pipeline runs.

### Explanation
Vault client count is calculated monthly and may have delays.

### Workaround
```bash
# Check entity count directly (real-time)
ENTITY_COUNT=$(vault list -format=json identity/entity/id | jq '. | length')
echo "Current entities: ${ENTITY_COUNT}"

# Monthly client count (may be delayed)
vault read sys/internal/counters/activity/monthly
```

---

## 10. Environment Variable Not Set in Pipeline

### Problem
```
Error: VAULT_TOKEN not set
```

### Solution
```yaml
# Ensure variable is properly exported between steps

# Wrong:
- script: |
    VAULT_TOKEN="hvs.xxx"
    # Only available in this script block

# Correct:
- script: |
    VAULT_TOKEN="hvs.xxx"
    echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]${VAULT_TOKEN}"

# Use in next step:
- script: |
    echo "Token is: $(VAULT_TOKEN)"
```

---

## Quick Troubleshooting Checklist

```bash
# 1. Verify Vault connectivity
vault status

# 2. Check OIDC config
vault read auth/oidc/config

# 3. List and verify roles
vault list auth/oidc/role
vault read auth/oidc/role/your-role

# 4. Test authentication with verbose logging
VAULT_LOG_LEVEL=debug vault write auth/oidc/login \
  role="your-role" \
  jwt="${JWT_TOKEN}"

# 5. Verify policies
vault policy list
vault policy read your-policy

# 6. Check entity count
vault list identity/entity/id

# 7. Review audit logs
vault audit list
# Check audit logs in HCP Vault Portal

# 8. Test secret access
vault kv get secret/path/to/secret
```

---

## Getting Help

1. **HashiCorp Community Forum**: https://discuss.hashicorp.com/
2. **GitHub Issues**: https://github.com/hashicorp/vault/issues
3. **HCP Support**: For HCP Vault Dedicated customers
4. **Azure DevOps Docs**: https://learn.microsoft.com/en-us/azure/devops/

## Additional Resources

- [Vault OIDC Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Azure DevOps Workload Identity](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure)
- [HCP Vault Client Count](https://developer.hashicorp.com/vault/tutorials/monitoring/usage-metrics)
