#!/usr/bin/env python3
"""Upload linux seed binary to S3 and run it on an in-service ASG instance (RDS is VPC-private)."""
import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
REGION = os.environ.get("AWS_REGION", "ap-south-1")
TARGET = int(os.environ.get("SEED_TARGET", "50000"))
BATCH = int(os.environ.get("SEED_BATCH", "5000"))
TIMEOUT = int(os.environ.get("SEED_SSM_TIMEOUT", "7200"))


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


def get_command_invocation(ssm, command_id: str, instance_id: str):
    try:
        return ssm.get_command_invocation(
            CommandId=command_id, InstanceId=instance_id
        )
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code == "InvocationDoesNotExist":
            return None
        raise


def terraform_output(name: str) -> str:
    out = subprocess.run(
        ["terraform", "output", "-raw", name],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.strip()


def main():
    bucket = terraform_output("artifacts_bucket")
    project = terraform_output("project_name")
    asg_name = f"{project}-api"

    print("Building linux/amd64 seed binary...")
    subprocess.run(
        [
            "go",
            "build",
            "-o",
            "/tmp/scalelab-seed",
            "./cmd/seed",
        ],
        cwd=ROOT / "backend",
        env={**os.environ, "CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "amd64"},
        check=True,
    )

    session = session_from_login_cache()
    s3 = session.client("s3")
    key = "api/scalelab-seed"
    s3.upload_file("/tmp/scalelab-seed", bucket, key)
    print(f"Uploaded s3://{bucket}/{key}")

    asg = session.client("autoscaling")
    groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])[
        "AutoScalingGroups"
    ]
    if not groups:
        raise SystemExit(f"ASG not found: {asg_name}")
    instances = [
        i["InstanceId"]
        for i in groups[0]["Instances"]
        if i["LifecycleState"] == "InService"
    ]
    if not instances:
        raise SystemExit(f"No InService instances in {asg_name}")
    instance_id = instances[0]
    print(f"Running seed on instance {instance_id} (target={TARGET}, batch={BATCH})...")

    shell = f"""set -euo pipefail
REGION={REGION}
BUCKET={bucket}
sudo /opt/scalelab/refresh-env.sh
set -a && source /opt/scalelab/env && set +a
aws s3 cp "s3://$BUCKET/{key}" /tmp/scalelab-seed --region "$REGION"
chmod +x /tmp/scalelab-seed
/tmp/scalelab-seed -target {TARGET} -batch {BATCH}
"""

    ssm = session.client("ssm")
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        TimeoutSeconds=TIMEOUT,
        Parameters={"commands": [shell]},
    )
    command_id = resp["Command"]["CommandId"]
    print(f"SSM command {command_id} (timeout {TIMEOUT}s)...")
    print("Waiting for SSM to register invocation on the instance...")

    deadline = time.time() + TIMEOUT
    last_out = ""
    while time.time() < deadline:
        inv = get_command_invocation(ssm, command_id, instance_id)
        if inv is None:
            time.sleep(5)
            continue
        status = inv["Status"]
        out = inv.get("StandardOutputContent") or ""
        if out != last_out and out.strip():
            # Stream seed progress (logs every 50k rows) while SSM is InProgress
            print(out[len(last_out) :] if out.startswith(last_out) else out, end="", flush=True)
            last_out = out
        if status in ("Success", "Cancelled", "TimedOut", "Failed"):
            if out and out != last_out:
                print(out[len(last_out) :] if out.startswith(last_out) else out, end="")
            if inv.get("StandardErrorContent"):
                print(inv["StandardErrorContent"], file=sys.stderr)
            if status != "Success":
                raise SystemExit(f"Seed failed: {status} — {inv.get('StatusDetails')}")
            print("Seed finished successfully.")
            return
        time.sleep(15)
    raise SystemExit("Timed out waiting for SSM seed command")


if __name__ == "__main__":
    main()
