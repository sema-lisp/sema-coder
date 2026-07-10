#!/bin/sh
# Run every tests/*_test.sema; fail on the first non-zero exit.
set -e
dir=$(cd "$(dirname "$0")/.." && pwd)
for f in "$dir"/tests/*_test.sema; do
  echo "── $f"
  sema "$f"
done
echo "all tests passed"
