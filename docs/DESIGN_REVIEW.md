# Design review: why the guidance in this repository changed

**Reviewed:** 11 to 16 September 2026.
**Subject:** the earlier version of this repository, which showed Azure DevOps pipelines authenticating to Vault with an Azure Resource Manager access token.
**Requirement under test:** move from long-standing, pipeline-wide service principal privileges to a zero standing privileges model, with just-in-time access granted at the task level rather than for the whole pipeline.

This is the report that led to the rewrite. The earlier design proved credential-free authentication, which is real and worth having, but it did not demonstrate zero standing privileges, and on task-level scoping it demonstrated the opposite of what was asked. The findings below explain why, and what replaced it.

What the review settled, and what the current build implements:

| Decision | Outcome |
|---|---|
| Token path | Vault trusts the Microsoft Entra issuer, not the retiring Azure DevOps one |
| Authorisation grain | Per pipeline, via one service connection per pipeline boundary |
| Task-level scoping | Reframed. The need is audit and visibility, not secret segregation between tasks. Met by claim mappings and audit records rather than per-task authentication |

The build that came out of it, with its measured results, is in [poc/README.md](../poc/README.md).

---

## 1. Verdict

The earlier design is a sound proof of **credential-free authentication**, and a sound proof that many pipelines can resolve to a single Vault entity. Both results are real and the guidance was technically correct about them.

It is **not** evidence of zero standing privileges, and on task-level scoping it demonstrates the opposite of what was asked. Two of five criteria are met.

The reason is structural rather than a matter of missing polish. The POC was built to answer a different question. Its stated goal throughout was entity consolidation, folding 400+ service principals into 4-8 entities. That objective and this one pull in opposite directions: consolidation maximises the blast radius of a single identity, whereas granularity and least privilege require the opposite. Section 8 shows the tension is avoidable, but only if the roles are built deliberately.

The framing that matters most for the decision:

> **The POC changed the authentication layer. Zero standing privileges is an authorisation and lifecycle problem.**

Swapping Azure auth for JWT auth neither creates nor removes standing privilege. What determines standing privilege is whether the downstream credential is dynamic, how long its lease lives, and whether it is revoked when the work finishes. The POC changes none of those three.

### Scorecard

| # | Criterion | Verdict | Basis |
|---|---|---|---|
| 1 | No long-lived stored credentials in Azure DevOps | **Pass** | Workload identity federation, token minted at runtime, no secret in the pipeline |
| 2 | Zero standing privileges | **Fail** | Static KV secrets, permanently attached policy, no dynamic secrets engine configured |
| 3 | Just-in-time, ephemeral credential lifecycle | **Partial, weak** | 30-60 minute TTLs, no revocation anywhere in the repository |
| 4 | Grant scoped to a task, not the pipeline | **Fail** | Token promoted to a job-wide variable; token carries no task, pipeline or repository identity |
| 5 | Works across the estate at scale | **Partial** | Terraform samples exist; no enforcement template, no revocation, no measured client-count evidence |

Criterion 4 has since been reframed. The task-level requirement was about audit and visibility rather than segregating secrets between tasks, so the target is now pipeline-level authorisation with per-pipeline attribution. That is achievable and is addressed in sections 7.3 and 8. The verdict on the POC as built is unchanged: it neither scopes nor attributes at that grain today.

---

## 2. What the POC genuinely proved

Give this full credit. It is the harder half of the plumbing and it works.

- Workload identity federation via a managed identity service connection, with no app registration required and only Contributor permissions needed.
- An Entra ID access token minted at pipeline runtime and never stored.
- Vault JWT auth validating that token against the Entra JWKS endpoint, with correct `bound_issuer` and `oidc_discovery_url` handling. The distinction the repo draws, that the issuer is `sts.windows.net` while discovery is at `login.microsoftonline.com`, is correct and is a genuinely easy thing to get wrong.
- A successful end-to-end secret read from a pipeline with nothing stored in Azure DevOps.
- The claim analysis in `STEP_3_PIPELINE_INTEGRATION.md` explaining why access tokens carry usable managed-identity claims is accurate.

If the objective had remained client-count reduction, this POC would substantially answer it.

---

## 3. Finding: standing privilege was moved, not removed

**Severity: high. This is the criterion the whole requirement rests on.**

Three separate reasons the model retains standing privilege.

