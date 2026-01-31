# Architecture Diagrams

## High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Azure DevOps Organization                       │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│  │  Pipeline 1  │  │  Pipeline 2  │  │  Pipeline N  │               │
│  │  (Retail)    │  │  (Banking)   │  │  (Insurance) │               │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘               │
│         │                  │                  │                     │
│         └──────────────────┴──────────────────┘                     │
│                            │                                        │
│                   Generates JWT Token                               │
│                   with Claims:                                      │
│                   - iss: vstoken.dev.azure.com/{org}                │
│                   - sub: sc://{org}/{project}/{id}                  │
│                   - project: {project-name}                         │
│                   - pipeline: {pipeline-name}                       │
│                   - environment: {env}                              │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              │ JWT Token
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       HCP Vault Dedicated                           │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    OIDC Auth Method                           │  │
│  │                                                               │  │
│  │  1. Validate JWT signature                                    │  │
│  │  2. Check issuer (vstoken.dev.azure.com)                      │  │
│  │  3. Match bound_claims                                        │  │
│  │  4. Return Vault token                                        │  │
│  └──────────────────────────┬────────────────────────────────────┘  │
│                             │                                       │
│         ┌───────────────────┴───────────────────┐                   │
│         │                                       │                   │
│         ▼                                       ▼                   │
│  ┌─────────────┐                        ┌─────────────┐             │
│  │ Role: retail│                        │ Role: banking│            │
│  │ bound_claims│                        │ bound_claims│             │
│  │ project=ret*│                        │ project=bank*│        │
│  │             │                        │             │         │
│  │ Policies:   │                        │ Policies:   │         │
│  │ - retail-r  │                        │ - banking-r │         │
│  └──────┬──────┘                        └──────┬──────┘         │
│         │                                       │                │
│         └───────────────────┬───────────────────┘                │
│                             │                                     │
│                             ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Identity - Entity Management               │    │
│  │                                                          │    │
│  │  Entity 1 (Retail Pipelines)                            │    │
│  │  ├── Alias 1: Pipeline 1 (sub: sc://org/retail/p1)     │    │
│  │  ├── Alias 2: Pipeline 2 (sub: sc://org/retail/p2)     │    │
│  │  └── Alias N: Pipeline N (sub: sc://org/retail/pN)     │    │
│  │                                                          │    │
│  │  Entity 2 (Banking Pipelines)                           │    │
│  │  ├── Alias 1: Pipeline X (sub: sc://org/banking/p1)    │    │
│  │  └── Alias 2: Pipeline Y (sub: sc://org/banking/p2)    │    │
│  │                                                          │    │
│  │  Client Count = Number of Entities (2 in this example)  │    │
│  └──────────────────────────┬───────────────────────────────┘    │
│                             │                                     │
│                             ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │               KV Secrets Engine (v2)                    │    │
│  │                                                          │    │
│  │  secret/                                                │    │
│  │  ├── retail/                                            │    │
│  │  │   ├── app-config                                     │    │
│  │  │   └── db-credentials                                 │    │
│  │  ├── banking/                                           │    │
│  │  │   ├── app-config                                     │    │
│  │  │   └── api-keys                                       │    │
│  │  └── shared/                                            │    │
│  │      └── common-config                                  │    │
│  └─────────────────────────────────────────────────────────┘    │
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

### OIDC Approach (Bound Claims)

```
┌──────────────────────────────────────────────────────────────┐
│ OIDC Authentication with Bound Claims                        │
└──────────────────────────────────────────────────────────────┘

Pipelines 1-100   (project: retail)     → OIDC Role → Entity 1 → Client 1
Pipelines 101-200 (project: banking)    → OIDC Role → Entity 2 → Client 2
Pipelines 201-300 (project: insurance)  → OIDC Role → Entity 3 → Client 3
Pipelines 301-350 (project: infra)      → OIDC Role → Entity 4 → Client 4
Pipelines 351-400 (project: platform)   → OIDC Role → Entity 5 → Client 5

Additional segmentation by environment:
├── Entity 6: Dev environment pipelines
├── Entity 7: Staging environment pipelines
└── Entity 8: Prod environment pipelines

┌──────────────────────────────────────────────────────────────┐
│ Result: 400 Pipelines = 8-15 Clients                         │
│ Cost: 15 × $0.40/month = $6/month                            │
│ Savings: $154/month ($1,848/year)                            │
│ Reduction: 96.25%                                            │
│ Management: 0 credentials (JWT auto-generated)               │
└──────────────────────────────────────────────────────────────┘
```

## Authentication Flow Sequence

```
┌─────────┐         ┌──────────┐        ┌───────────┐        ┌────────┐
│  AZDO   │         │  Azure   │        │    HCP    │        │   KV   │
│Pipeline │         │    AD    │        │   Vault   │        │Engine  │
└────┬────┘         └────┬─────┘        └─────┬─────┘        └───┬────┘
     │                   │                    │                   │
     │ 1. Request Token  │                    │                   │
     ├──────────────────>│                    │                   │
     │                   │                    │                   │
     │ 2. JWT Token      │                    │                   │
     │   (with claims)   │                    │                   │
     │<──────────────────┤                    │                   │
     │                   │                    │                   │
     │ 3. Auth to Vault with JWT              │                   │
     ├───────────────────────────────────────>│                   │
     │                   │                    │                   │
     │                   │  4. Validate JWT   │                   │
     │                   │<───────────────────┤                   │
     │                   │                    │                   │
     │                   │  5. JWT Valid      │                   │
     │                   │───────────────────>│                   │
     │                   │                    │                   │
     │                   │          6. Check bound_claims         │
     │                   │          7. Create/Update Entity       │
     │                   │          8. Create Alias               │
     │                   │                    │                   │
     │ 9. Vault Token (with policies)         │                   │
     │<───────────────────────────────────────┤                   │
     │                   │                    │                   │
     │ 10. Read Secret                        │                   │
     ├────────────────────────────────────────┼──────────────────>│
     │                   │                    │                   │
     │ 11. Secret Data                        │                   │
     │<───────────────────────────────────────┼───────────────────┤
     │                   │                    │                   │
     │ 12. Deploy with Secret                 │                   │
     │                   │                    │                   │

Token TTL: 30-60 minutes
Auto-expires: Yes
```

## Entity and Alias Relationship

```
┌─────────────────────────────────────────────────────────────────┐
│                        Vault Entities                           │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Entity 1: "retail-pipelines"                            │    │
│  │ ID: entity-uuid-1234                                    │    │
│  │ Policies: [retail-read, shared-read]                    │    │
│  │                                                          │    │
│  │ Aliases (Multiple pipelines → Same entity):             │    │
│  │ ┌──────────────────────────────────────────────────┐   │    │
│  │ │ Alias 1:                                         │   │    │
│  │ │   Name: sc://org/retail/pipeline-web            │   │    │
│  │ │   Auth Method: oidc/                             │   │    │
│  │ │   Created: 2025-11-01                            │   │    │
│  │ └──────────────────────────────────────────────────┘   │    │
│  │ ┌──────────────────────────────────────────────────┐   │    │
│  │ │ Alias 2:                                         │   │    │
│  │ │   Name: sc://org/retail/pipeline-api            │   │    │
│  │ │   Auth Method: oidc/                             │   │    │
│  │ │   Created: 2025-11-02                            │   │    │
│  │ └──────────────────────────────────────────────────┘   │    │
│  │ ┌──────────────────────────────────────────────────┐   │    │
│  │ │ Alias N:                                         │   │    │
│  │ │   Name: sc://org/retail/pipeline-batch          │   │    │
│  │ │   Auth Method: oidc/                             │   │    │
│  │ │   Created: 2025-11-03                            │   │    │
│  │ └──────────────────────────────────────────────────┘   │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  Key Concept: Multiple aliases → 1 entity → 1 client           │
└─────────────────────────────────────────────────────────────────┘
```

## Bound Claims Matching Logic

```
┌──────────────────────────────────────────────────────────────────┐
│ Incoming JWT Token Claims                                        │
├──────────────────────────────────────────────────────────────────┤
│ {                                                                │
│   "iss": "https://vstoken.dev.azure.com/abc-123",                │
│   "sub": "sc://myorg/retail-project/pipeline-web",               │
│   "aud": "api://AzureADTokenExchange",                           │
│   "project": "retail-project",                                   │
│   "pipeline": "pipeline-web",                                    │
│   "environment": "production"                                    │
│ }                                                                │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ Vault OIDC Role Configuration                                    │
├──────────────────────────────────────────────────────────────────┤
│ Role: retail-production                                          │
│                                                                  │
│ bound_audiences: ["api://AzureADTokenExchange"]  ✓ MATCH         │
│ bound_claims_type: "glob"                                        │
│ bound_claims: {                                                  │
│   "project": "retail-*"                         ✓ MATCH          │
│   "environment": "production"                   ✓ MATCH          │
│ }                                                                │
│                                                                  │
│ Result: AUTHENTICATED → Entity "retail-prod" → Client 1          │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ Key Insight: All pipelines matching these bound_claims           │
│              will share the SAME entity                          │
│              → Massive client count reduction!                   │
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

OIDC with Bound Claims:
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
 50│                            ●────────────●
  │              ●──────────────●
  0│──────●──────●
     0   100   200   300   400   500
                 Pipelines

Savings increase with scale!
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
     │ │    Savings Area: $154/month                         │
$100 │ │    Annual: $1,848                                   │
     │ │                                                      │
 $80 │ │                                                      │
     │ │                                                      │
 $60 │ │                                                      │
     │ │                                                      │
 $40 │ │                                                      │
     │ │                                                      │
 $20 │ │                                                      │
     │ └─────────────────────────────────────────────────────┘
  $0 │ ●──●──●──●──●──●──●──●──●──●──●──●  ← OIDC ($6/month)
     └─┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──
       1  2  3  4  5  6  7  8  9 10 11 12  Months

Break-even: Month 1 (immediate savings)
ROI: Infinite (no additional cost, only savings)
```
