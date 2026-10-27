#!/usr/bin/env bash
# Live run used for the terminal screenshot: one uncached Q6 per version at 1,769 MB,
# then the plain boto3 download speed at the smallest and largest memory size.
cd "$(dirname "$0")"
F=s3://@BUCKET@/sf10/lineitem_default.parquet
q6() {
  ./invoke.sh "$1" "{\"action\":\"bench\",\"query\":\"q6\",\"runs\":1,\"path\":\"$F\"}" \
    | jq -r '"  duckdb \(.duckdb)   \(.seconds[0]*10|round/10) s"'
}
tp() {
  ./invoke.sh "$1" "{\"action\":\"throughput\",\"runs\":1,\"path\":\"$F\"}" \
    | jq -r '"  \(.lambda_mb) MB Lambda   \(.runs[0].MB_per_s) MB/s"'
}
echo '# lineitem SF10 in S3'
echo '# 60M rows, 2.2 GB, 488 row groups'
echo
echo 'Q6, one uncached run, 1769 MB Lambda'
q6 1-5-6-1769
q6 2-0-0-1769
echo
echo 'boto3 download of the same file'
tp 2-0-0-1769
tp 2-0-0-10240
read -r -p '' _