**The policy is permanently attached.** The JWT role carries `token_policies` bound to a managed identity (`STEP_2_VAULT_SETUP.md:163`). Any pipeline run that can reach the service connection can mint a Vault token carrying that policy at any moment. There is no approval, no elevation step, and no window outside which access is unavailable. The entitlement is continuously live. This is standing privilege relocated from Azure to Vault, not eliminated.

**The secret is static.** The POC reads a fixed KV v2 value with a hardcoded `api_key` (`STEP_2_VAULT_SETUP.md:46`). A static secret read is the antithesis of zero standing privileges: the credential exists before the task, during it, and after it, and it is byte-identical on every run. Compromise of any single run compromises every past and future run until a human rotates it. Nothing about OIDC authentication changes this.

**No dynamic secrets engine exists in the POC.** I grepped the whole repository. The only mention of dynamic secrets is a seven-line aside in the production document (`STEP_5_PRODUCTION.md:535`). Nothing is configured, nothing is tested, and no lease is ever created or observed.

---

## 4. Finding: the design is pipeline-wide by construction

**Severity: high. The POC demonstrates the inverse of the requirement.**

Four mechanisms, each of which alone defeats task-level scoping.

**The Vault token becomes a job-wide variable.** `##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]` promotes the token out of the task and into job scope, readable by every subsequent step (`STEP_3_PIPELINE_INTEGRATION.md:155`, `azure-pipeline.yml:81`). One task's privilege becomes the whole job's privilege.

**The plaintext secrets are broadcast the same way.** `DATABASE_URL` and `API_KEY` are set as job variables (`STEP_3_PIPELINE_INTEGRATION.md:184`), so they are available to any step a developer later adds in a pull request.

**The reusable template makes it worse.** It uses `isOutput=true` (`STEP_5_PRODUCTION.md:403`), extending the token's reach across jobs in the stage. Any team adopting the template inherits the widest possible scope by default.

**Most fundamentally, the token has no task dimension.** Claims are `sub`, `oid`, `appid` and `tid`, all identifying the managed identity and nothing else. The repository's own advanced document states this correctly and explicitly, listing binding to a service connection, repository or branch as "NOT POSSIBLE" (`samples/AZDO-HashiCorp-Vault-EntraID-OIDC-Advanced-config-and-troubleshooting.md:104`). Vault cannot make a task-level authorisation decision on a token that contains no task.

Compounding this, `STEP_3_PIPELINE_INTEGRATION.md:47` instructs the reader to tick "Grant access to all pipelines" on the service connection. For anyone pursuing least privilege that is precisely backwards.

---

## 5. Finding: no revocation, so "just-in-time" is really "expires eventually"

**Severity: medium-high.**

I searched the entire repository for `revoke`, `sys/leases` and `lease_id`. There are zero matches. Nothing calls `auth/token/revoke-self`, and no lease is ever revoked.

Token TTLs are 30 to 60 minutes, far longer than a typical task. `token_num_uses` and `token_bound_cidrs` are both suggested in the production document (`STEP_5_PRODUCTION.md:466-492`) but appear in no actual role configuration anywhere in the repo.

Microsoft-hosted agents are destroyed after the run, which masks the problem. Self-hosted agents, which an enterprise running 400+ pipelines will certainly use, do not. On those, a valid Vault token sits in the agent's variable store long after the work that needed it has finished.

---

## 6. Security findings a reviewer will raise

Report these separately. Each is independently disqualifying if it reaches production.

**Tenant-wide fallback role.** The JWT config sets `default_role: azdo-pipelines` (`STEP_2_VAULT_SETUP.md:91`). That role binds only `tid` (`STEP_2_VAULT_SETUP.md:250`), and its policy grants read and list on `secret/data/*`, meaning every secret in the namespace (`STEP_2_VAULT_SETUP.md:319`). Any managed identity in the tenant, reading everything, on any login that omits the role name. This must be removed before the configuration is used anywhere.

**Any-tenant glob.** The strategy labelled "Best for Scale" sets `bound_claims_type = "glob"` with `iss = "https://sts.windows.net/*/"`, accepting tokens from **any Microsoft Entra tenant on earth** (`STEP_5_PRODUCTION.md:97-117`). This cannot remain in a document titled production recommendations.

