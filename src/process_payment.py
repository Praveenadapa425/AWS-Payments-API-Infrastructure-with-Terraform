import json
import os
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import unquote_plus

import boto3

LOCALSTACK_HOSTNAME = os.environ.get("LOCALSTACK_HOSTNAME", "localhost")
EDGE_PORT = os.environ.get("EDGE_PORT", "4566")
AWS_ENDPOINT_URL = os.environ.get(
    "AWS_ENDPOINT_URL", f"http://{LOCALSTACK_HOSTNAME}:{EDGE_PORT}"
)
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
DYNAMODB_TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]

s3_client = boto3.client("s3", endpoint_url=AWS_ENDPOINT_URL, region_name=AWS_REGION)
dynamodb = boto3.resource(
    "dynamodb", endpoint_url=AWS_ENDPOINT_URL, region_name=AWS_REGION
)
table = dynamodb.Table(DYNAMODB_TABLE_NAME)


def _read_event_payload(bucket_name: str, object_key: str) -> dict:
    response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
    body_text = response["Body"].read().decode("utf-8")

    try:
        return json.loads(body_text, parse_float=Decimal)
    except json.JSONDecodeError:
        return {}


def _safe_decimal(value):
    if isinstance(value, Decimal):
        return value
    try:
        return Decimal(str(value))
    except Exception:
        return None


def handler(event, context):
    print(json.dumps(event))
    processed = 0

    for record in event.get("Records", []):
        bucket_name = record["s3"]["bucket"]["name"]
        object_key = unquote_plus(record["s3"]["object"]["key"])

        payload = _read_event_payload(bucket_name, object_key)
        payment_id = str(payload.get("paymentId", "")).strip()

        if payment_id:
            transaction_id = payment_id
        else:
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            transaction_id = f"{object_key}-{timestamp}"

        item = {
            "TransactionID": transaction_id,
            "Bucket": bucket_name,
            "ObjectKey": object_key,
            "Status": "PROCESSED",
            "ProcessedAt": datetime.now(timezone.utc).isoformat(),
        }

        amount = _safe_decimal(payload.get("amount"))
        if amount is not None:
            item["Amount"] = amount

        table.put_item(Item=item)
        processed += 1
        print(f"Processed {object_key} from {bucket_name}. TransactionID: {transaction_id}")

    return {"status": "success", "recordsProcessed": processed}
