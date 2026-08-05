.PHONY: test-model replay replay-headline

test-model:
	python3 -m pytest -q

# End-to-end golden-model vs RTL replay (dump golden trace + wrapped byte
# stream, build and run the Verilator harness, compare). LIMIT is the message
# count; scripts/run_replay.sh defaults to 1,000,000.
#   make replay LIMIT=300000
replay:
	scripts/run_replay.sh $(if $(LIMIT),--limit $(LIMIT),)

# The headline verification run: 10M real Nasdaq messages, zero mismatches.
replay-headline:
	scripts/run_replay.sh --limit 10000000