**The token Vault accepts is a live Azure Resource Manager credential.** The audience is `https://management.core.windows.net/`. The same token the pipeline hands to Vault can be replayed against ARM with whatever Azure RBAC the managed identity holds, and Vault itself receives a usable ARM credential. This is an inherent trade-off of choosing access tokens over ID tokens, not an implementation slip, and the security team will raise it. Section 7 recommends a path that eliminates it.

The cost of that fix is lower than it looks. An earlier revision of the same pipeline (`poc/pipelines/pipeline-2-feb-2026.yml:37`) read `$idToken` from `addSpnToEnvironment` and sent **that** to Vault, and it authenticated successfully against the same cluster. Both token types were exercised and both worked; the access token was chosen on the assumption that its richer claim set gave better `bound_claims` options. It does not, because every claim that distinguishes one service connection from another lives in the ID token's `sub`, and the access token's additional claims are all per-identity. Moving to Path B is therefore a pipeline change of a few lines, already proven in this tenant, not a redesign.

**Credentials printed to the build log.** `azure-pipeline.yml:52` echoes the raw access token, line 46 decodes and prints its full payload, and line 111 echoes the retrieved secret. `samples/azure-pipelines-vault.yml:114` prints the database URL unmasked. `poc/pipelines/pipeline-2-feb-2026.yml:46` prints the access token base64-encoded, which additionally defeats Azure DevOps log masking, since the masker matches the literal secret string.

This was debug code written to inspect JWT structure, and the tokens are long expired. Two things still follow. The pattern must not survive into published guidance, and the **historical run logs still hold those values in recoverable form**, so the retained runs should be deleted rather than left in place. Treat old build logs as credential stores until proven otherwise.

**Unverifiable entity arithmetic.** The hierarchical model at `STEP_5_PRODUCTION.md:9-27` lists per-business-unit entity counts of 50, 40, 30 and 20, then concludes 30 to 50 entities in total. The numbers do not reconcile, and they do not follow from `user_claim = "sub"`, which yields one entity per managed identity. Due diligence will catch this.

---

## 7. What would actually satisfy the requirement

### 7.1 Dynamic secrets, primarily AWS

This is the change that makes standing privilege genuinely zero. The credential does not exist until the task asks for it, and Vault destroys it when the lease ends.

The **AWS secrets engine** is the primary target. It fits the multi-cloud deployment scenario in the blog's own opening. The **database secrets engine** is the fallback: it is the easier demonstration and the closest analogue to the static sample secret already in the repo.

**Choose the credential type by whether revocation must be demonstrable.** An earlier draft of this section recommended STS AssumeRole with a short lease, alongside explicit revocation in 7.2. Those two recommendations are incompatible. HashiCorp's documentation is explicit that only the `iam_user` credential type can be revoked before expiry. STS credentials, including `assumed_role`, `federation_token` and `session_token`, remain valid until they expire whatever Vault does, and AWS enforces a 15-minute minimum on AssumeRole sessions.

| Credential type | Revocable before expiry | Trade-off |
|---|---|---|
| `iam_user` | **Yes.** Revoking the lease deletes the IAM user | IAM user churn, and a 5 to 10 second eventual-consistency delay before first use |
| `assumed_role` | No. Valid for at least 15 minutes | No IAM user churn, but "dead once the task finishes" cannot be shown |

For a POC whose headline claim is that the credential stops working when the pipeline finishes, `iam_user` is the only honest choice. `assumed_role` remains reasonable in production where a bounded 15-minute window is acceptable, but it should then be described as short-lived, not as revoked.

One point that is easy to miss and that materially affects the story. If Vault holds a static AWS access key in order to mint dynamic credentials, the standing privilege has simply moved inside Vault. **Vault Enterprise plugin workload identity federation** closes this: configure `aws/config/root` with `identity_token_audience` and `role_arn` instead of `access_key`, and Vault exchanges its own signed identity token for short-lived STS credentials against an IAM OIDC provider that trusts Vault. The parameters are mutually exclusive, so this is an either/or choice. This is an Enterprise-only capability, which is worth knowing before the design depends on it.

**The Vault to AWS leg is analogous in shape but inverted in direction, and that inversion is the whole difficulty.** It is tempting to assume it works like the Azure DevOps to Vault leg already proven in the POC. The federation pattern is the same, but the roles swap:

