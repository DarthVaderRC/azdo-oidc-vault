# Architecture Diagrams - Access Token Based Authentication

## High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Azure DevOps Organization                       │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│  │  Pipeline 1  │  │  Pipeline 2  │  │  Pipeline N  │               │
│  │  (Dev)       │  │  (Staging)   │  │  (Prod)      │               │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘               │
│         │                  │                  │                     │
│         └──────────────────┴──────────────────┘                     │
│                            │                                        │
│                            ▼                                        │
│              ┌─────────────────────────────┐                        │
│              │  Azure Service Connection   │                        │
│              │  (Managed Identity)         │                        │
│              └──────────────┬──────────────┘                        │
│                            │                                        │
│         Generates Access Token (via Azure CLI)                      │
│         with Claims:                                                │
│         - iss: https://sts.windows.net/{tenant-id}/                 │
│         - aud: https://management.core.windows.net/                 │
│         - appid: {managed-identity-client-id}                       │
│         - oid: {managed-identity-principal-id}                      │
│         - sub: {managed-identity-principal-id}                      │
│         - tid: {tenant-id}                                          │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              │ Access Token (JWT)
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       HCP Vault Dedicated                           │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    JWT Auth Method                            │  │
│  │                                                               │  │
│  │  1. Validate JWT signature against Entra ID JWKS              │  │
│  │  2. Check issuer (sts.windows.net/{tenant}/)                  │  │
│  │  3. Match bound_audiences (management.core.windows.net)       │  │
│  │  4. Verify bound_claims (oid, appid, tid)                     │  │
│  │  5. Return Vault token with policies                          │  │
│  └──────────────────────────┬────────────────────────────────────┘  │
│                             │                                       │
│         ┌───────────────────┴───────────────────┐                   │
│         │                                       │                   │
│         ▼                                       ▼                   │
│  ┌─────────────┐                        ┌─────────────┐             │
│  │ Role: dev-  │                        │ Role: prod- │             │
│  │ pipelines   │                        │ pipelines   │             │
│  │ bound_claims│                        │ bound_claims│             │
│  │ oid={dev-mi}│                        │ oid={prod-mi}│            │
│  │ appid={dev} │                        │ appid={prod} │            │
│  │ Policies:   │                        │ Policies:   │              │
│  │ - dev-read  │                        │ - prod-read │              │
│  └──────┬──────┘                        └──────┬──────┘              │
│         │                                       │                   │
│         └───────────────────┬───────────────────┘                   │
│                             │                                       │
│                             ▼                                       │
│  ┌─────────────────────────────────────────────────────────┐      │
│  │              Identity - Entity Management               │      │
│  │                                                          │      │
│  │  Entity 1 (Dev Managed Identity)                        │      │
│  │  ├── Alias 1: oid={dev-managed-identity-principal-id}  │      │
│  │  │   All dev pipelines share this identity             │      │
│  │  │   Note: Managed-identity-level authorization        │      │
│  │                                                          │      │
│  │  Entity 2 (Prod Managed Identity)                       │      │
│  │  ├── Alias 1: oid={prod-managed-identity-principal-id} │      │
│  │  │   All prod pipelines share this identity            │      │
│  │                                                          │      │
│  │  Client Count = Number of Managed Identities (2)        │      │
│  └──────────────────────────┬───────────────────────────────┘      │
│                             │                                       │
│                             ▼                                       │
│  ┌─────────────────────────────────────────────────────────┐      │
│  │               KV Secrets Engine (v2)                    │      │
│  │                                                          │      │
│  │  secret/                                                │      │
│  │  ├── dev/                                               │      │
│  │  │   ├── app-config                                     │      │
│  │  │   └── db-credentials                                 │      │
│  │  ├── prod/                                              │      │
│  │  │   ├── app-config                                     │      │
│  │  │   └── api-keys                                       │      │
│  │  └── shared/                                            │      │
│  │      └── common-config                                  │      │
│  └─────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────┘
```

## Client Count Comparison

### Traditional Approach (Service Principals)

```
┌──────────────────────────────────────────────────────────────┐
│ Service Principal Authentication                             │
└──────────────────────────────────────────────────────────────┘

