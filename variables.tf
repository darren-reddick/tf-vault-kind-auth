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

variable "terraform_config" {
  type = map
  default = {
    providers = { 
      aws = {
        source  = "hashicorp/aws"
        version = ">=3.63.0"
      }
    }
  }
}