| | Azure DevOps to Vault, proven | Vault to AWS, to be built |
|---|---|---|
| Identity provider | Microsoft Entra | **Vault itself** |
| Relying party | Vault | AWS IAM |
| Who fetches whose JWKS | Vault fetches Entra's | **AWS fetches Vault's** |
| Reachability burden | Trivial, Entra is public | **Vault's OIDC endpoint must be publicly reachable** |

In the proven leg, Vault reaches out to a public Microsoft endpoint, which always works. In the new leg, AWS must reach **Vault** to validate the tokens Vault signs. That is the reason HashiCorp's own tutorial resorts to a tunnel when demonstrating this on a local cluster.

An earlier draft said an HCP Vault Dedicated cluster, having a public address, was likely to work as-is. **Probing the cluster on 16 and 18 September disproved that.** There are two separate problems, and the fix for one does not fix the other.

**Problem 1: the advertised issuer is unreachable and unstable. Fixed by overriding the issuer.** Fetched through the public address on port 8200, the plugin identity discovery document advertises its issuer and key endpoint on a **private hostname, on port 8202**:

```
https://node-106-1.<cluster>-private-vault-<id>.z1.hashicorp.cloud:8202/v1/admin/identity/oidc/plugins
```

That address does not answer from the internet, so AWS could never fetch the signing keys. It is also **node-specific**: the first probe returned `node-106-2`, the second `node-106-1`. Tokens carry whichever node's issuer was active when signed, so an AWS trust bound to one would break the next time leadership moved. The same signing keys are served on the public host on port 8200, so setting `identity/oidc/config` issuer to the public cluster URL resolves reachability and stability together.

**Problem 2: any port at all. Not fixed by the override.** AWS documentation for creating an IAM OIDC identity provider states that the URL should not contain a port number. The public cluster URL still carries 8200. The wording is "should not" rather than "must not", so whether AWS actually rejects it can only be settled empirically. Port 443 does not answer on the public host, so there is no portless alternative on the cluster itself.

This is the same HCP behaviour reported on HashiCorp Discuss in 2022, still present in September 2026. If the production cluster is private, the approach needs rethinking entirely.

### 7.2 Explicit lease and token revocation

Revoke explicitly rather than waiting for expiry. Cheap to implement, currently absent, and it is the entire difference between "the credential expires" and "the credential is just in time". Three details determine whether it actually works.

**Revoke inside the task that holds the token.** An earlier draft proposed a separate final step under `condition: always()`. That step would never have the token, since section 7.3 keeps the token out of job variables. Instead, call `auth/token/revoke-self` at the end of the task, and register a shell `EXIT` trap in the same task so revocation still runs when a command fails. Pipeline cancellation kills the process before the trap can run, so a short token TTL is the backstop.

**Revoking the token revokes its leases.** One `revoke-self` call is enough: Vault revokes every lease the token created, which for `iam_user` credentials deletes the IAM user. A separate lease revocation call is unnecessary.

**Size `token_num_uses` exactly, and keep the default policy.** A token that exhausts its use count is revoked immediately, which by the rule above deletes the credential mid-task. Count the calls: one credential read plus one `revoke-self` is two. And `revoke-self` is permitted by Vault's default policy, so setting `token_no_default_policy = true`, as `STEP_5_PRODUCTION.md` suggests, would make self-revocation fail.

This only proves anything with a revocable credential type. See 7.1.

### 7.3 Credential handling and the audit requirement

**This section was substantially reduced after clarifying the requirement.** The interest in task-level access is about **audit and visibility**, knowing which work consumed which secret, not about segregating secrets between tasks within a pipeline. That is a far cheaper problem, and it does not require per-task authentication.

**For visibility**, use `claim_mappings` on the JWT role to project the token subject into Vault token metadata. Verified behaviour: the mapped claim appears in the token metadata and in the audit record alongside the role name, so every secret access is attributable to a specific pipeline without any change to pipeline structure. Supplement with the pipeline context headers already shown in `STEP_3_PIPELINE_INTEGRATION.md:255` for build-level correlation, remembering that those are self-asserted and belong in audit, never in policy.

**For containment**, the hygiene still matters even though segregation is not the goal:

- Authenticate, read and use inside a single task where it is convenient, so the token does not become a job variable unnecessarily.
- Set `token_num_uses` on the role so a leaked token cannot be replayed. Verified as honoured.
- Do not use `isOutput=true` on the token variable. Extending it across jobs buys nothing and widens exposure.
- Response wrapping remains available if a specific secret warrants single-use delivery with tamper evidence.

