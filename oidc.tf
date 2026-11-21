variable "enable_github_oidc" {
  type        = bool
  default     = false
  description = "Create the GitHub Actions OIDC provider and CI role. Off because this account's SCP denies iam:*Provider*."
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.enable_github_oidc ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_trust" {
  count = var.enable_github_oidc ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:Rayyan98Dev/aws-serverless-visit-counter:ref:refs/heads/main", "repo:Rayyan98Dev/aws-serverless-visit-counter:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  count              = var.enable_github_oidc ? 1 : 0
  name               = "visit-counter-github-ci"
  assume_role_policy = data.aws_iam_policy_document.github_trust[0].json
}

locals {
  state_bucket = "rayyan98dev-aws-serverless-visit-counter-tfstate"
}

data "aws_iam_policy_document" "github_ci_state" {
  count = var.enable_github_oidc ? 1 : 0
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/visit-counter/terraform.tfstate"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/visit-counter/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "github_ci_state" {
  count  = var.enable_github_oidc ? 1 : 0
  name   = "github-ci-state"
  role   = aws_iam_role.github_ci[0].id
  policy = data.aws_iam_policy_document.github_ci_state[0].json
}

resource "aws_iam_role_policy_attachment" "github_ci_readonly" {
  count      = var.enable_github_oidc ? 1 : 0
  role       = aws_iam_role.github_ci[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}