# aws-serverless-visit-counter

A public visit counter on AWS: a **Lambda function URL** runs a small Python **Lambda** that adds 1 to a count in **DynamoDB** and returns it.
All infrastructure is **Terraform**, with remote state in an **S3 bucket** (built by a separate `bootstrap/` config) and least-privilege IAM.
Changes go through a **pull request with CI checks** (fmt, validate, Trivy); after merge I apply the **reviewed, saved plan** by hand, because this account's guardrail policy blocks GitHub from logging in to AWS.

> **Status:** destroyed on 21 Nov 2026 (nothing public left running). It can be rebuilt with one plan + apply (see [Rebuild](#rebuild)). The state bucket is kept.

Project 2 of my 12-week DevOps plan. Project 1 (the same counter with Docker, Compose and CI/CD) is in [`devops-journey`](https://github.com/Rayyan98Dev/devops-journey).

---

## How a request works

```
curl ──► Function URL ──► Lambda (src/app.py) ──► DynamoDB table "visits"
          (public)          runs as role             UpdateItem: visits + 1
                            visit-counter-lambda
                                 │
                                 └──► CloudWatch log group /aws/lambda/visit-counter (7 days)
```

| Step | What is checked |
|---|---|
| Someone calls the URL | The function's **resource policy**: `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` for the public (`authorization_type = "NONE"`). The URL resource adds both itself. |
| Lambda starts the handler | **Reserved concurrency 2**: at most 2 copies run at once, extra requests are throttled. |
| Lambda takes on its role | The role's **trust policy**: only `lambda.amazonaws.com` may assume it. |
| The code updates the count | The role's **permissions policy**: only `dynamodb:UpdateItem` on the `visits` table. |
| Lambda writes its logs | Only `logs:CreateLogStream` / `logs:PutLogEvents` on its own log group (`:*` = every stream inside it). |

That makes three separate permission checks: **who may call the function** (resource policy), **who may become the role** (trust policy) and **what the role may do** (permissions policy).

`UpdateExpression="ADD visits :one"` creates the item with `visits = 1` the first time, so no setup step is needed. The DynamoDB handle (`boto3.resource("dynamodb").Table(...)`) creates nothing in AWS: it only points at the table Terraform made.

### Evidence (before the destroy)

```bash
curl "$(terraform output -raw url)"
# Hello from Catto! This page has been visited 1 times.
```

The count went 1 → 7 across 20–21 Nov. The first request had a cold start (`Init Duration: 470 ms`); the next one on the same copy took 23 ms, because the DynamoDB handle is created outside `handler` and reused.

---

## Repository layout

| Path | What it is |
|---|---|
| `bootstrap/main.tf` | The S3 state bucket: versioning, all public access blocked, SSE-S3 encryption, tags. **Local state** (see below). |
| `main.tf` | `backend "s3"` (where root's state lives, with `use_lockfile = true`) and `provider "aws"` (where resources are created: `eu-north-1`, `default_tags`). |
| `dynamodb.tf` | Table `visits`, `PROVISIONED` 1 RCU / 1 WCU (the always-free tier is provisioned capacity only). |
| `iam.tf` | Lambda execution role: trust policy + least-privilege permissions policy. |
| `logs.tf` | Log group `/aws/lambda/visit-counter`, 7-day retention. |
| `lambda.tf` | Zips `src/app.py`, creates the function (python3.13, 128 MB, 5 s, reserved concurrency 2) and the public function URL. Output: `url`. |
| `oidc.tf` | GitHub OIDC provider + CI role, **switched off** (see [OIDC](#github-oidc-written-but-off)). |
| `src/app.py` | The handler (`app.handler` = file `app.py`, function `handler`). It reads the table name from the `TABLE_NAME` environment variable, so the name isn't typed into the code. |
| `.github/workflows/ci.yml` | CI: `terraform-checks` on every PR and push to `main`; `terraform-plan-oidc` switched off. |
| `.trivyignore` | One accepted finding, with the reason. |

Terraform reads **every** `.tf` file in a folder as one config, so the split into files is only for tidiness: `main.tf` holds the folder-wide settings, and `iam.tf` only *points at* the table and log group by ARN. Terraform never reads subfolders, which is why `bootstrap/` is a separate config with its own provider block, lock file and state (you `cd bootstrap` to work on it).

A few details worth knowing when reading the code:

- **Labels vs real names.** In `aws_dynamodb_table.visits`, `visits` is Terraform's label for the block; the table's AWS name comes from `name = "visits"`. Likewise `aws_s3_bucket.state` is a bucket that *holds* state, not the state itself.
- **Data vs resource.** In `iam.tf`, the `aws_iam_policy_document` data blocks only write policy JSON (no AWS call); `aws_iam_role` and `aws_iam_role_policy` create the role and attach that JSON. `lambda.tf` then links the function to the role with `role = aws_iam_role.lambda.arn`.
- **The zip.** `archive_file` builds `build/lambda.zip` on the laptop; Terraform uploads it as it is and Lambda unpacks it. `source_code_hash` is how Terraform notices the code changed.
- **`depends_on`.** The function doesn't reference the log group (it only shares the name by convention) or the role *policy*, so Terraform can't see the order by itself. Without it, the first request could run before the permissions exist.
- **Versions.** `~> 6.0` allows any 6.x provider but not 7.0; `required_version = ">= 1.10"` because `use_lockfile` arrived in Terraform 1.10.

### Why `bootstrap/` is separate

A config can't keep its state in a bucket it hasn't created yet. So `bootstrap/` creates the bucket and keeps its own small state **locally**; the root config stores its state **in** that bucket. Neither state file goes in Git (state can hold secrets in clear text, and two copies of state can't be merged like code).

---

## Workflow ("A+")

1. Branch → change `.tf` files → `terraform plan -out=tfplan` on my laptop → paste the plan summary into the PR.
2. CI runs on the PR **without any AWS login**: `terraform fmt -check -recursive`, `init -backend=false` + `validate` for root, `init` + `validate` for bootstrap, then `trivy config` (fails on HIGH/CRITICAL). The job has no credentials at all, which is why root needs `-backend=false`; bootstrap's plain `init` works because its state is local. Every action is pinned by full commit SHA.
3. `main` is protected by a ruleset: PR required, required check `terraform-checks`, no force pushes, no deletion, empty bypass list.
4. Merge when green → on `main`, `terraform apply tfplan`. A saved plan applies exactly what was reviewed and does not ask "yes" again. If the state changed since the plan (for example a failed apply part-way), the plan is stale: plan again.

**What is real:** the code, remote locked state, least privilege, PR review, required checks, no long-lived keys.
**What is simulated:** a person runs `plan` and `apply` instead of a pipeline.

### Why plan and apply are manual

This is a new-style AWS account on the **Free plan**. AWS attaches a guardrail service control policy (SCP) that denies `iam:*Provider*`, so the GitHub OIDC provider can't be created:

```
$ aws iam list-open-id-connect-providers --profile lab
An error occurred (AccessDenied) ... with an explicit deny in a service control policy
```

An explicit Deny above the account beats any Allow inside it, even full admin. Without OIDC, the only way for Actions to reach AWS would be stored access keys, which this project doesn't use anywhere.

---

## Rebuild

```bash
aws login --profile lab            # short-lived credentials, no access keys
terraform init
terraform plan -out=tfplan         # expect: 6 to add
terraform apply tfplan
curl "$(terraform output -raw url)"  # new random URL, count starts at 1
```

Destroy (root only, never `bootstrap/`):

```bash
terraform plan -destroy            # read it first
terraform destroy
terraform state list               # empty afterwards; the old URL answers 403
```

---

## Security decisions

- **No access keys.** CLI and Terraform use `aws login` (session up to 12 h, credentials refresh by themselves).
- **State bucket:** versioning (a bad write can be rolled back), all four public-access blocks on, encryption at rest, native S3 locking (`use_lockfile`, a `.tflock` object during plan/apply; no DynamoDB lock table).
- **Least privilege:** the Lambda role can only `UpdateItem` on one table and write to its own log group. `GetItem` was dropped because the code never reads; `CreateLogGroup` isn't needed because Terraform creates the group.
- **Public URL, limited:** `authorization_type = "NONE"` with reserved concurrency 2. This caps how many copies run at once; it does not stop requests arriving or cap the monthly total. The account has no card attached, and the project is destroyed when not in use.
- **Logs expire** after 7 days.
- **CI supply chain:** every action pinned by full 40-character commit SHA (verified with `git ls-remote`), with the tag as a comment.
- **Trivy** scans the Terraform on every PR. One finding is accepted in `.trivyignore`: `AWS-0132` (no customer-managed KMS key; ~USD 1/month for a single-owner learning bucket, revisit if it ever holds real data).
- **Nothing sensitive in Git:** `.gitignore` covers `.terraform/`, `*.tfstate`, `*.tfstate.backup`, `*.tfvars`, `tfplan` (a saved plan holds the full config and values) and `build/`. The account ID lives in a GitHub repository variable, not in the code.
- **Tags everywhere** through `default_tags` (`project`, `owner`, `managed-by = terraform`).

---

## GitHub OIDC (written but off)

One-line model: **GitHub vouches for the run, AWS trusts GitHub.** For each workflow run, GitHub signs a short-lived token saying which repo and branch it comes from. Nothing is stored in GitHub secrets.

`oidc.tf` has three parts:

- **The OIDC provider**: AWS writing down "I trust tokens signed by GitHub". It doesn't fetch tokens; GitHub issues them itself. `client_id_list = ["sts.amazonaws.com"]` is the **audience** AWS accepts.
- **The trust policy** (`github_trust`, the "who"): `sts:AssumeRoleWithWebIdentity` for the `Federated` GitHub principal, with exact `StringEquals` matches (no wildcards) on audience `sts.amazonaws.com` and subject `repo:Rayyan98Dev/aws-serverless-visit-counter:ref:refs/heads/main` or `...:pull_request`.
- **Two permissions policies** (the "what"): AWS's ready-made `ReadOnlyAccess`, so `plan` can read the real resources; and my own `github_ci_state`, because read-only can't touch the lock file. It lists the one bucket, reads only the state key, and reads/writes/deletes only the `.tflock` key (plan takes the lock too).

In the workflow, `terraform-plan-oidc` needs `terraform-checks` to pass first. Its `configure-aws-credentials` step is the actual login: with `permissions: id-token: write` it gets GitHub's token and swaps it for temporary credentials for the CI role. `-input=false` makes Terraform fail instead of waiting for someone to type, since a runner has no one to answer.

It is **off twice**:

| Switch | What it stops |
|---|---|
| Terraform variable `enable_github_oidc = false` (`count = 0` on every OIDC block) | the provider and role are never created |
| Repository variable `ENABLE_OIDC` not `'true'` | the `terraform-plan-oidc` job is skipped |

The CI job only **plans**. A real pipeline would apply on merge to `main` with a separate role that has write permissions, usually behind an approval gate.

### Turning it on in an account without the SCP

1. Remove `profile = "lab"` from the `backend` and `provider` blocks (use `AWS_PROFILE=lab` on the laptop). Otherwise `init` on a runner stops with "failed to get shared config profile, lab": nothing falls back to `default`.
2. Apply with `enable_github_oidc = true`, **by hand**: CI can't create its own way in.
3. In GitHub, set the repository variables `AWS_ACCOUNT_ID` and `ENABLE_OIDC=true`.
4. Open a PR and check that `terraform-plan-oidc` runs and prints a plan.

---

## Disaster recovery

If the laptop dies, only **bootstrap's local state** is lost. The bucket and root's state stay in AWS, and the code is in Git. Rebuild bootstrap's state with:

```bash
cd bootstrap
terraform init
B=rayyan98dev-aws-serverless-visit-counter-tfstate
terraform import aws_s3_bucket.state "$B"
terraform import aws_s3_bucket_versioning.state "$B"
terraform import aws_s3_bucket_public_access_block.state "$B"
terraform import aws_s3_bucket_server_side_encryption_configuration.state "$B"
terraform plan                     # expect: No changes
```

Destroying `bootstrap/` is a different and much worse case: it would delete the bucket that holds root's state, leaving anything still running in AWS unmanaged. (Today it would actually fail half-way with `BucketNotEmpty`, after removing versioning and the public-access block. That is why `prevent_destroy` is first on the list below.)

---

## Known gaps / what I'd do next

- `lifecycle { prevent_destroy = true }` on the state bucket, so a destroy plan fails before touching anything.
- Remove `profile = "lab"` from the code (needed for OIDC anyway).
- Replace `ReadOnlyAccess` with only the read actions `plan` needs for these resource types. `ReadOnlyAccess` can read **every object in every bucket**, including state, and state can hold secrets.
- Narrow the Trivy ignore to one path with `.trivyignore.yaml`; it currently applies to the whole repo by rule ID, so a future bucket would be skipped silently.
- Bump the Trivy version CI runs (0.70.0 skipped at least one check).
- Log a line per request from the handler (the log group only has Lambda's START/END/REPORT lines).

## What I learned

- Docker packages the **app**; Terraform describes the **infrastructure** it runs on, so it can be reviewed in a PR and rebuilt with one command instead of clicking through the console. (AWS's own CloudFormation does a similar job for AWS only; Terraform works across providers.) Terraform only manages what is in its state: what it created or was given through `import`.
- Terraform has three places: **code** (Git, what I want), **state** (S3 / local file, what Terraform remembers) and **real infrastructure** (AWS, what exists). A stale plan means state moved; drift means reality moved; changed code is just the next change.
- `backend` decides where state lives; `provider` decides where resources are created. With no provider block, my first apply went to Frankfurt and hit an SCP deny.
- A `data` block writes policy JSON; a `resource` creates something and attaches it.
- Lambda allows one change at a time per function: parallel permission changes gave a 409, fixed with `apply -parallelism=1`, then by removing the duplicate permissions entirely.
- A saved plan is the reviewed decision: read it before saving, because nothing asks again.
