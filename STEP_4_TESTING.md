# Step 4: Testing and Client Count Validation

## 4.1 Test Basic Vault Integration

### Test 1: Manual Vault API Authentication (Local)

```bash
# Set environment variables
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
export VAULT_TOKEN="hvs.your-admin-token"

# Verify connection
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/sys/health | jq

# Read secrets
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/secret/data/dev/app-config | jq

curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/secret/data/prod/app-config | jq

# List secrets
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request LIST \
     ${VAULT_ADDR}/v1/secret/metadata | jq
```

### Test 2: Run Azure DevOps Pipeline

1. Commit the pipeline YAML file to your repository
2. In Azure DevOps, go to Pipelines
3. Create a new pipeline and select your repository
4. Select existing YAML file: `azure-pipelines-simple.yml`
5. Run the pipeline
6. Verify:
   - Vault CLI installs successfully
   - Authentication works
   - Secrets are retrieved

## 4.2 Monitor Client Count

### Method 1: Using Vault UI

1. Login to HCP Vault Portal
2. Navigate to your cluster
3. Go to **"Client Count"** dashboard
4. Observe active clients after pipeline runs

### Method 2: Using Vault API (curl)

```bash
# View current client count
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/sys/internal/counters/activity/monthly | jq

# View detailed client information
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/sys/internal/counters/activity/monthly | jq '.data.clients'

# List entities (each entity = 1 client)
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request LIST \
     ${VAULT_ADDR}/v1/identity/entity/id | jq

# Get entity details
ENTITY_ID="<entity-id-from-list>"
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/identity/entity/id/${ENTITY_ID} | jq

# View entity aliases
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/identity/entity/id/${ENTITY_ID} | jq '.data.aliases'
```

### Method 3: Using Vault API

```bash
# Get client count
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     ${VAULT_ADDR}/v1/sys/internal/counters/activity/monthly

# List entities
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request LIST \
     ${VAULT_ADDR}/v1/identity/entity/id
```

## 4.3 Test Client Count Reduction

### Scenario: Multiple Pipelines, Same Bound Claims

Create three separate pipelines with the same bound claims:

#### Pipeline 1: `pipeline-app1.yml`
```yaml
name: App1 Pipeline

trigger: none

pool:
  vmImage: 'ubuntu-latest'

variables:
  VAULT_ADDR: 'https://your-cluster.hashicorp.cloud:8200'
  VAULT_NAMESPACE: 'admin'
  APP_NAME: 'app1'

steps:
  - task: AzureCLI@2
    displayName: 'Get Access Token & Retrieve Secrets for App1'
    inputs:
      azureSubscription: 'vault-managed-identity'
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      inlineScript: |
        ACCESS_TOKEN=$(az account get-access-token \
          --resource https://management.core.windows.net/ \
          --query accessToken -o tsv)
        
        VAULT_TOKEN=$(curl --silent --request POST \
          --header "X-Vault-Namespace: $(VAULT_NAMESPACE)" \
          --data "{\"jwt\": \"${ACCESS_TOKEN}\", \"role\": \"dev-mi-role\"}" \
          $(VAULT_ADDR)/v1/auth/jwt/login | jq -r '.auth.client_token')
        
        echo "App: $(APP_NAME)"
        curl --silent \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          --header "X-Vault-Namespace: $(VAULT_NAMESPACE)" \
          $(VAULT_ADDR)/v1/secret/data/dev/app-config | jq
```

#### Pipeline 2: `pipeline-app2.yml`
```yaml
name: App2 Pipeline

trigger: none

pool:
  vmImage: 'ubuntu-latest'

variables:
  VAULT_ADDR: 'https://your-cluster.hashicorp.cloud:8200'
  VAULT_NAMESPACE: 'admin'
  APP_NAME: 'app2'

steps:
  - task: AzureCLI@2
    displayName: 'Get Access Token & Retrieve Secrets for App2'
    inputs:
      azureSubscription: 'vault-managed-identity'
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      inlineScript: |
        ACCESS_TOKEN=$(az account get-access-token \
          --resource https://management.core.windows.net/ \
          --query accessToken -o tsv)
        
        VAULT_TOKEN=$(curl --silent --request POST \
          --header "X-Vault-Namespace: $(VAULT_NAMESPACE)" \
          --data "{\"jwt\": \"${ACCESS_TOKEN}\", \"role\": \"dev-mi-role\"}" \
          $(VAULT_ADDR)/v1/auth/jwt/login | jq -r '.auth.client_token')
        
        echo "App: $(APP_NAME)"
        curl --silent \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          --header "X-Vault-Namespace: $(VAULT_NAMESPACE)" \
          $(VAULT_ADDR)/v1/secret/data/dev/app-config | jq
```

