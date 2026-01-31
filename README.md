# Azure DevOps OIDC + HCP Vault POC

## 🎯 Overview

This POC demonstrates how to **reduce Vault client count by 85-95%** using Azure DevOps with **Entra ID JWT authentication** (managed identity, no app registration) instead of service principals.

**Problem**: 400+ service principals = 400+ Vault clients = High HCP Vault costs  
**Solution**: JWT auth with bound claims = 10-20 entities = **$1,800+/year savings**

### ✅ Correct Approach (Updated)

**Important**: This documentation uses the **correct production-ready approach**:

1. ✅ **JWT Auth** (NOT OIDC with `oidc_client_id`) - See [CORRECTED_APPROACH.md](CORRECTED_APPROACH.md)
2. ✅ **Managed Identity** (no app registration needed - works with contributor permissions)
3. ✅ **Entra ID OAuth** (Microsoft is sunsetting Azure DevOps OAuth)
4. ✅ **JWT tokens from pipeline** (NOT System.AccessToken or AppRole)
5. ✅ **curl commands only** (no Vault CLI binary required)

**Read [CORRECTED_APPROACH.md](CORRECTED_APPROACH.md) first** to understand the critical fixes!

## 🚀 Quick Start

**Want to get started immediately?** → **Read [GET_STARTED.md](GET_STARTED.md) then follow [STEP_1](STEP_1_AZURE_SETUP.md) through [STEP_5](STEP_5_PRODUCTION.md)**

**Key Approach**:
- ✅ Uses **Managed Identity** (no app registration needed - works with contributor permissions)
- ✅ **Entra ID JWT tokens** (Microsoft is sunsetting Azure DevOps OAuth)
- ✅ **curl commands only** (no Vault CLI binary required)
- ✅ **JWT auth** with `oidc_discovery_url` (correct Vault configuration)
- ✅ Production-ready implementation

## 📋 Table of Contents

