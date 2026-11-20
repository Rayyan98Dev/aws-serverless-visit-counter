terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source = "hashicorp/aws", version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "rayyan98dev-aws-serverless-visit-counter-tfstate"
    key          = "visit-counter/terraform.tfstate"
    region       = "eu-north-1"
    use_lockfile = true
    encrypt      = true
    profile      = "lab"
  }
}

provider "aws" {
  region  = "eu-north-1"
  profile = "lab"
}
