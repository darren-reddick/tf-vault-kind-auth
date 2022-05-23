terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=3.63.0"
    }
  }
}

// AWS provider options
provider "aws" {
  region = var.aws_region
}