#!/bin/sh
# local-test.sh — tests the local file upload path for additional_scripts.
# This script is sourced from a local path in the Terraform config and uploaded
# to S3 automatically by the module. It runs inside the container before NIM starts
# (SageMaker) or as an init container before the pod starts (EKS).

echo "=== additional_scripts local-test.sh ==="
echo "Host: $(hostname)"
echo "Date: $(date -u)"
echo "User: $(id)"
echo "AWS region: ${AWS_DEFAULT_REGION:-not set}"
echo "=== local-test.sh complete ==="