These are worth doing, but they are no longer the acceptance criterion. Sections 7.1 and 7.2 carry the weight of the requirement.

### 7.4 Getting real pipeline identity into the authorisation decision

This is where my earlier assessment was too casual and where the research changed the picture. Your findings about ID tokens were closer to the truth than my initial summary. Here is what I verified.

**Azure DevOps can issue its own OIDC token that carries genuine pipeline identity.** The `OidcToken` REST API (`POST {org}/{project}/_apis/distributedtask/hubs/{hub}/plans/{planId}/jobs/{jobId}/oidctoken?api-version=7.1-preview.1`) returns a token whose subject encodes real context. Two forms exist:

| Call | Subject format | Identifies |
|---|---|---|
| Without `serviceConnectionId` | `p://<org>/<project>/<pipeline>` | The pipeline |
| With `serviceConnectionId` | `sc://<org>/<project>/<service-connection>` | The service connection |

The `sc://` format is confirmed by Microsoft's own troubleshooting documentation, which quotes it verbatim in the AADSTS70021 error example. The `p://` format is confirmed by Microsoft's Databricks integration guide, which uses exactly this pattern to let a third party trust Azure DevOps directly.

The issuer `https://vstoken.dev.azure.com` publishes a working OIDC discovery document and JWKS endpoint, so Vault could consume these tokens natively via JWT auth with no Entra ID in the path at all. The token lifetime is 10 minutes, and the audience is `api://AzureADTokenExchange`, which is **not** an Azure Resource Manager credential and therefore cannot be replayed against Azure. That eliminates the finding in section 6.

**However, that issuer is being retired.** This drove the decision recorded in section 0 to build on Path B instead.

| Date | Status |
|---|---|
| November 2025 | New service connections default to the Microsoft Entra issuer |
| 1 July 2026 | Deprecation begins. **Already past.** Warnings now appear in pipelines |
| 1 July 2027 | End of life for the Azure DevOps issuer |

The retirement is scoped to workload identity federation **service connections** in Azure public cloud using single-tenant apps or managed identities. Sovereign clouds and multi-tenant applications are explicitly out of scope and keep the old issuer.

Whether the `p://` pattern, where a third party such as Vault trusts `vstoken.dev.azure.com` directly rather than federating into Entra, falls inside or outside that retirement is **not stated anywhere in Microsoft's documentation**. Microsoft's own Databricks guidance, updated in March 2026, still recommends it. The Azure DevOps roadmap entry on Entra-issued tokens frames the change exclusively as the Azure DevOps to Entra exchange for Azure deployments and never mentions third-party direct trust, which is suggestive but not dispositive.

Because Path B is now the chosen design, this question no longer blocks anything. It is an optimisation: if Microsoft later confirms the direct-trust pattern survives, moving to it would buy readable `p://org/project/pipeline` subjects in place of opaque GUIDs. Worth asking, not worth waiting for.

Separately, the deprecation of the Azure DevOps **OAuth app platform** is a different announcement and does not affect any of this. It covers third-party apps calling the Azure DevOps REST APIs on a user's behalf, and leaves `System.AccessToken`, personal access tokens and the OidcToken API untouched. Note that the blog article at line 132 currently cites the OAuth sunset as the reason to prefer the Entra issuer. The conclusion is right but the justification is not: the reason is the workload identity federation issuer retirement described above.

**Under the Microsoft Entra issuer**, the replacement, the pipeline-visible token carries a structured subject. The POC captured a real one from the federated credential blade, which lets the format be decoded segment by segment:

```
/eid1/c/pub/t/{tenant-id-base64url}/a/{azdo-app-id-base64url}/sc/{org-instance-id}/{service-connection-id}
```

| Segment | Content | How to obtain it |
|---|---|---|
| `t/...` | Entra tenant ID, base64url encoded rather than a plain GUID | Derived from the tenant ID |
| `a/...` | The Azure DevOps first-party app ID, base64url encoded | Constant across all organisations |
| `sc/...` | **Organisation instance ID**, a plain GUID | `GET https://dev.azure.com/{org}/_apis/connectionData` then read `.instanceId` |
| final segment | **Service connection ID**, a plain GUID | Shown on the service connection in Azure DevOps |

