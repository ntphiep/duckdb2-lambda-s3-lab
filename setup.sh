#!/usr/bin/env bash
# Creates the S3 bucket, an IAM role, one layer per DuckDB version and one arm64 function
# per (version, memory size). Writes names to lab.env. Run teardown.sh when you are done.
set -euo pipefail
cd "$(dirname "$0")"

REGION=${REGION:-us-east-1}
NAME=${NAME:-duckdb2-async-lab}
VERSIONS=${VERSIONS:-"1.5.6 2.0.0"}
MEMORY=${MEMORY:-"1769 3538 10240"}   # 1, 2 and 6 vCPU
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${BUCKET:-$NAME-$ACCOUNT-$REGION}
export AWS_DEFAULT_REGION=$REGION
TAGS="Project=$NAME"

aws s3api create-bucket --bucket "$BUCKET" >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=Project,Value=$NAME}]"

aws iam create-role --role-name "$NAME" --tags Key=Project,Value=$NAME --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam attach-role-policy --role-name "$NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name "$NAME" --policy-name s3 --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:AbortMultipartUpload\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},
   {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":\"arn:aws:s3:::$BUCKET\"}]}"
ROLE_ARN=$(aws iam get-role --role-name "$NAME" --query Role.Arn --output text)
sleep 10   # a brand-new role is not assumable by Lambda right away

(cd lambda && rm -f ../build/code.zip && zip -q ../build/code.zip bench.py)
FUNCS=()
for v in $VERSIONS; do
  layer=$(aws lambda publish-layer-version --layer-name "$NAME-${v//./-}" --compatible-architectures arm64 \
    --compatible-runtimes python3.13 --zip-file fileb://build/layer-$v.zip --query LayerVersionArn --output text)
  for m in $MEMORY; do
    f="$NAME-${v//./-}-$m"
    aws lambda create-function --function-name "$f" --runtime python3.13 --architectures arm64 \
      --role "$ROLE_ARN" --handler bench.handler --zip-file fileb://build/code.zip --layers "$layer" \
      --memory-size "$m" --timeout 900 --ephemeral-storage Size=10240 --tags "$TAGS" >/dev/null
    FUNCS+=("$f")
  done
done
for f in "${FUNCS[@]}"; do aws lambda wait function-active-v2 --function-name "$f"; done

{
  echo "REGION=$REGION"
  echo "NAME=$NAME"
  echo "BUCKET=$BUCKET"
  echo "FUNCS=\"${FUNCS[*]}\""
} > lab.env
echo "ready, see lab.env"