Pipeline 1 → SP-1 (Client ID + Secret) → Vault Entity 1 → Client 1
Pipeline 2 → SP-2 (Client ID + Secret) → Vault Entity 2 → Client 2
Pipeline 3 → SP-3 (Client ID + Secret) → Vault Entity 3 → Client 3
   ...
Pipeline 400 → SP-400 (Client ID + Secret) → Vault Entity 400 → Client 400

┌──────────────────────────────────────────────────────────────┐
│ Result: 400 Pipelines = 400 Clients                          │
│ Cost: 400 × $0.40/month = $160/month                         │
│ Management: 400 credentials to rotate                        │
└──────────────────────────────────────────────────────────────┘
```

### OIDC Approach with Access Tokens (Managed Identity)

```
┌──────────────────────────────────────────────────────────────┐
│ JWT/OIDC Authentication with Managed Identity Authorization  │
└──────────────────────────────────────────────────────────────┘

Pipelines 1-100   (dev-managed-identity)   → JWT Role → Entity 1 → Client 1
Pipelines 101-200 (staging-managed-id)     → JWT Role → Entity 2 → Client 2
Pipelines 201-350 (prod-managed-identity)  → JWT Role → Entity 3 → Client 3
Pipelines 351-400 (platform-shared-mi)     → JWT Role → Entity 4 → Client 4

Key: Managed Identity determines entity
├── Entity = Unique managed identity (oid + appid)
├── Multiple pipelines → Same managed identity → Same entity
├── Multiple service connections → Same managed identity → Same entity
└── Granularity: Managed-identity-level (not service-connection-level)

┌──────────────────────────────────────────────────────────────┐
│ Result: 400 Pipelines = 4-8 Clients                          │
│ Cost: 8 × $0.40/month = $3.20/month                          │
│ Savings: $156.80/month ($1,881.60/year)                      │
│ Reduction: 98%                                               │
│ Management: 0 credentials (access tokens auto-generated)     │
│ Granularity: Same as Azure auth method                       │
└──────────────────────────────────────────────────────────────┘
```

## Authentication Flow Sequence

```
┌─────────┐         ┌──────────┐        ┌───────────┐        ┌────────┐
│  AZDO   │         │  Azure   │        │    HCP    │        │   KV   │
│Pipeline │         │   CLI    │        │   Vault   │        │Engine  │
└────┬────┘         └────┬─────┘        └─────┬─────┘        └───┬────┘
     │                   │                    │                   │
     │ 1. Run az account get-access-token     │                   │
     ├──────────────────>│                    │                   │
     │                   │                    │                   │
     │ 2. Access Token   │                    │                   │
     │   (with MI claims)│                    │                   │
     │<──────────────────┤                    │                   │
     │                   │                    │                   │
     │ 3. Auth to Vault with Access Token     │                   │
     ├───────────────────────────────────────>│                   │
     │                   │                    │                   │
     │                   │  4. Validate JWT   │                   │
     │                   │     - Verify signature (JWKS)          │
     │                   │     - Check issuer (sts.windows.net)   │
     │                   │     - Verify audience                  │
     │                   │     - Match bound_claims (oid, appid)  │
     │                   │                    │                   │
     │                   │          5. Create/Update Entity       │
     │                   │          6. Create Alias (oid-based)   │
     │                   │          7. Attach Policies            │
     │                   │                    │                   │
     │ 8. Vault Token (with policies)         │                   │
     │<───────────────────────────────────────┤                   │
     │                   │                    │                   │
     │ 9. Read Secret                         │                   │
     ├────────────────────────────────────────┼──────────────────>│
     │                   │                    │                   │
     │ 10. Secret Data                        │                   │
     │<───────────────────────────────────────┼───────────────────┤
     │                   │                    │                   │
     │ 11. Deploy with Secret                 │                   │
     │                   │                    │                   │

