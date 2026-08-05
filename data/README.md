# data/

This directory holds real ITCH capture data used for golden-trace generation
and RTL replay testing. It is gitignored — nothing here is committed.

## Sample capture provenance

Source: free public Nasdaq TotalView-ITCH 5.0 sample data, listed at
https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/

Directory listing checked on 2026-08-05. Files matching `*.NASDAQ_ITCH50.gz`
present at that time (name, date, size):

| File | Date | Size |
|---|---|---|
| 12302019.NASDAQ_ITCH50.gz | 2019-12-31 | 3,524,013,057 bytes (smallest) |
| 07302019.NASDAQ_ITCH50.gz | 2019-07-31 | 3,662,140,094 bytes |
| 10302019.NASDAQ_ITCH50.gz | 2019-10-31 | 3,872,931,242 bytes |
| 08302019.NASDAQ_ITCH50.gz | 2019-08-31 | 4,075,649,457 bytes |
| 01302019.NASDAQ_ITCH50.gz | 2019-01-31 | 4,764,426,091 bytes |
| 03272019.NASDAQ_ITCH50.gz | 2019-03-28 | 5,510,131,732 bytes |
| 01302020.NASDAQ_ITCH50.gz | 2020-01-31 | 5,597,158,940 bytes |

The listing also contains other, non-`*.NASDAQ_ITCH50.gz`-named full ITCH50
captures (e.g. `itch50_05_15.gz`, `S071321-v50.txt.gz`) and an `NOII/`
subdirectory (net-order-imbalance-indicator captures only, not general order
flow) — these were not chosen because the task calls for the smallest file
matching the `*.NASDAQ_ITCH50.gz` naming.

Chosen: **12302019.NASDAQ_ITCH50.gz** (smallest matching file, ~3.5 GB
compressed), fetched by `scripts/download_data.sh` into
`data/sample.NASDAQ_ITCH50.gz`.

This is Nasdaq's own free, publicly downloadable historical sample data,
provided for testing/development purposes — no license key or account
required.
