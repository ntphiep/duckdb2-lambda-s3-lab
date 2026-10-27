#!/usr/bin/env bash
# Deletes everything setup.sh created, then lists whatever still carries the project tag.
set -euo pipefail
cd "$(dirname "$0")"
. "${LAB_ENV:-./lab.env}"
export AWS_DEFAULT_REGION=$REGION

for f in $FUNCS; do
  aws lambda delete-function --function-name "$f" || true
  aws logs delete-log-group --log-group-name "/aws/lambda/$f" 2>/dev/null || true
done
for l in $(aws lambda list-layers --query "Layers[?starts_with(LayerName, '$NAME')].LayerName" --output text); do
  for ver in $(aws lambda list-layer-versions --layer-name "$l" --query 'LayerVersions[].Version' --output text); do
    aws lambda delete-layer-version --layer-name "$l" --version-number "$ver"
  done
done
aws s3 rm "s3://$BUCKET" --recursive --quiet
aws s3api delete-bucket --bucket "$BUCKET"
aws iam detach-role-policy --role-name "$NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role-policy --role-name "$NAME" --policy-name s3
aws iam delete-role --role-name "$NAME"

echo "left over with tag Project=$NAME:"
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values="$NAME" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
