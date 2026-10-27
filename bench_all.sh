#!/usr/bin/env bash
# Runs TPC-H Q6 (and Q1) against both Parquet files on every function, 3 uncached runs each.
# Functions run in parallel, runs inside one function run one after another.
set -euo pipefail
cd "$(dirname "$0")"
. ./lab.env
RUNS=${RUNS:-3}
mkdir -p results/bench

one_function() {
  local suffix=$1 variants
  if [[ $suffix == 2-0-0-* ]]; then variants='{} {"read_ahead_depth":0}'; else variants='{}'; fi
  for file in lineitem_default lineitem_rg128mb; do
    for q in q6 q1; do
      for s in $variants; do
        tag=$([ "$s" = '{}' ] && echo default || echo readahead0)
        ./invoke.sh "$suffix" "{\"action\":\"bench\",\"query\":\"$q\",\"runs\":$RUNS,\"settings\":$s,\"path\":\"s3://@BUCKET@/sf10/$file.parquet\"}" \
          "results/bench/$suffix.$file.$q.$tag.json" >/dev/null
      done
    done
  done
}

for f in $FUNCS; do one_function "${f#$NAME-}" & done
wait
echo done
