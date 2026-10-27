#!/usr/bin/env bash
# Builds one Lambda layer zip per DuckDB version: the arm64 wheel for Python 3.13
# plus the httpfs and tpch extensions, so the function never downloads anything at runtime.
set -euo pipefail
cd "$(dirname "$0")"
VERSIONS=${VERSIONS:-"1.5.6 2.0.0"}
mkdir -p build
for v in $VERSIONS; do
  d=build/layer-$v
  rm -rf "$d" && mkdir -p "$d/python" "$d/duckdb_ext/v$v/linux_arm64"
  pip download -q "duckdb==$v" --no-deps --only-binary=:all: --implementation cp --python-version 3.13 \
    --platform manylinux_2_28_aarch64 -d build/whl-$v
  unzip -q -o build/whl-$v/duckdb-$v-*.whl -d "$d/python"
  for e in httpfs tpch; do
    curl -sfL "http://extensions.duckdb.org/v$v/linux_arm64/$e.duckdb_extension.gz" \
      | gunzip > "$d/duckdb_ext/v$v/linux_arm64/$e.duckdb_extension"
  done
  (cd "$d" && rm -f ../layer-$v.zip && zip -qr ../layer-$v.zip python duckdb_ext)
  ls -l build/layer-$v.zip
done