1. [Executive Summary](EXECUTIVE_SUMMARY.md) - Business case and feasibility assessment
2. [Get Started](GET_STARTED.md) - Implementation roadmap
3. [Step-by-Step Guides](#step-by-step-implementation)
4. [Common Pitfalls](COMMON_PITFALLS.md) - Troubleshooting guide
5. [Sample Code](SAMPLES.md) - Reusable templates and scripts

## 📐 Architecture

```
Azure DevOps Pipeline (JWT Token)
    ↓
OIDC Auth Method (HCP Vault)
    ↓
Bound Claims Validation
    ↓
Entity/Alias Creation
    ↓
Policy Assignment
    ↓
KV Secrets Access
```

## ✅ Prerequisites

- [x] Azure subscription (available)
- [x] HCP Vault Dedicated cluster (can spin up)
- [ ] Azure DevOps organization
- [ ] Azure CLI installed locally
- [ ] Vault CLI installed locally
- [ ] Git repository for pipeline code

## 💡 Client Count Reduction Strategy

### Current: Service Principal Approach
```
Service Principal 1 → Vault Entity 1 (Client 1)
Service Principal 2 → Vault Entity 2 (Client 2)
...
Service Principal 400 → Vault Entity 400 (Client 400)
```

### Target: OIDC with Bound Claims
```
OIDC Auth Method
├── Role: dev-pipelines (bound to project:dev)
│   ├── Pipeline 1 → Entity A (shared)
│   ├── Pipeline 2 → Entity A (shared)
│   └── Pipeline N → Entity A (shared)
├── Role: prod-pipelines (bound to project:prod)
│   ├── Pipeline X → Entity B (shared)
│   └── Pipeline Y → Entity B (shared)
└── Role: infra-pipelines (bound to project:infra)
    └── Pipeline Z → Entity C (shared)
```

**Result**: 400 pipelines → 3-15 entities = **85-97.5% reduction**

## 📚 Step-by-Step Implementation

| Step | Document | Time | Description |
|------|----------|------|-------------|
| 1 | [Azure DevOps Setup](STEP_1_AZURE_SETUP.md) | 20 min | Configure AZDO organization and OIDC |
| 2 | [HCP Vault Configuration](STEP_2_VAULT_SETUP.md) | 30 min | Enable OIDC auth, create roles & policies |
| 3 | [Pipeline Integration](STEP_3_PIPELINE_INTEGRATION.md) | 45 min | Update pipelines to use Vault |
| 4 | [Testing & Validation](STEP_4_TESTING.md) | 30 min | Verify client count reduction |
| 5 | [Production Deployment](STEP_5_PRODUCTION.md) | 1 hour | Best practices and rollout strategy |

**Total Time**: ~3 hours for complete POC

## 💰 Cost Comparison

| Approach | Vault Clients | Monthly Cost | Annual Cost | Savings |
|----------|---------------|--------------|-------------|---------|
| **Service Principals** | 400 | $160 | $1,920 | Baseline |
| **OIDC (Conservative)** | 50 | $20 | $240 | $1,680/year |
| **OIDC (Optimized)** | 20 | $8 | $96 | $1,824/year |
| **OIDC (Aggressive)** | 10 | $4 | $48 | $1,872/year |

*Based on $0.40/client/month for HCP Vault*

## 🎁 What's Included

```
azdo-oidc-vault/
├── README.md                          # This file - START HERE
├── CORRECTED_APPROACH.md              # CRITICAL - Read this first!
├── GET_STARTED.md                     # Implementation roadmap
├── INDEX.md                           # Navigation guide
├── EXECUTIVE_SUMMARY.md               # Business case and ROI
├── DIAGRAMS.md                        # Visual architecture
├── STEP_1_AZURE_SETUP.md             # Azure DevOps + Managed Identity
├── STEP_2_VAULT_SETUP.md             # HCP Vault + JWT auth (curl)
├── STEP_3_PIPELINE_INTEGRATION.md    # Pipeline with Entra JWT
├── STEP_4_TESTING.md                 # Validation procedures
├── STEP_5_PRODUCTION.md              # Production best practices
├── COMMON_PITFALLS.md                # Troubleshooting guide
├── SAMPLES.md                         # Code templates documentation
└── samples/
    ├── pipelines/                     # Azure DevOps pipeline templates
    │   └── basic-vault-integration.yml  # Working example (curl-based)
    ├── scripts/                       # (deprecated - using curl now)
    └── terraform/                     # Terraform for Vault config
```

## ✨ Key Benefits

### 🔒 Security
- ✅ No long-lived credentials
- ✅ Automatic token expiration (30-60 min)
- ✅ Centralized access control
- ✅ Full audit trail

### 💸 Cost
- ✅ 85-95% client count reduction
- ✅ $1,800+/year savings
- ✅ Scales with growth

### ⚙️ Operations
- ✅ Single auth method
- ✅ No credential management
- ✅ Easy pipeline onboarding
- ✅ Simplified troubleshooting

## 🎯 Success Criteria

- [ ] OIDC authentication working
- [ ] Secrets retrieved in pipeline
- [ ] Client count reduced by 85%+
- [ ] Authentication time < 3 seconds
- [ ] 99%+ success rate

## 📊 Recommended Path

### Start Here (Required Reading - 15 minutes)
1. **[CORRECTED_APPROACH.md](CORRECTED_APPROACH.md)** - Understand the critical fixes
2. **[GET_STARTED.md](GET_STARTED.md)** - Implementation roadmap

### For Production Implementation (4-6 hours)
1. [EXECUTIVE_SUMMARY.md](EXECUTIVE_SUMMARY.md) (get buy-in)
2. [STEP_1_AZURE_SETUP.md](STEP_1_AZURE_SETUP.md) → [STEP_5_PRODUCTION.md](STEP_5_PRODUCTION.md) (detailed implementation)
3. [samples/pipelines/basic-vault-integration.yml](samples/pipelines/basic-vault-integration.yml) (working example)
4. [COMMON_PITFALLS.md](COMMON_PITFALLS.md) (reference during rollout)

## 🆘 Troubleshooting

Having issues? Check [COMMON_PITFALLS.md](COMMON_PITFALLS.md) for solutions to:
- OIDC token access in Azure DevOps
- Bound claims not matching
- Client count not reducing
- Token expiration issues
- And more...

## 📞 Support

- **HashiCorp Learn**: https://learn.hashicorp.com/vault
- **Community Forum**: https://discuss.hashicorp.com
- **HCP Support**: For HCP Vault Dedicated customers
- **Azure DevOps Docs**: https://learn.microsoft.com/azure/devops

## 🎓 Additional Resources

- [Vault OIDC Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Azure DevOps Workload Identity](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure)
- [HCP Vault Client Count](https://developer.hashicorp.com/vault/tutorials/monitoring/usage-metrics)

## 🤝 Contributing

This POC is designed to be customized for your specific environment. Feel free to adapt the templates and scripts to match your organization's requirements.

---

**Ready to start?** → **[Jump to Quick Start](QUICKSTART.md)** 🚀

**Document Version**: 1.0  
**Last Updated**: November 2025  
**Status**: Ready for Implementation