#### Pipeline 3: `pipeline-app3.yml`
```yaml
name: App3 Pipeline

trigger: none

pool:
  vmImage: 'ubuntu-latest'

variables:
  VAULT_ADDR: 'https://your-cluster.hashicorp.cloud:8200'
  VAULT_NAMESPACE: 'admin'
  APP_NAME: 'app3'

steps:
  - task: AzureCLI@2
    displayName: 'Get Access Token & Retrieve Secrets for App3'
    inputs:
      azureSubscription: 'vault-managed-identity'
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      inlineScript: |
        ACCESS_TOKEN=$(az account get-access-token \
          --resource https://management.core.windows.net/ \
          --query accessToken -o tsv)
        
        VAULT_TOKEN=$(curl --silent --request POST \
          --header "X-Vault-Namespace: $(VAULT_NAMESPACE)" \
          --data "{\"jwt\": \"${ACCESS_TOKEN}\", \"role\": \"dev-mi-role\"}" \
          $(VAULT_ADDR)/v1/auth/jwt/login | jq -r '.auth.client_token')
        
        echo "App: $(APP_NAME)"
        curl --silent \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          --header "X-Vault-Namespace: $(VAULT_NAMESPACE)" \
          $(VAULT_ADDR)/v1/secret/data/dev/app-config | jq
```

### Expected Result

With **Service Principals**: 3 pipelines = 3 entities = **3 clients**

With **OIDC + Bound Claims** (all in same project): 3 pipelines = 1 entity (with 3 aliases) = **1 client**

### Verification Steps

1. Run Pipeline 1
   ```bash
   vault list identity/entity/id
   # Should see 1 entity
   ```

2. Run Pipeline 2
   ```bash
   vault list identity/entity/id
   # Should still see 1 entity (or 2 if different role)
   ```

3. Run Pipeline 3
   ```bash
   vault list identity/entity/id
   # Should still see 1 entity (or 2-3 depending on bound claims)
   ```

4. Check entity details
   ```bash
   ENTITY_ID=$(vault list -format=json identity/entity/id | jq -r '.[]' | head -1)
   vault read -format=json identity/entity/id/${ENTITY_ID} | jq '.data.aliases'
   # Should see multiple aliases (one per pipeline run)
   ```

## 4.4 Generate Client Count Report

Create a script to analyze client count:

File: `scripts/analyze-clients.sh`

```bash
#!/bin/bash

export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin/azdo-poc"
export VAULT_TOKEN="hvs.your-admin-token"

echo "=========================================="
echo "Vault Client Count Analysis"
echo "=========================================="
echo ""

# Get monthly client count
echo "1. Monthly Client Count:"
vault read -format=json sys/internal/counters/activity/monthly | \
  jq '.data.months[-1] | {month: .timestamp, total_clients: .counts.clients, new_clients: .new_clients.counts.clients}'
echo ""

# List all entities
echo "2. Total Entities (Unique Clients):"
ENTITY_COUNT=$(vault list -format=json identity/entity/id | jq '. | length')
echo "   Total Entities: ${ENTITY_COUNT}"
echo ""

# Detailed entity information
echo "3. Entity Details:"
vault list -format=json identity/entity/id | jq -r '.[]' | while read entity_id; do
  ENTITY_INFO=$(vault read -format=json identity/entity/id/${entity_id})
  
  ENTITY_NAME=$(echo ${ENTITY_INFO} | jq -r '.data.name')
  ALIAS_COUNT=$(echo ${ENTITY_INFO} | jq '.data.aliases | length')
  POLICIES=$(echo ${ENTITY_INFO} | jq -r '.data.policies | join(", ")')
  
  echo "   Entity: ${ENTITY_NAME}"
  echo "   ID: ${entity_id}"
  echo "   Aliases: ${ALIAS_COUNT}"
  echo "   Policies: ${POLICIES}"
  echo "   ---"
done
echo ""

# Breakdown by auth method
echo "4. Breakdown by Auth Method:"
vault read -format=json sys/internal/counters/activity/monthly | \
  jq '.data.months[-1].counts.distinct_entities[] | {mount: .mount_path, count: .counts.clients}'
echo ""

echo "=========================================="
echo "Analysis Complete"
echo "=========================================="
```

Run the script:
```bash
chmod +x scripts/analyze-clients.sh
./scripts/analyze-clients.sh
```

## 4.5 Validate Cost Savings

### Calculate Savings

```bash
# Current monthly cost per client (example: HCP Vault Starter)
COST_PER_CLIENT=0.40  # USD per client per month

# Service Principal approach
SP_COUNT=400
SP_MONTHLY_COST=$(echo "${SP_COUNT} * ${COST_PER_CLIENT}" | bc)

# OIDC approach (estimated)
OIDC_COUNT=15  # 15 entities for different projects/environments
OIDC_MONTHLY_COST=$(echo "${OIDC_COUNT} * ${COST_PER_CLIENT}" | bc)

# Savings
SAVINGS=$(echo "${SP_MONTHLY_COST} - ${OIDC_MONTHLY_COST}" | bc)
SAVINGS_PERCENT=$(echo "scale=2; ${SAVINGS} / ${SP_MONTHLY_COST} * 100" | bc)

echo "Cost Analysis:"
echo "  Service Principal Approach: ${SP_COUNT} clients = \$${SP_MONTHLY_COST}/month"
echo "  OIDC Approach: ${OIDC_COUNT} clients = \$${OIDC_MONTHLY_COST}/month"
echo "  Monthly Savings: \$${SAVINGS}"
echo "  Savings Percentage: ${SAVINGS_PERCENT}%"
```

