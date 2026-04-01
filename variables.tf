variable "aws_region" {
  description = "AWS region used by Terraform and LocalStack"
  type        = string
  default     = "us-east-1"
}

variable "localstack_endpoint" {
  description = "LocalStack edge endpoint"
  type        = string
  default     = "http://localhost:4566"
}

variable "project_name" {
  description = "Project name prefix used for tag-like naming"
  type        = string
  default     = "fintech"
}
