# AWS Payments API Infrastructure with Terraform

Terraform project for a serverless fintech payments workflow running locally on LocalStack.

The stack provisions:

- An S3 bucket for payment events
- A Lambda function that reads uploaded events and writes transaction records
- A DynamoDB table for processed transactions
- A customer-managed KMS key for encryption at rest
- A least-privilege IAM role and policy for the Lambda function

The repository is designed for local-first infrastructure development. All AWS calls can be directed to LocalStack so the stack can be validated without using a real AWS account.

## Repository Layout

- `main.tf` - Terraform provider and resource definitions
- `variables.tf` - Terraform variables
- `outputs.tf` - Useful Terraform outputs
- `docker-compose.yml` - LocalStack service definition
- `src/process_payment.py` - Lambda handler code
- `compliance_check.sh` - Verification script for the deployed stack
- `.env.example` - Example environment variables for LocalStack

## Prerequisites

Install the following tools before running the project:

- Docker and Docker Compose
- Terraform
- AWS CLI
- `jq`
- Bash-compatible shell

## LocalStack Setup

1. Start LocalStack:

	```bash
	docker compose up -d
	```

2. Verify the health endpoint:

	```bash
	curl http://localhost:4566/health
	```

3. Create a local environment file:

	```bash
	cp .env.example .env
	```

4. Load the environment variables:

	```bash
	source .env
	```

The environment file points the AWS CLI and SDK calls to LocalStack using `AWS_ENDPOINT_URL=http://localhost:4566`.

## Terraform Workflow

Initialize Terraform:

```bash
terraform init
```

Create the workspaces used by this project:

```bash
terraform workspace new dev
terraform workspace new staging
terraform workspace select dev
```

Apply the infrastructure to the active workspace:

```bash
terraform apply -auto-approve
```

Resource names are parameterized by `terraform.workspace`, so the active workspace changes the deployed names.

## Compliance Verification

The compliance script checks the main security and wiring requirements:

- LocalStack health
- KMS customer-managed key
- S3 versioning, encryption, and public access blocking
- DynamoDB encryption
- Lambda IAM policy least privilege
- Lambda trigger configuration

Make the script executable and run it for the `dev` workspace:

```bash
chmod +x compliance_check.sh
./compliance_check.sh dev
```

Optional end-to-end validation is also available:

```bash
./compliance_check.sh dev --e2e
```

## End-to-End Flow

1. Upload a JSON payment event to the S3 bucket.
2. S3 sends an `s3:ObjectCreated:*` event to Lambda.
3. The Lambda function reads the uploaded object from S3.
4. The function writes a transaction record into DynamoDB.

Example test file:

```bash
printf '{"paymentId":"123","amount":100}' > payment.json
aws s3 cp payment.json s3://fintech-payment-events-dev/
aws dynamodb scan --table-name transactions-dev
```

## Security Controls

- S3 public access is fully blocked.
- S3 and DynamoDB are encrypted with a customer-managed KMS key.
- The Lambda IAM policy grants only the permissions it needs.
- Workspace-based naming keeps dev and staging state isolated.

## Troubleshooting

- If Terraform cannot reach AWS APIs, confirm LocalStack is running and `AWS_ENDPOINT_URL` is set to `http://localhost:4566`.
- If the Lambda trigger does not fire, verify the S3 bucket notification and the `aws_lambda_permission` resource.
- If the compliance script fails, check that `aws`, `jq`, and `curl` are installed and that the resources were applied in the correct workspace.


