# Watchers and checks for a live demonstration

Three scripts for side terminals during a demo, and one helper that feeds them.
All are read only, and all use your own credentials rather than the pipeline's.

| Script | What it shows |
|---|---|
| `watch-iam.sh` | Dynamic IAM users appearing and disappearing while a pipeline runs. The moment worth showing. |
| `watch-audit.sh` | Vault's own audit record from CloudWatch: path, policies and the full `pipeline_subject`. The server's account of what happened, not the pipeline's. |
| `scan-logs.sh` | Downloads every log part of the latest runs and searches them for Vault tokens, AWS keys and raw JWTs. Acceptance test 7, run live. |
| `env-from-terraform.sh` | Prints the names Terraform created, as exports, so the three above do not need them retyped. |

## What they need

Two sources, deliberately separate.

**Credentials and endpoints** come from `~/.zsp-poc.env`, which every script sources if it exists. That
file is yours and is not in this repository. It sets `AZDO_ORG_SERVICE_URL`, `AZDO_PERSONAL_ACCESS_TOKEN`,
`VAULT_ADDR`, `VAULT_TOKEN`, `VAULT_NAMESPACE`, `AWS_PROFILE` and `AWS_REGION`.
[docs/VALIDATION.md](../docs/VALIDATION.md) shows the whole file.

**Names of the things Terraform created** come from Terraform:

```bash
eval "$(./env-from-terraform.sh)"
```

That exports `AZDO_PROJECT`, `NAME_PREFIX`, `AWS_USER_PREFIX`, `VAULT_JWT_PATH`, `VAULT_AWS_PATH` and
`VAULT_NAMESPACE` from the `demo_env` output. Without it the scripts fall back to the defaults in
`variables.tf`, except `scan-logs.sh`, which refuses to guess a project name: a wrong one returns a 404
that reads like a permissions problem.

## Running them

```bash
./watch-iam.sh            # poll until interrupted; ./watch-iam.sh 300 stops after 300s
./watch-audit.sh 30       # look back 30 minutes, then poll
./scan-logs.sh            # latest run of each pipeline; or pass build IDs
```

`watch-audit.sh` lags. HCP batches audit delivery, so events land a minute or two late: start it at the
beginning of the run rather than waiting at a blank terminal when you reach the proof.