This is a correction to an earlier draft, which described the final segment as the federated credential ID. It is the service connection ID, which is better news: it is directly visible in the Azure DevOps UI and retrievable through the API, so Terraform can generate the bindings without a lookup into Entra.

The audience is `api://AzureADTokenExchange` and the issuer is `https://login.microsoftonline.com/{tenant}/v2.0`. The subject uniquely identifies one service connection, so **per-service-connection granularity is achievable** on the supported path.

Two caveats remain. The identifiers are opaque GUIDs rather than readable names, which is an operational cost at 400+ pipelines and argues for Terraform generation. And the format is **undocumented by Microsoft**, which is what the developer community thread is asking them to fix. Building policy on an undocumented format carries change risk, and that should be stated plainly rather than buried.

**Glob matching: tested, with a trap.** An earlier draft said `bound_subject` must never be a glob, then a later draft said the POC had proved globs work. Neither was properly established: the POC defines several roles but the pipeline references only role 3, so the glob roles were written rather than exercised. I tested all the variants against a local Vault Enterprise instance using the real subject structure.

| Role configuration | This connection | Another connection, same org | Another org |
|---|---|---|---|
| `bound_claims.sub = "*/sc/{org}/*"`, glob | Allow | Allow | **Deny** |
| `bound_claims.sub = "<full subject>"`, glob | Allow | Deny | Deny |
| `bound_claims.sub = "*/sc/*/*"`, glob | Allow | Allow | **Allow** |
| `bound_claims.sub = "<full subject>"`, exact | Allow | Deny | Deny |
| `bound_subject = "*/sc/{org}/*"`, glob | **Deny** | Deny | Deny |

Three conclusions.

**Globs work, but only through `bound_claims`.** The last row is the trap: `bound_subject` is exact-match only and silently ignores glob patterns, failing closed even on a token that should match. Anyone who tries a glob on `bound_subject`, sees it fail, and concludes that globbing is unsupported has drawn the wrong lesson. Set `bound_claims_type = "glob"` and put the pattern in `bound_claims.sub` instead.

**A glob must pin the organisation instance ID.** Row one is a legitimate organisation-wide boundary. Row three is not: `*/sc/*/*` accepts any Azure DevOps organisation whose tokens reach the tenant, and is the same class of mistake as the any-tenant glob flagged in section 6.

**For per-pipeline granularity, use an exact `bound_claims.sub`.** Row four is the recommended configuration. It is simpler than a fully specified glob, behaves identically, and removes any risk of a pattern being loosened later by someone who does not realise what the segments mean.

Critically, because `api://AzureADTokenExchange` is a generic audience shared by every Entra tenant, **`bound_audiences` provides no isolation on this path**. The issuer constrains you to the tenant and the subject does all the remaining work. `bound_subject` must therefore be an exact match, never a glob.

This is now confirmed rather than assumed. The OidcToken Create API accepts only `hubName`, `jobId`, `organization`, `planId`, `scopeIdentifier`, `api-version` and an optional `serviceConnectionId`. There is no audience parameter and no request body, so the audience cannot be customised. Verified separately against a local Vault: presenting a token whose subject does not match `bound_subject` is rejected with `invalid subject (sub) claim`, with no partial or glob matching.

#### Service connections map many-to-one onto identities

**Several service connections can share a single app registration or user-assigned managed identity.** This is not an edge case; it is the default outcome of how teams create connections, and the repository already documents it at `samples/AZDO-HashiCorp-Vault-EntraID-OIDC-Advanced-config-and-troubleshooting.md:104`.

The mechanism is **federated identity credentials**. An app registration or managed identity holds a collection of these, each one a distinct issuer, subject and audience triple. Creating a workload identity federation service connection adds one federated credential to the chosen identity, carrying that connection's own subject.

This single fact explains both the POC's failure and Path B's success, because two different tokens exist and the POC selected the wrong one:

| | Token the POC uses | Token Path B uses |
|---|---|---|
| Obtained by | `az account get-access-token` | `addSpnToEnvironment: true`, or the OidcToken REST API |
| What it is | Entra access token, after the exchange | The ID token or assertion, before the exchange |
| Identifying claim | `sub`, `oid`, `appid` = the service principal | `sub` = the federated credential, so the service connection |
| Audience | `https://management.core.windows.net/` | `fb60f99c-7a34-4190-8149-302f77469936`, the Azure Token Exchange Endpoint app ID |
| Replayable against Azure | **Yes** | No |
| Granularity when connections share an identity | **All indistinguishable** | **Each one distinct** |

