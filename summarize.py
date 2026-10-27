"""Prints one row per benchmark result file: version, Lambda memory, file, query, setting, median seconds."""
import glob
import json
import statistics
import sys

rows = []
for p in sorted(glob.glob(sys.argv[1] if len(sys.argv) > 1 else "results/bench/*.json")):
    r = json.load(open(p))
    if "seconds" not in r:
        print("NO RESULT", p, r)
        continue
    tag = "readahead0" if r["settings"] and r["settings"].get("read_ahead_depth") == 0 else "default"
    rows.append((r["duckdb"], int(r["lambda_mb"]), r["path"].rsplit("/", 1)[1].replace(".parquet", ""), r["query"], tag,
                 statistics.median(r["seconds"]), r["seconds"], r["threads"], r.get("async_threads", "-"), r["memory_limit"]))
for row in sorted(rows, key=lambda x: (x[2], x[3], x[1], x[0], x[4])):
    print("{:6} {:>6} {:18} {:3} {:10} median={:7.2f}s runs={} threads={} async={} mem={}".format(*row))