Token TTL: 30-60 minutes
Auto-expires: Yes
Granularity: Managed-identity-level (matches Azure auth method)
```

## Entity and Alias Relationship

```
┌─────────────────────────────────────────────────────────────────┐
│                        Vault Entities                           │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Entity 1: "retail-dev-sc"                               │    │
│  │ ID: entity-uuid-1234                                    │    │
│  │ Policies: [retail-read, shared-read]                    │    │
│  │                                                          │    │
│  │ Metadata:                                                │    │
│  │  managed_identity_oid: aaa-bbb-ccc-ddd-eee              │    │
│  │  managed_identity_client_id: fff-ggg-hhh-iii-jjj        │    │
│  │  tenant_id: tenant-guid                                  │    │
│  │                                                          │    │
│  │ Alias: Managed Identity (NOT service connection)        │    │
│  │ ┌──────────────────────────────────────────────────┐   │    │
│  │ │ Alias 1:                                         │   │    │
│  │ │   Name: aaa-bbb-ccc-ddd-eee (MI oid)            │   │    │
│  │ │   Auth Method: jwt/                              │   │    │
│  │ │   Created: 2025-11-01                            │   │    │
│  │ │                                                  │   │    │
│  │ │   Used by (via dev-managed-identity):           │   │    │
│  │ │   - retail-dev-sc (service connection)          │   │    │
│  │ │     ├─ retail-web-pipeline (100 runs)           │   │    │
│  │ │     ├─ retail-api-pipeline (250 runs)           │   │    │
│  │ │     └─ retail-batch-pipeline (50 runs)          │   │    │
│  │ │   - banking-dev-sc (service connection)         │   │    │
│  │ │     ├─ banking-core-pipeline (300 runs)         │   │    │
│  │ │     └─ banking-api-pipeline (150 runs)          │   │    │
│  │ │   All share this ONE managed identity entity    │   │    │
│  │ └──────────────────────────────────────────────────┘   │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Entity 2: "prod-managed-identity"                       │    │
│  │ ID: entity-uuid-5678                                    │    │
│  │ Policies: [prod-read, prod-write]                       │    │
│  │                                                          │    │
│  │ Metadata:                                                │    │
│  │  managed_identity_oid: zzz-yyy-xxx-www-vvv              │    │
│  │  managed_identity_client_id: uuu-ttt-sss-rrr-qqq        │    │
│  │  tenant_id: tenant-guid                                  │    │
│  │                                                          │    │
│  │ Alias: Managed Identity                                  │    │
│  │ ┌──────────────────────────────────────────────────┐   │    │
│  │ │ Alias 1:                                         │   │    │
│  │ │   Name: zzz-yyy-xxx-www-vvv (MI oid)            │   │    │
│  │ │   Auth Method: jwt/                              │   │    │
│  │ │   Created: 2025-11-02                            │   │    │
│  │ │                                                  │   │    │
│  │ │   Used by (via prod-managed-identity):          │   │    │
│  │ │   - retail-prod-sc (service connection)         │   │    │
│  │ │     ├─ retail-deploy-pipeline (200 runs)        │   │    │
│  │ │     └─ retail-rollback-pipeline (50 runs)       │   │    │
│  │ │   - banking-prod-sc (service connection)        │   │    │
│  │ │     ├─ banking-core-pipeline (500 runs)         │   │    │
│  │ │     └─ banking-api-pipeline (300 runs)          │   │    │
│  │ │   All share this ONE managed identity entity    │   │    │
│  │ └──────────────────────────────────────────────────┘   │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  Key Concept: One alias per managed identity                   │
│               Multiple service connections → 1 MI →            │
│               Multiple pipelines → 1 entity → 1 client          │
│               Granularity: Managed-identity-level               │
└─────────────────────────────────────────────────────────────────┘
```

## Bound Claims Matching Logic

```
┌──────────────────────────────────────────────────────────────────┐
│ Incoming Access Token Claims (from Azure Resource Manager)       │
├──────────────────────────────────────────────────────────────────┤
│ {                                                                │
│   "iss": "https://sts.windows.net/abc123.../",                   │
│   "aud": "https://management.core.windows.net/",                 │
│   "sub": "aaa-bbb-ccc-ddd-eee",      // MI Principal ID          │
│   "oid": "aaa-bbb-ccc-ddd-eee",      // Same as sub              │
│   "appid": "fff-ggg-hhh-iii-jjj",    // MI Client ID             │
│   "tid": "abc123-def4-5678-9012-345678901234"                    │
│ }                                                                │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ Vault JWT Role Configuration                                     │
├──────────────────────────────────────────────────────────────────┤
│ Role: dev-mi-role                                                │
│                                                                  │
│ bound_audiences:                                                 │
│   ["https://management.core.windows.net/"]      ✓ MATCH          │
│                                                                  │
│ bound_claims: {                                                  │
│   "sub": "aaa-bbb-ccc-ddd-eee",      // MI Principal ID exact    │
│   "appid": "fff-ggg-hhh-iii-jjj",    // MI Client ID exact       │
│   "tid": "abc123-def4-5678-9012-345678901234"   // Tenant ID     │
│ }                                        ✓ ALL MATCH              │
│                                                                  │
│ claim_mappings: {                                                │
│   "oid": "managed_identity_oid",                                 │
│   "appid": "managed_identity_client_id",                         │
│   "tid": "tenant_id"                                             │
│ }                                                                │
│                                                                  │
│ Result: AUTHENTICATED → Entity "dev-managed-identity" → Client 1 │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ Key Insight: All pipelines & service connections using the       │
│              SAME managed identity will share the SAME entity    │
│              → Massive client count reduction!                   │
│              → Managed-identity-level authorization              │
│              → Matches Azure auth method granularity             │
│              → No glob patterns - exact claim matches only       │
└──────────────────────────────────────────────────────────────────┘
```

## Scalability Model

```
Number of Pipelines vs Clients

