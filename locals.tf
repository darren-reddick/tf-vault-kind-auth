locals {
  prefix                = var.prefix
  cluster_init_sec_name = "${var.prefix}-cluster-init-output"
}

data "aws_caller_identity" "current" {}