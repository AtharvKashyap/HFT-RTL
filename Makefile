.PHONY: test-model replay replay-headline fuzz

test-model:
	python3 -m pytest -q

# End-to-end golden-model vs RTL replay (dump golden trace, order stream and
# wrapped byte stream, build and run the Verilator harness, compare BOTH the
# book updates and the OUCH order frames, and assert the DUT's strategy/risk
# counters against the golden model's). LIMIT is the message count;
# scripts/run_replay.sh defaults to 1,000,000.
#   make replay LIMIT=300000
replay:
	scripts/run_replay.sh $(if $(LIMIT),--limit $(LIMIT),)

# The headline verification run: 10M real Nasdaq messages, zero mismatches on
# both the book updates and the order stream.
replay-headline:
	scripts/run_replay.sh --limit 10000000

# Fuzz robustness: corrupted-stream + clean-tail run, 3 seeds. See
# docs/results.md ("Fuzz robustness") for what this checks.
fuzz:
	scripts/run_fuzz.sh
