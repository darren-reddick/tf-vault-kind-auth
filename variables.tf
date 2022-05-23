variable "azs" {
  type = list(any)
  default = [
    "eu-west-1a",
    "eu-west-1b",
    "eu-west-1c"
  ]
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "prefix" {
  type        = string
  description = "The prefix for resources created"
  default     = "vault"
}

variable "single_nat_gateway" {
  type        = bool
  description = "Only create a single NAT gateway - useful option for testing"
  default     = true
}