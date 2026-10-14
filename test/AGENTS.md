# test: market-replay tests

- `test_ws_replay.ml`: pacing on a synthetic clock at speeds 1, 2 and 0, a late subscription joining
  mid-replay, and gaps skipped.
- `test_clients.ml`: the hl, bybit and binance clients connect to the server and receive normalized
  events from recorded fixture minutes.
- `test_feed_clients.ml`: the okx, coinbase, kraken, deribit and bitget feeds do the same over their
  own fixture minutes, with no parse errors.

Rules:

- Copy new fixtures under `test/fixtures/raw`; do not edit an existing recording.
- Use the synthetic clock; the tests must not depend on wall time.
