# Azure DevOps OIDC + HCP Vault POC

A comprehensive POC guide for implementing Azure DevOps OIDC authentication with HCP Vault — eliminating stored credentials, reducing client counts, and centralising secret management.

## Key Approach

- ✅ Uses **Managed Identity** (no app registration needed — works with contributor permissions)
- ✅ **Access tokens** from Azure CLI (authorisation-ready tokens with MI claims)
- ✅ **curl commands only** (no Vault CLI binary required)
- ✅ **JWT auth** with exact claim matching (oid, appid, tid)
- ✅ **Managed-identity-level** granularity (matches Azure auth method)
- ✅ Production-ready implementation

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Azure DevOps Pipeline                                       │
│  - Obtains access token from Azure Entra ID via Azure CLI   │
│  - Token contains claims: oid, appid, sub, tid              │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ HCP Vault - JWT Auth Method                                 │
│  - Validates JWT signature against Entra ID JWKS            │
│  - Matches bound_claims (sub, appid, tid)                   │
│  - Returns Vault token with policies                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Entity/Alias Management                                     │
│  - Multiple pipelines → Same entity (via user_claim: sub)   │
│  - bound_claims control auth success                        │
│  - claim_mappings export oid, appid, tid as metadata        │
│  - 1 entity per managed identity = 1 client (licensing)     │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ KV Secrets Engine                                           │
│  - Read secrets based on policy                             │
│  - Short-lived tokens (30-60 min)                           │
│  - No stored credentials in Azure DevOps                    │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- [ ] Azure subscription with Contributor permissions
- [ ] HCP Vault Dedicated cluster
- [ ] Azure DevOps organisation with a project
- [ ] Azure CLI installed locally
- [ ] Git repository for pipeline code

## Step-by-Step Implementation

| Step | Document | Time | Description |
|------|----------|------|-------------|
| 1 | [Azure DevOps Setup](STEP_1_AZURE_SETUP.md) | 20 min | Configure Azure DevOps organisation and OIDC |
| 2 | [HCP Vault Configuration](STEP_2_VAULT_SETUP.md) | 30 min | Enable JWT auth, create roles & policies |
| 3 | [Pipeline Integration](STEP_3_PIPELINE_INTEGRATION.md) | 45 min | Update pipelines to authenticate with Vault |
| 4 | [Testing & Validation](STEP_4_TESTING.md) | 30 min | Verify client count reduction |
| 5 | [Production Deployment](STEP_5_PRODUCTION.md) | 1 hour | Best practices and rollout strategy |

**Supporting resources:**
- [DIAGRAMS.md](DIAGRAMS.md) — Visual architecture and flow diagrams
- [COMMON_PITFALLS.md](COMMON_PITFALLS.md) — Troubleshooting guide

## Why OIDC over Other Approaches

| Aspect | Service Principals | Azure Auth | AppRole | OIDC/JWT (This Guide) |
|--------|-------------------|------------|---------|-------------------|
| **Credentials** | Long-lived, stored | Managed identity | Secret ID required | Short-lived, auto-generated (JWT) |
| **Rotation** | Manual, complex | Automatic | Manual | Automatic |
| **Client Count** | 1 per pipeline | 1 per identity | 1 per app | Shared via bound claims |
| **Infrastructure** | None extra | Requires Azure VMs/RGs | None extra | None extra |
| **Multi-cloud** | Azure only | Azure only | Cloud-agnostic | Cloud-agnostic |
| **Security Risk** | Credential exposure | Low | Secret exposure | Minimal |

## Bound Claims Strategy

`bound_claims` control authorisation (which pipelines can authenticate), while `user_claim` determines entity consolidation and client licensing.

**Recommended: Managed Identity Consolidation**
```hcl
role_type       = "jwt"
user_claim      = "sub"   # MI principal ID → 1 entity per managed identity
bound_audiences = ["https://management.core.windows.net/"]
bound_claims = {
  sub   = var.managed_identity_principal_id
  appid = var.managed_identity_client_id
  tid   = var.azure_tenant_id
}
claim_mappings = {
  oid   = "managed_identity_oid"
  appid = "managed_identity_client_id"
  tid   = "tenant_id"
}
# Result: All pipelines using this MI share 1 entity
# Multiple roles can target different MIs for environment isolation
```

**Multiple Roles for Environment Isolation:**
```hcl
# Dev role — read-only, bound to dev managed identity
bound_claims = {
  sub   = var.dev_mi_principal_id
  appid = var.dev_mi_client_id
  tid   = var.azure_tenant_id
}
token_policies = ["dev-read-only"]

# Prod role — read/write, bound to prod managed identity
bound_claims = {
  sub   = var.prod_mi_principal_id
  appid = var.prod_mi_client_id
  tid   = var.azure_tenant_id
}
token_policies = ["prod-read-write"]
# Result: 2 entities total (1 per managed identity), different policies per role
```

## Key Benefits

**Security** — Zero stored credentials, automatic token expiration (30-60 min), centralised access control, full audit trail with JWT claims logged as entity metadata.

**Cost** — 98% client count reduction (400 pipelines → 4-8 managed identities), ~$1,800+/year savings, scales without increasing client count.

**Operations** — Single auth method, no credential rotation, easy pipeline onboarding, simplified troubleshooting.

## Repository Structure

```
azdo-oidc-vault/
├── README.md                             # This file
├── DIAGRAMS.md                           # Visual architecture diagrams
├── STEP_1_AZURE_SETUP.md                 # Azure DevOps configuration
├── STEP_2_VAULT_SETUP.md                 # HCP Vault setup & JWT auth
├── STEP_3_PIPELINE_INTEGRATION.md        # Pipeline code updates
├── STEP_4_TESTING.md                     # Validation & client count checks
├── STEP_5_PRODUCTION.md                  # Best practices & rollout
└── COMMON_PITFALLS.md                    # Troubleshooting guide
```

## Success Criteria

- [ ] JWT authentication working with access tokens
- [ ] Secrets retrieved in pipeline via curl
- [ ] Authentication time < 3 seconds
- [ ] 99%+ success rate
- [ ] Client count reduced to 4-8 entities

## Getting Help

1. Check [COMMON_PITFALLS.md](COMMON_PITFALLS.md) for troubleshooting
2. Review the relevant STEP_X guide for section-specific issues
3. HashiCorp Community: https://discuss.hashicorp.com
4. HCP Vault Support: https://support.hashicorp.com (HCP customers)