Expected output:
```
Cost Analysis:
  Service Principal Approach: 400 clients = $160.00/month
  OIDC Approach: 15 clients = $6.00/month
  Monthly Savings: $154.00
  Savings Percentage: 96.25%
```

## 4.6 Test Different Bound Claims Strategies

### Test A: By Managed Identity (Recommended)

```bash
# Create role bound to specific managed identity
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"role_type\": \"jwt\",
       \"bound_audiences\": [\"https://management.core.windows.net/\"],
       \"user_claim\": \"sub\",
       \"token_policies\": [\"dev-secrets-reader\"],
       \"bound_claims\": {
         \"sub\": \"${DEV_MI_PRINCIPAL_ID}\",
         \"appid\": \"${DEV_MI_CLIENT_ID}\",
         \"tid\": \"${AZURE_TENANT_ID}\"
       }
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/role/dev-mi-role

# Result: All pipelines using this managed identity share 1 entity
```

### Test B: By Tenant

```bash
# Create role bound to tenant (less restrictive)
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"role_type\": \"jwt\",
       \"bound_audiences\": [\"https://management.core.windows.net/\"],
       \"user_claim\": \"sub\",
       \"token_policies\": [\"dev-secrets-reader\"],
       \"bound_claims\": {
         \"tid\": \"${AZURE_TENANT_ID}\"
       }
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/role/tenant-role

# Result: All managed identities in this tenant can authenticate
```

### Test C: Combination (MI + Tenant)

```bash
# Create role with multiple bound claims
curl --header "X-Vault-Token: ${VAULT_TOKEN}" \
     --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
     --request POST \
     --data "{
       \"role_type\": \"jwt\",
       \"bound_audiences\": [\"https://management.core.windows.net/\"],
       \"user_claim\": \"sub\",
       \"token_policies\": [\"prod-secrets-reader\"],
       \"bound_claims\": {
         \"sub\": \"${PROD_MI_PRINCIPAL_ID}\",
         \"appid\": \"${PROD_MI_CLIENT_ID}\",
         \"tid\": \"${AZURE_TENANT_ID}\"
       }
     }" \
     ${VAULT_ADDR}/v1/auth/jwt/role/prod-mi-role

# Result: Only pipelines using this specific prod managed identity can authenticate
```

## 4.7 Performance Testing

Run load test to ensure OIDC authentication performs well:

File: `scripts/load-test.sh`

```bash
#!/bin/bash

ITERATIONS=100
SUCCESS=0
FAILED=0
TOTAL_TIME=0

echo "Running ${ITERATIONS} authentication attempts..."

for i in $(seq 1 $ITERATIONS); do
  START=$(date +%s.%N)
  
  # Simulate JWT authentication via curl
  curl --silent --request POST \
    --data "{\"jwt\": \"${JWT_TOKEN}\", \"role\": \"dev-mi-role\"}" \
    ${VAULT_ADDR}/v1/auth/jwt/login > /dev/null 2>&1
  
  if [ $? -eq 0 ]; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  
  END=$(date +%s.%N)
  DURATION=$(echo "$END - $START" | bc)
  TOTAL_TIME=$(echo "$TOTAL_TIME + $DURATION" | bc)
  
  echo -ne "Progress: ${i}/${ITERATIONS} (Success: ${SUCCESS}, Failed: ${FAILED})\r"
done

echo ""
echo "Load Test Results:"
echo "  Total Attempts: ${ITERATIONS}"
echo "  Successful: ${SUCCESS}"
echo "  Failed: ${FAILED}"
echo "  Average Time: $(echo "scale=3; ${TOTAL_TIME} / ${ITERATIONS}" | bc)s"
```

## 4.8 Audit and Compliance

Enable and review audit logs:

```bash
# Enable audit logging
vault audit enable file file_path=/vault/logs/audit.log

# For HCP Vault, audit logs are available in the portal
# Go to: Vault Cluster → Logs → Audit Logs

# Query specific authentication events
vault audit list

# Review authentication patterns
# Look for: auth/jwt/login events
# Analyze: entity_id, aliases, policies assigned
```

## 4.9 Document Results

Create a results document with:

1. **Before & After Comparison**
   - Service Principal count: 400+
   - OIDC entity count: 10-20
   - Client reduction: 95%+

2. **Cost Savings**
   - Monthly savings: $150+
   - Annual savings: $1,800+

3. **Performance Metrics**
   - Authentication time: <2s
   - Success rate: 99%+

4. **Security Benefits**
   - No long-lived credentials
   - JWT tokens expire automatically
   - Fine-grained access via bound claims
   - Centralized policy management

5. **Operational Improvements**
   - Single auth method for all pipelines
   - Easier credential rotation
   - Simplified auditing

## Next Steps

Proceed to [Step 5: Production Recommendations](STEP_5_PRODUCTION.md)
