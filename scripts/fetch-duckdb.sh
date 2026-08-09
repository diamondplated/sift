#!/usr/bin/env bash
# Fetches the prebuilt DuckDB library. Nothing is compiled from source: the C++
# amalgamation is 400 files and this keeps the exact version pin the engine's
# measured behaviors depend on.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.5.5"
SHA256="7b5b8915cc382d0708636fe6385c0cdad5a61c9ff8ba2638b3e2141640783155"
URL="https://github.com/duckdb/duckdb/releases/download/v${VERSION}/libduckdb-osx-universal.zip"

if [ -f Vendor/duckdb/libduckdb.dylib ] && [ -f Sources/CDuckDB/duckdb.h ]; then
  echo "libduckdb ${VERSION} already present; delete Vendor/ to refetch."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading libduckdb ${VERSION}…"
curl -fsSL -o "$tmp/libduckdb.zip" "$URL"

echo "Verifying checksum…"
actual="$(shasum -a 256 "$tmp/libduckdb.zip" | cut -d' ' -f1)"
if [ "$actual" != "$SHA256" ]; then
  echo "CHECKSUM MISMATCH" >&2
  echo "  expected: $SHA256" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi

unzip -oq "$tmp/libduckdb.zip" -d "$tmp/out"
mkdir -p Vendor/duckdb Sources/CDuckDB
cp "$tmp/out/libduckdb.dylib" Vendor/duckdb/
# The header lives beside the module map so the module map needs no -I flag.
cp "$tmp/out/duckdb.h" Sources/CDuckDB/

echo "libduckdb ${VERSION} ready."
