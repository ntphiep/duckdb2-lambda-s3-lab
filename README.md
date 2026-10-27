# duckdb2-lambda-s3-lab

A small lab for [DuckDB 2.0.0](https://duckdb.org/2026/10/21/announcing-duckdb-200), released on
2026-10-21 with asynchronous I/O for Parquet on S3. The
[DuckDB async I/O post](https://duckdb.org/2026/07/31/asynchronous-io) measured it on a 64-vCPU EC2
instance with 25 Gbit networking. This lab runs the same kind of query on AWS Lambda.

The setup is one S3 bucket and six arm64 Lambda functions (Python 3.13, us-east-1): DuckDB 1.5.6 and
2.0.0, each at 1,769 MB, 3,538 MB and 10,240 MB. The data is TPC-H SF10 `lineitem` (60M rows) generated
by DuckDB's `tpch` extension and written twice: once with DuckDB's default row group size, once with
128 MB row groups. Every query runs on a fresh connection with `enable_external_file_cache = false`.

## What I found

| Check | Result | File |
|---|---|---|
| Q6 at 1,769 MB, default row groups | 1.5.6: 29.3 s, 2.0.0: 6.7 s | `results/03_summary.txt` |
| Q6 at 3,538 MB and 10,240 MB | 1.5.6: 19.3 s and 10.2 s, 2.0.0: 6.6 s and 6.8 s | `results/03_summary.txt` |
| Memory times Q6 time | 2.0.0 at 1,769 MB: 11.6 GB-s, 1.5.6 at 10,240 MB: 102 GB-s | `results/bench/` |
| Plain boto3 download of the file from each function size | about 75 MB/s at every size | `results/throughput/` |
| Bytes Q6 has to fetch | 480 MB in 1,952 column chunks (default row groups), 476 MB in 364 chunks (128 MB row groups) | `results/02_q6_bytes.txt` |
| Q6 on 1.5.6 at 1,769 MB with 128 MB row groups | 7.5 s | `results/03_summary.txt` |
| Q6 on 2.0.0 at 1,769 MB with `read_ahead_depth = 0` | 8.9 s | `results/03_summary.txt` |

480 MB at 75 MB/s is 6.3 s, so 2.0.0 reaches the download speed of the function at the smallest size.
1.5.6 time multiplied by its thread count stays near 59 s (2, 3 and 6 threads), which fits one blocking
request per column chunk at about 30 ms each. That last part is my reading of the numbers, not something
I traced.

Medians of 3 runs, one region, one table, warm functions. Treat the numbers as relative.

## Running it

You need the AWS CLI with permissions for S3, IAM and Lambda, plus `pip`, `zip`, `curl` and `jq`.

```bash
./build_layers.sh      # one Lambda layer per DuckDB version, with httpfs and tpch bundled
./setup.sh             # bucket, role, layers, 6 functions, writes lab.env
./invoke.sh 2-0-0-10240 '{"action":"gen","sf":10,"prefix":"s3://@BUCKET@/sf10","files":{"lineitem_default.parquet":"","lineitem_rg128mb.parquet":", ROW_GROUP_SIZE 1000000000, ROW_GROUP_SIZE_BYTES '"'"'128MB'"'"'"}}'
./bench_all.sh         # Q6 and Q1, every function, both files, 3 runs each
python3 summarize.py   # one line per result file
./teardown.sh          # deletes everything setup.sh created
```

By my estimate the whole run is about 0.3 USD at us-east-1 list prices, mostly Lambda compute and S3 GET requests.

## Layout

```
build_layers.sh           DuckDB wheel and extensions packed as a Lambda layer
setup.sh, teardown.sh     create and delete the AWS resources
lambda/bench.py           the handler: gen, meta, bench and throughput actions
invoke.sh, bench_all.sh   call one function, or run the whole matrix
summarize.py              turn results into one line per run
results/                  output of my run
```

The GB-s numbers come from the result files with the DuckDB CLI:

```sql
SELECT duckdb, lambda_mb, round(median(s), 1) AS q6_s,
       round(median(s) * any_value(lambda_mb) / 1024, 1) AS gb_s
FROM (SELECT duckdb, lambda_mb::INT AS lambda_mb, unnest(seconds) AS s
      FROM read_json('results/bench/*.lineitem_default.q6.default.json'))
GROUP BY ALL ORDER BY gb_s;
```

They count query time only, not billed duration, request fees or cold starts.
