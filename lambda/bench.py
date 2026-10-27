"""Lambda handler shared by both DuckDB versions.

event = {
  "action": "bench" | "gen" | "meta",
  "path": "s3://bucket/key.parquet",
  "query": "q6" | "q1",
  "runs": 5,
  "settings": {"read_ahead_depth": 0, ...}
}
"""
import os
import time

import duckdb

QUERIES = {
    "q6": """
        SELECT sum(l_extendedprice * l_discount) AS revenue
        FROM read_parquet('{path}')
        WHERE l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1995-01-01'
          AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24
    """,
    "q1": """
        SELECT l_returnflag, l_linestatus, sum(l_quantity), sum(l_extendedprice),
               sum(l_extendedprice * (1 - l_discount)),
               sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)),
               avg(l_quantity), avg(l_extendedprice), avg(l_discount), count(*)
        FROM read_parquet('{path}')
        WHERE l_shipdate <= DATE '1998-12-01' - INTERVAL 90 DAY
        GROUP BY ALL ORDER BY ALL
    """,
}


def connect(settings=None):
    con = duckdb.connect(config={"extension_directory": "/opt/duckdb_ext", "home_directory": "/tmp"})
    con.execute("LOAD httpfs")
    con.execute(
        "CREATE SECRET s3 (TYPE s3, KEY_ID ?, SECRET ?, SESSION_TOKEN ?, REGION ?)",
        [os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"],
         os.environ["AWS_SESSION_TOKEN"], os.environ["AWS_REGION"]],
    )
    # every run must go to S3, not to the in-process file cache
    con.execute("SET enable_external_file_cache = false")
    for k, v in (settings or {}).items():
        con.execute(f"SET {k} = {v!r}" if isinstance(v, str) else f"SET {k} = {v}")
    return con


def describe(con):
    names = ("threads", "memory_limit", "async_threads", "read_ahead_depth", "http_client_pool_capacity")
    rows = con.execute(
        "SELECT name, value FROM duckdb_settings() WHERE name IN ({})".format(",".join("?" * len(names))),
        list(names),
    ).fetchall()
    return {"duckdb": duckdb.__version__, "platform": con.execute("PRAGMA platform").fetchone()[0],
            "lambda_mb": os.environ.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE"), "cpus": os.cpu_count(),
            **dict(rows)}


def bench(event):
    sql = QUERIES[event["query"]].format(path=event["path"])
    out = []
    for _ in range(event.get("runs", 5)):
        con = connect(event.get("settings"))
        t = time.perf_counter()
        con.execute(sql).fetchall()
        out.append(round(time.perf_counter() - t, 3))
        info = describe(con)
        con.close()
    return {**info, "query": event["query"], "path": event["path"], "settings": event.get("settings"), "seconds": out}


def gen(event):
    # TPC-H lineitem, written twice: DuckDB's default row group size, and a few huge row groups
    con = connect({"memory_limit": "7GB", "temp_directory": "/tmp/spill", "preserve_insertion_order": False})
    con.execute("LOAD tpch")
    t = time.perf_counter()
    con.execute(f"CALL dbgen(sf = {event['sf']})")
    done = {"dbgen_s": round(time.perf_counter() - t, 1)}
    for name, opts in event["files"].items():
        t = time.perf_counter()
        con.execute(f"COPY lineitem TO '{event['prefix']}/{name}' (FORMAT parquet {opts})")
        done[name] = round(time.perf_counter() - t, 1)
    return done


def meta(event):
    con = connect()
    return con.execute(
        "SELECT file_name, count(DISTINCT row_group_id) AS row_groups, max(row_group_num_rows) AS max_rows, "
        "sum(total_compressed_size) AS bytes FROM parquet_metadata(?) GROUP BY ALL ORDER BY ALL",
        [event["path"]],
    ).fetchall()


def throughput(event):
    # raw S3 GET speed from this function with boto3, no DuckDB involved
    import boto3
    from boto3.s3.transfer import TransferConfig

    class Sink:
        n = 0

        def write(self, b):
            Sink.n += len(b)

    bucket, key = event["path"][5:].split("/", 1)
    cfg = TransferConfig(multipart_chunksize=8 * 2**20, max_concurrency=event.get("concurrency", 32))
    out = []
    for _ in range(event.get("runs", 3)):
        Sink.n = 0
        t = time.perf_counter()
        boto3.client("s3").download_fileobj(bucket, key, Sink(), Config=cfg)
        s = time.perf_counter() - t
        out.append({"seconds": round(s, 2), "MB_per_s": round(Sink.n / s / 1e6, 1), "Gbit_per_s": round(Sink.n * 8 / s / 1e9, 2)})
    return {"lambda_mb": os.environ.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE"), "bytes": Sink.n, "runs": out}


def handler(event, context):
    return {"bench": bench, "gen": gen, "meta": meta, "throughput": throughput}[event["action"]](event)
