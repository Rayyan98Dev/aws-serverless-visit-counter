# Design: serverless visit counter on AWS

Agreed 17 Nov 2026, built 18–21 Nov 2026, destroyed 21 Nov 2026. This doc records the decisions and the reasons behind them; the [README](../README.md) covers what the project is and how to run it.

## Goal

Rebuild Project 1 (a visit counter running in Docker Compose) as a serverless app on AWS, with all infrastructure in Terraform and every change going through a pull request. Aim: as close to a production setup as the account allows, while staying free.

## Constraints

| Constraint | Effect on the design |
|---|---|
| New-style AWS account on the **Free plan**, no card attached | Only always-free services and settings; nothing that needs billing. Never click Upgrade. |
| Guardrail **SCP denies `iam:*Provider*`** (proved 17 Nov: `ListOpenIDConnectProviders` → "explicit deny in a service control policy") | GitHub Actions can't log in to AWS with OIDC. |
| **No access keys** anywhere | No stored credentials in GitHub either, so CI can't reach AWS at all. Laptop uses `aws login` (short-lived). |
| Guardrails deny some regions (Frankfurt) | Region `eu-north-1`. |
| Free plan ends 16 May 2027 | Don't leave anything running that would need a decision then. |

## Decisions

### Compute: Lambda + function URL

- **Chosen:** one Python Lambda behind a Lambda function URL.
- **Considered:** API Gateway in front of Lambda; a small EC2 instance running the Project 1 containers.
- **Why:** a function URL gives the function its own HTTPS address with no extra service to configure, and Lambda's always-free allowance (1M requests and 400,000 GB-s a month) covers this many times over. EC2 would mean a server that runs all the time and needs patching, which is the opposite of what this project is meant to practise. API Gateway adds routing, throttling and auth options this one endpoint doesn't need yet.

### Data: DynamoDB, provisioned 1 RCU / 1 WCU

- **Chosen:** table `visits`, `billing_mode = "PROVISIONED"`, 1/1, hash key `id`.
- **Considered:** on-demand billing.
- **Why:** the always-free 25 RCU / 25 WCU apply to **provisioned** capacity only (checked on the pricing page before creating it). On-demand gets free storage but no free requests. One counter needs almost no capacity.

### Access to the URL: public, with a concurrency cap

- **Chosen:** `authorization_type = "NONE"` with `reserved_concurrent_executions = 2`.
- **Considered:** `AWS_IAM` auth (only signed requests); a CloudWatch alarm on invocations.
- **Why:** the point is a page anyone can open. The cap limits damage (at most 2 copies run at once, extras are throttled) but doesn't stop requests arriving or cap the monthly total. That was acceptable because the account has no card, and it's the main reason the project is destroyed when not in use. The account allowed up to 300 reserved (400 total, minus the 100 AWS keeps unreserved).

### IAM: least privilege

- **Chosen:** the Lambda role may only `dynamodb:UpdateItem` on the `visits` table and `logs:CreateLogStream` / `logs:PutLogEvents` on its own log group.
- **Changed during the build:** `GetItem` was in the first design and was dropped, because `UpdateItem` with `ReturnValues="UPDATED_NEW"` already returns the count and the code never reads. `CreateLogGroup` isn't needed because Terraform creates the group (with 7-day retention, so logs don't pile up).

### State: S3 backend made by a separate bootstrap config

- **Chosen:** a `bootstrap/` config with **local state** creates the bucket (versioning, all public access blocked, SSE-S3 encryption, tags); the root config stores its state in that bucket with `use_lockfile = true`.
- **Considered:** local state only; a DynamoDB lock table.
- **Why:** remote state is what a team uses, and a config can't keep its state in a bucket it creates itself (chicken-and-egg). Native S3 locking (Terraform ≥ 1.10) replaces the DynamoDB lock table. Versioning lets a damaged state file be rolled back. If the laptop dies, only bootstrap's small state is lost, and four `terraform import` commands rebuild it (in the README).

### Encryption: SSE-S3, not KMS

- **Chosen:** `AES256` (AWS-owned key). Trivy finding `AWS-0132` is ignored in `.trivyignore` with a written reason.
- **Considered:** a customer-managed KMS key.
- **Why:** KMS costs about USD 1 a month per key and adds control over who can decrypt plus an audit trail, which matters for real data, not for a single-owner learning bucket. Revisit if it ever holds real data.

### Workflow: "A+" (CI without AWS, plan and apply by hand)

- **Chosen:** CI on every PR runs only checks that need no AWS login (`fmt -check`, `init -backend=false` + `validate` for root and bootstrap, `trivy config`). I run `plan -out=tfplan` on the laptop, paste the summary into the PR, merge when green, then `apply tfplan` from `main`. `main` is protected by a ruleset (PR required, required check, no force pushes or deletion, no bypass).
- **Considered:** access keys stored as GitHub secrets so CI could plan and apply.
- **Why:** OIDC is blocked by the SCP, and long-lived keys are the thing this project avoids. Everything except who runs `plan`/`apply` is the real process. The saved plan means exactly what was reviewed gets applied.

### OIDC: written, but off

- **Chosen:** `oidc.tf` (provider, trust policy, CI role with state/lock permissions + `ReadOnlyAccess`) and a `terraform-plan-oidc` job, both switched off: Terraform `count` via `enable_github_oidc = false`, and repository variable `ENABLE_OIDC`.
- **Why:** shows the production setup and makes moving to an account without the SCP a small change (steps in the README). The job only plans; applying from CI would need a separate role with write access and an approval gate.

### Tags

`default_tags` on the provider (`project`, `owner`, `managed-by = terraform`), so no resource can be created untagged. Useful for cost reports, finding everything before a destroy, and warning people not to edit by hand.

## What changed during the build

| Date | What happened | Change |
|---|---|---|
| 19 Nov | Reviewed the IAM policy against the code | Dropped `GetItem` |
| 20 Nov | First apply went to Frankfurt and hit an SCP deny (no `provider` block, so the `default` profile's region) | Added `provider "aws"` with region and profile |
| 20 Nov | 409 concurrent update while creating the URL permissions | Re-planned, `apply -parallelism=1` |
| 21 Nov | `aws lambda get-policy` showed every permission twice: the URL resource adds both public permissions itself | Removed my two `aws_lambda_permission` resources, left a comment |
| 21 Nov | Keep or destroy? | **Destroyed** (6 resources). State bucket kept. Rebuild = one plan + apply, new URL, count from 1. |

## Known gaps and future work

- `lifecycle { prevent_destroy = true }` on the state bucket. A bootstrap `destroy` today would remove versioning and the public-access block, then fail on the non-empty bucket.
- Remove `profile = "lab"` from the backend and provider blocks (use `AWS_PROFILE`); required before OIDC can work on a runner.
- Replace `ReadOnlyAccess` on the CI role with only the read actions `plan` needs. As it stands it can read every object in every bucket, state included.
- Narrow the Trivy ignore to one path with `.trivyignore.yaml`, and bump the Trivy version CI runs.
- Log one line per request from the handler.
- Before May 2027: decide where the project lives after the Free plan, and add a budget alarm if it ever runs on a paid account.
