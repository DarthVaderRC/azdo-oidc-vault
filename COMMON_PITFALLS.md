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
        TOKEN=$(az account get-access-token --resource https://management.core.windows.net/ -o tsv --query accessToken)
        echo "##vso[task.setvariable variable=JWT_TOKEN;issecret=true]${TOKEN}"
```

---

## 2. Bound Claims Not Matching

### Problem
OIDC authentication fails with "permission denied" even though role exists.

### Diagnosis
```bash
# Get JWT token claims
echo "${JWT_TOKEN}" | cut -d'.' -f2 | base64 -d | jq

# Check actual claims vs bound claims
vault read auth/jwt/role/your-role

# Common mismatches:
# - Issuer URL format
# - Audience value
# - Claim names (case-sensitive)
```

### Solution
```hcl
# Recommended: Exact match with managed identity claims
bound_claims = {
  sub   = "your-managed-identity-principal-id"
  appid = "your-managed-identity-client-id"
  tid   = "your-azure-tenant-id"
}

# Alternative: Glob pattern for flexibility (e.g., tenant-level)
bound_claims_type = "glob"
bound_claims = {
  tid = "your-azure-tenant-id"
}
```

---

## 3. Token Expiration During Long-Running Jobs

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

## 4. OIDC Discovery URL Not Accessible

### Problem
```
Error: failed to verify token: error validating token: unable to verify token signature
```

### Diagnosis
```bash
# Check if Vault can reach OIDC discovery URL
curl https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration

# From HCP Vault cluster, verify network access
# HCP Vault needs internet access to Entra ID's OIDC endpoint
```

### Solution
```bash
# For HCP Vault: No action needed (has internet access)

# For self-hosted Vault: Ensure firewall allows outbound HTTPS
# Allow: vault-server → login.microsoftonline.com:443

# Verify in Vault
vault read auth/jwt/config
# Should show: oidc_discovery_url
```

---

## 5. Policy Permissions Too Restrictive

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

## 6. Environment Variable Not Set in Pipeline

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

# 2. Check JWT config
vault read auth/jwt/config

# 3. List and verify roles
vault list auth/jwt/role
vault read auth/jwt/role/your-role

# 4. Test authentication with verbose logging
VAULT_LOG_LEVEL=debug vault write auth/jwt/login \
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