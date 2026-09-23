#!/usr/bin/env python3
"""Phase 2 deploy: S3 upload + ASG instance refresh (works with aws login cache)."""
import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import boto3

ROOT = Path(__file__).resolve().parents[1]
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
    subprocess.run(
        ["go", "build", "-o", "/tmp/scalelab-api", "./cmd/api"],
        cwd=ROOT / "backend",
        env={**os.environ, "CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "amd64"},
        check=True,
    )
    out = subprocess.run(
        ["terraform", "output", "-raw", "artifacts_bucket"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    bucket = out.stdout.strip()
    if not bucket or bucket == "null":
        raise SystemExit("artifacts_bucket not set — is scaling_phase >= 2 applied?")

    session = session_from_login_cache()
    s3 = session.client("s3")
    s3.upload_file("/tmp/scalelab-api", bucket, "api/scalelab-api")
    print(f"Uploaded to s3://{bucket}/api/scalelab-api")

    name = subprocess.run(
        ["terraform", "output", "-raw", "project_name"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    asg_name = f"{name}-api"
    asg = session.client("autoscaling")
    refresh = asg.start_instance_refresh(
        AutoScalingGroupName=asg_name,
        Preferences={"MinHealthyPercentage": 50, "InstanceWarmup": 120},
    )
    refresh_id = refresh["InstanceRefreshId"]
    print(f"Instance refresh started on {asg_name} ({refresh_id})")

    elbv2 = session.client("elbv2")
    tg_arn = elbv2.describe_target_groups(Names=[f"{name}-api"])["TargetGroups"][0][
        "TargetGroupArn"
    ]
    wait_for_instance_refresh(asg, asg_name, refresh_id)
    wait_for_healthy_targets(elbv2, tg_arn)
    print("Instance refresh complete; ALB targets healthy.")


def wait_for_instance_refresh(asg, asg_name, refresh_id, timeout_sec=900):
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        resp = asg.describe_instance_refreshes(
            AutoScalingGroupName=asg_name, InstanceRefreshIds=[refresh_id]
        )
        refreshes = resp.get("InstanceRefreshes") or []
        if not refreshes:
            time.sleep(10)
            continue
        status = refreshes[0]["Status"]
        if status == "Successful":
            return
        if status in ("Failed", "Cancelled"):
            raise SystemExit(f"Instance refresh {status}: {refreshes[0].get('StatusReason')}")
        print(f"  instance refresh: {status} …")
        time.sleep(15)
    raise SystemExit("Timed out waiting for instance refresh")


def wait_for_healthy_targets(elbv2, tg_arn, timeout_sec=600):
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        desc = elbv2.describe_target_health(TargetGroupArn=tg_arn)
        targets = desc.get("TargetHealthDescriptions") or []
        if not targets:
            print("  waiting for targets to register …")
            time.sleep(10)
            continue
        healthy = [
            t
            for t in targets
            if t.get("TargetHealth", {}).get("State") == "healthy"
        ]
        if healthy and len(healthy) == len(targets):
            return
        states = [t.get("TargetHealth", {}).get("State") for t in targets]
        print(f"  target health: {states} …")
        time.sleep(10)
    raise SystemExit("Timed out waiting for healthy ALB targets")


if __name__ == "__main__":
    main()