Service Principals:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Clients
  │
500│                                          ●
  │                                      ●
400│                                  ●
  │                              ●
300│                          ●
  │                      ●
200│                  ●
  │              ●
100│          ●
  │      ●
  0│──────┬──────┬──────┬──────┬──────┬──────
     0   100   200   300   400   500
                 Pipelines

OIDC with Managed Identity Access Tokens:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Clients
  │
500│
  │
400│
  │
300│
  │
200│
  │
100│
  │
 50│
  │
 20│
  │              ●────────────────────────────●
  0│──────●──────●
     0   100   200   300   400   500
                 Pipelines

Managed-identity-level granularity:
- 4-8 managed identities support 500 pipelines
- Client count = Number of managed identities (not service connections)
- Same granularity as Azure auth method
- Savings increase dramatically with scale!
```

## Cost Analysis Timeline

```
Monthly Cost Comparison Over 12 Months

$200 │
     │ ┌─────────────────────────────────────────────────────┐
$180 │ │  Service Principals: $160/month (constant)          │
     │ │                                                      │
$160 │ ●──●──●──●──●──●──●──●──●──●──●──●  ← Service Principals
     │ │                                                      │
$140 │ │                                                      │
     │ │                                                      │
$120 │ │                                                      │
     │ │    Savings Area: $156.80/month                      │
