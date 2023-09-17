terraform {
  required_providers {
    var.terraform_config.providers
  }
}

provider "aws" {
  region = var.aws_region
}
