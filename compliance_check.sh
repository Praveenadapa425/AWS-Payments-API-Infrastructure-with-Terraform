#!/usr/bin/env bash
set -Eeuo pipefail

# Production-grade compliance checks for the LocalStack Terraform fintech stack.
# Usage:
#   ./compliance_check.sh [workspace] [--e2e]
# Example:
#   ./compliance_check.sh dev --e2e

on_error() {
  local line="$1"
  echo "[ERROR] Compliance check failed at line ${line}." >&2
}
trap 'on_error ${LINENO}' ERR

WORKSPACE="${1:-dev}"
RUN_E2E="${2:-}"

if [[ "${WORKSPACE}" == "--e2e" ]]; then
  WORKSPACE="dev"
  RUN_E2E="--e2e"
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_ENDPOINT_URL

BUCKET_NAME="fintech-payment-events-${WORKSPACE}"
TABLE_NAME="transactions-${WORKSPACE}"
FUNCTION_NAME="process-payment-${WORKSPACE}"
POLICY_NAME="lambda-payment-processor-policy-${WORKSPACE}"
KMS_ALIAS_NAME="alias/fintech-cmk-${WORKSPACE}"

required_tools=(aws jq curl)
for tool in "${required_tools[@]}"; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "[ERROR] Required tool not found: ${tool}" >&2
    exit 1
  fi
done

aws_ls() {
  aws --endpoint-url="${AWS_ENDPOINT_URL}" "$@"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "${expected}" != "${actual}" ]]; then
    echo "[FAIL] ${message}" >&2
    echo "       expected: ${expected}" >&2
    echo "       actual  : ${actual}" >&2
    exit 1
  fi

  echo "[PASS] ${message}"
}

assert_non_empty() {
  local value="$1"
  local message="$2"

  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "[FAIL] ${message}" >&2
    exit 1
  fi

  echo "[PASS] ${message}"
}

echo "=== Compliance Check Start (workspace: ${WORKSPACE}) ==="

echo "[CHECK] LocalStack health"
HEALTH_JSON="$(curl -sS "${AWS_ENDPOINT_URL}/health")"
assert_non_empty "${HEALTH_JSON}" "Health endpoint is reachable"

for service in s3 dynamodb iam kms lambda; do
  status="$(echo "${HEALTH_JSON}" | jq -r --arg svc "${service}" '.services[$svc] // empty')"
  if [[ "${status}" != "running" && "${status}" != "available" && "${status}" != "enabled" ]]; then
    echo "[FAIL] Service ${service} is not healthy (status: ${status:-unknown})" >&2
    exit 1
  fi
  echo "[PASS] Service ${service} status is ${status}"
done

echo "[CHECK] KMS customer-managed key"
KMS_KEY_ARN="$(aws_ls kms describe-key --key-id "${KMS_ALIAS_NAME}" | jq -r '.KeyMetadata.Arn')"
KMS_KEY_MANAGER="$(aws_ls kms describe-key --key-id "${KMS_ALIAS_NAME}" | jq -r '.KeyMetadata.KeyManager')"
KMS_KEY_SPEC="$(aws_ls kms describe-key --key-id "${KMS_ALIAS_NAME}" | jq -r '.KeyMetadata.KeySpec')"

assert_non_empty "${KMS_KEY_ARN}" "KMS key ARN resolved from alias ${KMS_ALIAS_NAME}"
assert_equals "CUSTOMER" "${KMS_KEY_MANAGER}" "KMS KeyManager is CUSTOMER"
assert_equals "SYMMETRIC_DEFAULT" "${KMS_KEY_SPEC}" "KMS KeySpec is SYMMETRIC_DEFAULT"

echo "[CHECK] S3 bucket versioning"
VERSIONING_STATUS="$(aws_ls s3api get-bucket-versioning --bucket "${BUCKET_NAME}" | jq -r '.Status')"
assert_equals "Enabled" "${VERSIONING_STATUS}" "S3 bucket versioning is enabled"

echo "[CHECK] S3 bucket encryption"
S3_ENCRYPTION_JSON="$(aws_ls s3api get-bucket-encryption --bucket "${BUCKET_NAME}")"
S3_SSE_ALGO="$(echo "${S3_ENCRYPTION_JSON}" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm')"
S3_KMS_ARN="$(echo "${S3_ENCRYPTION_JSON}" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID')"

assert_equals "aws:kms" "${S3_SSE_ALGO}" "S3 SSE algorithm is aws:kms"
assert_equals "${KMS_KEY_ARN}" "${S3_KMS_ARN}" "S3 bucket uses the expected customer KMS key"

echo "[CHECK] S3 public access block"
S3_PAB_JSON="$(aws_ls s3api get-public-access-block --bucket "${BUCKET_NAME}")"
assert_equals "true" "$(echo "${S3_PAB_JSON}" | jq -r '.PublicAccessBlockConfiguration.BlockPublicAcls')" "BlockPublicAcls is true"
assert_equals "true" "$(echo "${S3_PAB_JSON}" | jq -r '.PublicAccessBlockConfiguration.BlockPublicPolicy')" "BlockPublicPolicy is true"
assert_equals "true" "$(echo "${S3_PAB_JSON}" | jq -r '.PublicAccessBlockConfiguration.IgnorePublicAcls')" "IgnorePublicAcls is true"
assert_equals "true" "$(echo "${S3_PAB_JSON}" | jq -r '.PublicAccessBlockConfiguration.RestrictPublicBuckets')" "RestrictPublicBuckets is true"

