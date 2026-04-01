terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.67"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    s3       = var.localstack_endpoint
    dynamodb = var.localstack_endpoint
    iam      = var.localstack_endpoint
    kms      = var.localstack_endpoint
    lambda   = var.localstack_endpoint
    sts      = var.localstack_endpoint
  }
}

locals {
  env            = terraform.workspace
  bucket_name    = "fintech-payment-events-${local.env}"
  table_name     = "transactions-${local.env}"
  function_name  = "process-payment-${local.env}"
  role_name      = "lambda-payment-processor-role-${local.env}"
  policy_name    = "lambda-payment-processor-policy-${local.env}"
  kms_alias_name = "alias/fintech-cmk-${local.env}"
}

resource "aws_kms_key" "fintech_key" {
  description             = "Customer managed key for fintech payment data encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "fintech_key_alias" {
  name          = local.kms_alias_name
  target_key_id = aws_kms_key.fintech_key.key_id
}

resource "aws_s3_bucket" "payment_events" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_versioning" "payment_events_versioning" {
  bucket = aws_s3_bucket.payment_events.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "payment_events_encryption" {
  bucket = aws_s3_bucket.payment_events.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.fintech_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "payment_events_public_access_block" {
  bucket                  = aws_s3_bucket.payment_events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "transactions" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "TransactionID"

  attribute {
    name = "TransactionID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.fintech_key.arn
  }
}

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_payment_processor_role" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid = "CloudWatchLogsWrite"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    sid       = "ReadPaymentEventObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.payment_events.arn}/*"]
  }

  statement {
    sid       = "WriteTransactions"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.transactions.arn]
  }

  statement {
    sid       = "DecryptWithCmk"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.fintech_key.arn]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name   = local.policy_name
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_payment_processor_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/process_payment.py"
  output_path = "${path.module}/process_payment.zip"
}

resource "aws_lambda_function" "process_payment" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_payment_processor_role.arn
  runtime       = "python3.9"
  handler       = "process_payment.handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.transactions.name
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_policy_attachment]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_payment.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.payment_events.arn
}

resource "aws_s3_bucket_notification" "payment_events_notifications" {
  bucket = aws_s3_bucket.payment_events.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.process_payment.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
