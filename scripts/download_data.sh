#!/usr/bin/env bash
# Downloads a real Nasdaq TotalView-ITCH 5.0 BinaryFILE sample capture into
# data/ (gitignored) for use with model/dump_trace.py.
#
# Free public Nasdaq sample data, listed at:
#   https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/
#
# The listing changes over time; this script targets the file recorded in
# data/README.md as of the time it was chosen (smallest current
# *.NASDAQ_ITCH50.gz file at execution time). Re-check the listing and update
# both this URL and data/README.md if that file is no longer available.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p data

curl -o data/sample.NASDAQ_ITCH50.gz \
  "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/12302019.NASDAQ_ITCH50.gz"

echo "Downloaded to data/sample.NASDAQ_ITCH50.gz"
