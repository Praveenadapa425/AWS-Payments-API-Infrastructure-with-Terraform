output "workspace" {
  description = "Active Terraform workspace"
  value       = terraform.workspace
}

output "kms_key_arn" {
  description = "Customer-managed KMS key ARN"
  value       = aws_kms_key.fintech_key.arn
}

output "s3_bucket_name" {
  description = "S3 bucket receiving payment events"
  value       = aws_s3_bucket.payment_events.bucket
}

output "dynamodb_table_name" {
  description = "DynamoDB transactions table"
  value       = aws_dynamodb_table.transactions.name
}

output "lambda_function_name" {
  description = "Lambda function processing S3 events"
  value       = aws_lambda_function.process_payment.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.process_payment.arn
}

output "lambda_policy_arn" {
  description = "Least-privilege IAM policy ARN attached to Lambda role"
  value       = aws_iam_policy.lambda_policy.arn
}
