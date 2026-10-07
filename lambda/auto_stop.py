"""Stop every running instance tagged TAG_KEY=TAG_VALUE (nightly safety net for k3s-dev)."""

import os

import boto3

ec2 = boto3.client("ec2")


def handler(event, context):
    tag_key = os.environ["TAG_KEY"]
    tag_value = os.environ["TAG_VALUE"]

    paginator = ec2.get_paginator("describe_instances")
    pages = paginator.paginate(
        Filters=[
            {"Name": f"tag:{tag_key}", "Values": [tag_value]},
            {"Name": "instance-state-name", "Values": ["pending", "running"]},
        ]
    )
    ids = [i["InstanceId"] for page in pages for r in page["Reservations"] for i in r["Instances"]]

    if not ids:
        print(f"nothing running with {tag_key}={tag_value}")
        return {"stopped": []}

    ec2.stop_instances(InstanceIds=ids)
    print(f"stopping {len(ids)} instance(s) with {tag_key}={tag_value}: {', '.join(ids)}")
    return {"stopped": ids}