$100 │ │    Annual: $1,881.60                                │
     │ │                                                      │
 $80 │ │    Using Managed Identity Access Tokens             │
     │ │    4-8 managed identities for 400 pipelines         │
 $60 │ │    Granularity: Managed-identity-level              │
     │ │                                                      │
 $40 │ │                                                      │
     │ │                                                      │
 $20 │ │                                                      │
     │ └─────────────────────────────────────────────────────┘
  $0 │ ●──●──●──●──●──●──●──●──●──●──●──●  ← OIDC ($3.20/month)
     └─┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──
       1  2  3  4  5  6  7  8  9 10 11 12  Months

Break-even: Month 1 (immediate savings)
ROI: Infinite (no additional cost, only savings)
Reduction: 98% (from 400 clients to 8 clients)
```

---

## Detailed Authentication Flow Sequence Diagram

```
┌───────────────────────┐  ┌─────────────────────────────┐  ┌───────────────────────┐  ┌──────────────────────┐
│ Azure DevOps Pipeline │  │ Microsoft Identity Platform │  │ Vault JWT Auth Method │  │ Vault Secrets Engine │
└───────────┬───────────┘  └──────────────┬──────────────┘  └───────────┬───────────┘  └──────────┬───────────┘
            │                             │                             │                         │
            │ 1. Pipeline Starts          │                             │                         │
            │                             │                             │                         │
            │ 2. Get access token         │                             │                         │
            ├────────────────────────────>│                             │                         │
            │                             │                             │                         │
            │ 3. Return Access Token (JWT)│                             │                         │
            │<────────────────────────────┤                             │                         │
            │                             │                             │                         │
            │ 4. Auth to Vault with Access Token & vault role           │                         │
            ├──────────────────────────────────────────────────────────>│                         │
            │                             │                             │                         │
            │                             │  5. Fetch OIDC discovery & JWKS                       │
            │                             │<───────────────────────────>│                         │
            │                             │                             │                         │
            │                             │                             │ 6. Validate JWT         │
            │                             │                             │    - Verify signature (JWKS)
            │                             │                             │    - Check issuer       │
            │                             │                             │    - Check aud          │
            │                             │                             │                         │
            │                             │                             │ 7. Authorization        │
            │                             │                             │    - Match bound_claims │
            │                             │                             │    - Lookup/create entity
            │                             │                             │    - Attach metadata    │
            │                             │                             │    - Attach policies    │
            │                             │                             │                         │
            │                             │                             │ 8. Generate Vault Token │
            │                             │                             │                         │
            │ 9. Return Vault Token       │                             │                         │
            │<──────────────────────────────────────────────────────────│                         │
            │                             │                             │                         │
            │ 10. Read Secret from Vault  │                             │                         │
            ├────────────────────────────────────────────────────────────────────────────────────>│
            │                             │                             │                         │
            │ 11. Return Secret Data      │                             │                         │
            │<────────────────────────────────────────────────────────────────────────────────────┤
            │                             │                             │                         │
            │ 12. Use secrets in deployment                             │                         │
            │                             │                             │                         │

```

### Critical Flow Differences from Traditional Auth

| Step | Traditional (Service Principal) | OIDC (Access Token + MI) |
|------|--------------------------------|--------------------------|
| **Setup** | Create SP, store client secret in Azure DevOps variable | Configure service connection with managed identity & federated credential |
| **Authentication** | Use static client_id + client_secret | Request temporary access token via Azure CLI |
| **Token Lifetime** | Client secret valid for months/years | Access token valid for 30-60 minutes |
| **Identity** | Service principal (persistent) | Managed identity (persistent, cloud-native) |
| **Rotation** | Manual secret rotation required | No secrets to rotate |
| **Vault Entity** | One per pipeline | One per managed identity (shared across pipelines & service connections) |
| **Claims** | None (uses client_id only) | MI claims: oid (principal ID), appid (client ID), tid (tenant ID) |
| **Issuer** | N/A | sts.windows.net/{tenant}/ |
| **Audience** | N/A | https://management.core.windows.net/ |
| **Granularity** | Pipeline-level | Managed-identity-level (same as Azure auth method) |
```
