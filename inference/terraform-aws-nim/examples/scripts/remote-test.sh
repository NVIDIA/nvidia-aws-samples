#!/bin/sh
# remote-test.sh — tests the existing-S3-URI path for additional_scripts.
# Unlike local-test.sh, this script is NOT uploaded by Terraform. It must exist
# in S3 BEFORE terraform apply. The module passes the s3:// URI through unchanged;
# the container downloads and runs the script at startup.
#
# Upload this file to your test bucket first:
#   aws s3 cp examples/scripts/remote-test.sh s3://<your-bucket>/remote-test.sh
# Then reference s3://<your-bucket>/remote-test.sh in additional_scripts.

echo "=== additional_scripts remote-test.sh ==="
echo "Host: $(hostname)"
echo "Date: $(date -u)"
echo "User: $(id)"
echo "Source: pre-existing S3 object (no Terraform upload)"
echo "=== remote-test.sh complete ==="
