variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "single_nat_gateway" {
  type        = bool
  description = "Only create a single NAT gateway - useful option for testing"
  default     = true
}