Ten service connections sharing one managed identity produce ten byte-identical sets of authorisation claims under the POC's approach. Path B binds on the **service connection ID**, which stays distinct regardless of how connections are grouped onto identities.

A real subject, taken from a live token rather than from documentation, confirms the structure:

```
/eid1/c/pub/t/<tenant, base64url>/a/<azure devops app, base64url>/sc/<org instance>/<connection>
              └─ tenant GUID ───┘   └─ Azure DevOps app ──────┘   └ org instance ┘ └ connection ┘
```

The two base64url segments decode to the tenant ID and to `499b84ac-1321-427f-aa17-267ca6975798`, which is the **Azure DevOps first-party application**, not the backing identity. It is constant for every Azure DevOps service connection everywhere, and it appears again as the token's `azp`. The managed identity does not appear in the subject at all: a connection anchored on a managed identity produced the subject above with that identity's client ID nowhere in it.

That is the crux of Path B. Because the identity is absent from the subject, connections sharing one identity are still distinguishable, and the only segment that varies within a tenant and organisation is the final one, the service connection ID. That is the claim Path B binds on.

Three design consequences follow.

**The backing identity may need no Azure permissions at all.** If a service connection exists only to anchor a federated credential for Vault authentication, the app registration or managed identity behind it needs no role assignments, because obtaining a token is not the same as being authorised to use it against Azure. The portal creation flow tends to grant Contributor by default, so that assignment should be stripped afterwards. This turns each identity into a pure authentication anchor rather than a standing Azure privilege, which is directly on-message for the zero standing privileges ask. Two things to confirm in your own tenant before relying on it: whether the `AzureCLI@2` task tolerates an identity with no subscription access, since that task performs a sign-in and subscription selection that may fail without it, and whether the OidcToken REST API path avoids the problem entirely by never invoking the Azure CLI.

**The assertion is cached for roughly 24 hours, not minted per run.** Measured on 21 September 2026: a token issued at 03:55:41Z, expiring 04:00:41Z the following day, was served unchanged to pipeline runs starting at 04:18 and later, with an identical `uti`. One assertion exists per service connection and every authorised run receives it until it expires. This does not weaken the zero standing privileges claim, which rests on what the assertion is exchanged for, a 5-minute Vault token limited to two uses and an AWS credential deleted before the run ends. It does mean the assertion itself is a long-lived bearer credential whose protection is Azure DevOps job isolation and per-pipeline connection authorisation, so authorising a connection for a whole project rather than one pipeline is a real exposure, and a token reaching a build log is usable for a day. Raise it before a security reviewer does.

**The two acquisition methods return the same token.** Also measured: `addSpnToEnvironment` and the OidcToken REST API produced byte-identical payloads with the same `uti`. `AzureCLI@2` calls that same endpoint with the same `System.AccessToken` and then additionally signs in to Azure. The choice between them is therefore not about the token but about that sign-in. `AzureCLI@2` signs in and then selects a subscription before any user script runs, and that selection fails outright for an identity holding no role assignment anywhere in the subscription: `The subscription of '...' doesn't exist in cloud 'AzureCloud'`. An identity stripped of all assignments, which is the point of the paragraph above, therefore fails in the task rather than in Vault. The OidcToken REST API never invokes the Azure CLI and has no such requirement; it does require the connection to be referenced by some task in the job, which a `condition: false` task satisfies.

The earlier open question, whether the REST API returns the Entra-issued token or the older Azure DevOps one, is settled: it returns the Entra-issued token, the same one `addSpnToEnvironment` exposes.

So the trade is a single standing Azure privilege against a slightly unusual pipeline. Reader scoped to a resource group containing only the identity is the smallest grant that makes the CLI task work.

**The federated credential cap is real, and the workaround does not exist.** Both claims your side chat flagged as unverified have now been checked:

| Claim | Verified outcome |
|---|---|
| Cap of 20 federated credentials per identity | **Confirmed.** The quota cannot be raised, even by support request. The workaround is more app registrations |
| Flexible federated identity credentials could cover a whole project | **False.** The preview supports GitHub, GitLab and Terraform Cloud only. Azure DevOps is not a supported issuer, and `claimsMatchingExpression` is mutually exclusive with `subject` |

