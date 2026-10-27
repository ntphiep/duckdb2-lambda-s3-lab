#!/usr/bin/env bash
# usage: ./invoke.sh <function-suffix> '<json event>' [results/file.json]
# Invokes one lab function synchronously and prints (and optionally saves) its JSON result.
set -euo pipefail
cd "$(dirname "$0")"
. ./lab.env
export AWS_DEFAULT_REGION=$REGION
out=$(mktemp)
aws lambda invoke --function-name "$NAME-$1" --cli-read-timeout 0 --cli-binary-format raw-in-base64-out \
  --payload "${2//@BUCKET@/$BUCKET}" "$out" >/dev/null
python3 -m json.tool "$out" | tee ${3:+"$3"}
rm -f "$out"