echo "[CHECK] DynamoDB table encryption"
DDB_TABLE_JSON="$(aws_ls dynamodb describe-table --table-name "${TABLE_NAME}")"
DDB_SSE_STATUS="$(echo "${DDB_TABLE_JSON}" | jq -r '.Table.SSEDescription.Status')"
DDB_KMS_ARN="$(echo "${DDB_TABLE_JSON}" | jq -r '.Table.SSEDescription.KMSMasterKeyArn')"

assert_equals "ENABLED" "${DDB_SSE_STATUS}" "DynamoDB SSE is ENABLED"
assert_equals "${KMS_KEY_ARN}" "${DDB_KMS_ARN}" "DynamoDB table uses the expected customer KMS key"

echo "[CHECK] IAM least-privilege policy"
POLICY_ARN="$(aws_ls iam list-policies --scope Local | jq -r --arg name "${POLICY_NAME}" '.Policies[] | select(.PolicyName == $name) | .Arn' | head -n1)"
assert_non_empty "${POLICY_ARN}" "IAM policy ARN resolved (${POLICY_NAME})"

POLICY_VERSION_ID="$(aws_ls iam get-policy --policy-arn "${POLICY_ARN}" | jq -r '.Policy.DefaultVersionId')"
assert_non_empty "${POLICY_VERSION_ID}" "IAM policy default version found"

POLICY_DOC_JSON="$(aws_ls iam get-policy-version --policy-arn "${POLICY_ARN}" --version-id "${POLICY_VERSION_ID}")"

mapfile -t ACTIONS < <(echo "${POLICY_DOC_JSON}" | jq -r '
  .PolicyVersion.Document.Statement[]?.Action
  | if type == "array" then .[] else . end
')

if [[ "${#ACTIONS[@]}" -eq 0 ]]; then
  echo "[FAIL] IAM policy has no actions to evaluate" >&2
  exit 1
fi

for action in "${ACTIONS[@]}"; do
  if [[ "${action}" == "*" ]]; then
    echo "[FAIL] Forbidden wildcard action '*' found" >&2
    exit 1
  fi

  if [[ "${action}" == *"*"* ]]; then
    if [[ "${action}" != logs:* ]]; then
      echo "[FAIL] Forbidden wildcard action found: ${action}" >&2
      exit 1
    fi
  fi
done
echo "[PASS] IAM policy has no forbidden wildcard actions"

required_actions=("s3:GetObject" "dynamodb:PutItem" "kms:Decrypt")
for required_action in "${required_actions[@]}"; do
  if ! printf '%s\n' "${ACTIONS[@]}" | grep -Fxq "${required_action}"; then
    echo "[FAIL] Required action missing from IAM policy: ${required_action}" >&2
    exit 1
  fi
done
echo "[PASS] IAM policy contains required actions"

echo "[CHECK] Lambda function exists"
LAMBDA_JSON="$(aws_ls lambda get-function --function-name "${FUNCTION_NAME}")"
LAMBDA_ARN="$(echo "${LAMBDA_JSON}" | jq -r '.Configuration.FunctionArn')"
assert_non_empty "${LAMBDA_ARN}" "Lambda function is retrievable"

echo "[CHECK] S3 bucket notification invokes Lambda"
NOTIFY_JSON="$(aws_ls s3api get-bucket-notification-configuration --bucket "${BUCKET_NAME}")"
NOTIFY_MATCH_COUNT="$(echo "${NOTIFY_JSON}" | jq -r --arg arn "${LAMBDA_ARN}" '[.LambdaFunctionConfigurations[]? | select(.LambdaFunctionArn == $arn and (.Events | index("s3:ObjectCreated:*")))] | length')"
assert_equals "1" "${NOTIFY_MATCH_COUNT}" "S3 notification contains expected Lambda + event"

if [[ "${RUN_E2E}" == "--e2e" ]]; then
  echo "[CHECK] Optional E2E trigger path"
  TEST_FILE="test-event-$(date +%s)-$RANDOM.json"
  printf '{"paymentId":"%s","amount":100.00}\n' "${TEST_FILE}" > "${TEST_FILE}"

  aws_ls s3 cp "${TEST_FILE}" "s3://${BUCKET_NAME}/${TEST_FILE}" >/dev/null
  sleep 10

  SCAN_JSON="$(aws_ls dynamodb scan --table-name "${TABLE_NAME}")"
  MATCH_COUNT="$(echo "${SCAN_JSON}" | jq -r --arg key "${TEST_FILE}" '[.Items[]? | select(.ObjectKey.S == $key)] | length')"
  assert_equals "1" "${MATCH_COUNT}" "DynamoDB contains item for uploaded S3 object"

  rm -f "${TEST_FILE}"
fi

echo "=== All compliance checks passed for workspace: ${WORKSPACE} ==="
