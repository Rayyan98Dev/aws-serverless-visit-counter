import os
import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

def handler(event, context):
    resp = table.update_item(
        Key={"id": "home"},
        UpdateExpression="ADD visits :one",
        ExpressionAttributeValues={":one": 1},
        ReturnValues="UPDATED_NEW",
    )
    count = int(resp["Attributes"]["visits"])
    return {"statusCode": 200,
            "body": f"Hello from Catto! This page has been visited {count} times.\n"}