So the floor is arithmetic: per-pipeline granularity across 400 pipelines needs at least 20 identities. That is manageable rather than alarming, and it composes well with section 8, where 20 identities still collapse to a single Vault entity. It does mean the identity estate must be planned and generated rather than created by hand, which is another argument for Terraform.

**On the custom headers idea** in `STEP_3_PIPELINE_INTEGRATION.md:255`: passing `Build.BuildId`, repo and branch as request headers is self-asserted and unauthenticated. It is genuinely useful for audit correlation and worthless for authorisation. The repo does not overclaim here, but a reader easily could.

**The honest limit.** None of these options gives cryptographic task-level identity. The finest grain Azure DevOps can attest to is the pipeline or the service connection, and the OIDC token is minted per job. Task-level scoping must therefore be enforced by construction, as described in 7.3, not by a claim Vault can verify. State that plainly rather than implying otherwise.

### 7.5 Azure DevOps controls that carry real weight

- Scope service connections to **named pipelines**, not "all pipelines". This is the single highest-leverage change and it reverses current guidance in the repo.
- Use **Environments with approvals and checks** to gate stages that touch production secrets. This is where genuine just-in-time human authorisation lives in Azure DevOps.
- Run **one managed identity or service connection per team and environment**, so the Vault role has a meaningful boundary to bind to.
- Review the org setting **Limit job authorization scope**, which governs what `System.AccessToken` can reach.

---

## 8. Granularity versus client count: resolved, and the news is good

My earlier draft of this section claimed that granularity and client count are in direct tension, and that per-pipeline boundaries would multiply Vault clients. **Testing disproved that.** The two are separable, and you can have both.

`bound_subject` controls authorisation. `user_claim` independently controls which entity the login maps to. Setting a granular subject binding alongside a coarse `user_claim` gives per-pipeline authorisation at per-organisation client count.

Measured against a local Vault Enterprise instance, with two roles bound to two different service connection subjects:

| Configuration | Entities created | Distinct policies applied | Full subject in audit record |
|---|---|---|---|
| `user_claim = "sub"` | 2 | Yes | Yes |
| `user_claim = "iss"` | 1 | Yes | No |
| `user_claim = "iss"` plus `claim_mappings` | 1 | Yes | Yes |

**The POC reached the same conclusion independently.** Its findings note records that using `user_claim = "tid"` limits the entity count to one regardless of project or pipeline. That is the same mechanism I tested with `iss`, and `tid` is the better choice of the two because it names the tenant explicitly rather than relying on the issuer string. Treat this as corroborated from two directions rather than as a new idea.

The third row is the recommended configuration. Both pipelines share one entity, each still receives only its own policy, and the audit record carries the exact federated credential subject alongside the role name. Consolidation costs nothing in attribution.

One caveat to state honestly: the entity alias name becomes the issuer, so entity-level identity in the Vault UI is no longer meaningful, and attribution must be read from audit records and token metadata rather than from the identity system.

The practical consequence is that per-pipeline authorisation costs nothing in entity count, so a design does not have to choose between granularity and consolidation. That is a stronger position than the one this report opened with.

---

## 9. What happened next

Every recommendation above was built and measured. The configuration is in [poc/terraform](../poc/terraform), the pipeline in [poc/pipelines](../poc/pipelines), and the nine acceptance tests with their evidence in [poc/README.md](../poc/README.md).

Three things the build settled that this report left open:

- **The federated credential cap is 20 per identity** and cannot be raised. Flexible federated identity credentials, which would allow a wildcard subject, support GitHub, GitLab and Terraform Cloud only, on app registrations only, and are in preview. Azure DevOps is not a supported issuer.
- **The OidcToken REST API and `AzureCLI@2` return the same token**, byte for byte, with the same `uti`. The choice between them is about which failure mode and which Azure permission you prefer, not about the token.
- **The backing identity can hold no Azure role assignment at all**, provided the pipeline uses the REST method. `AzureCLI@2` needs one, because it selects a subscription.

One constraint found while resolving the plugin federation question deserves early attention: plugin workload identity federation requires **AWS to reach Vault's own OIDC issuer endpoint** to fetch its JWKS. A private Vault cluster cannot satisfy this, and a public one advertises a port, which AWS documentation says an OIDC provider URL should not contain.
