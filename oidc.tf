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