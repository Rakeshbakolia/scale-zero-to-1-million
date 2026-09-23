#!/usr/bin/env python3
"""Upload frontend dist to S3 and invalidate CloudFront (aws login cache)."""
import glob
import json
import mimetypes
import os
import sys
from pathlib import Path

import boto3

REGION = os.environ.get("AWS_REGION", "ap-south-1")


def session_from_login_cache():
    cache = sorted(
        glob.glob(str(Path.home() / ".aws/login/cache/*.json")),
        key=os.path.getmtime,
        reverse=True,
    )
    if not cache:
        raise SystemExit("No aws login cache. Run: aws login")
    at = json.load(open(cache[0]))["accessToken"]
    return boto3.Session(
        aws_access_key_id=at["accessKeyId"],
        aws_secret_access_key=at["secretAccessKey"],
        aws_session_token=at["sessionToken"],
        region_name=REGION,
    )


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: deploy-frontend-phase5.py <dist_dir> <bucket> [cloudfront_id]")
    dist = Path(sys.argv[1])
    bucket = sys.argv[2]
    cf_id = sys.argv[3] if len(sys.argv) > 3 else ""

    session = session_from_login_cache()
    s3 = session.client("s3")

    for path in dist.rglob("*"):
        if not path.is_file():
            continue
        key = str(path.relative_to(dist)).replace("\\", "/")
        ctype, _ = mimetypes.guess_type(path.name)
        extra = {"ContentType": ctype} if ctype else {}
        s3.upload_file(str(path), bucket, key, ExtraArgs=extra)
        print(f"  s3://{bucket}/{key}")

    # Remove stale keys not in dist
    paginator = s3.get_paginator("list_objects_v2")
    local_keys = {str(p.relative_to(dist)).replace("\\", "/") for p in dist.rglob("*") if p.is_file()}
    for page in paginator.paginate(Bucket=bucket):
        for obj in page.get("Contents") or []:
            k = obj["Key"]
            if k not in local_keys:
                s3.delete_object(Bucket=bucket, Key=k)
                print(f"  deleted s3://{bucket}/{k}")

    if cf_id and cf_id != "null":
        cf = session.client("cloudfront")
        resp = cf.create_invalidation(
            DistributionId=cf_id,
            InvalidationBatch={
                "Paths": {"Quantity": 1, "Items": ["/*"]},
                "CallerReference": str(os.getpid()),
            },
        )
        print(f"CloudFront invalidation: {resp['Invalidation']['Id']}")


if __name__ == "__main__":
    main()
