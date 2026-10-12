# market-replay

A replay server for the raw minute files written by `market-recorder`, in the style of
`tardis-machine`. Recorded venue frames come back two ways:

- over HTTP as raw lines, exactly as the recorder stored them;
- over a websocket that speaks each venue's own subscribe protocol, so the venue clients
  (`hl-client`, `binance-client`, `bybit-client`) and anything built on them, such as the
  market maker or the recorder itself, can run against history unchanged.

## Running

```sh
dune exec market-replay -- -data-dir /var/lib/market-recorder \
  -from 2026-10-12T09:00:00Z -speed 1 -port 8800
```

| Flag | Meaning |
|------|---------|
| `-data-dir DIR` | the recorder's data directory (reads `DIR/raw/...`) |
| `-port PORT` | HTTP and websocket port (default 8800) |
| `-from TIME` | where websocket replays start (ISO 8601 UTC or a date) |
| `-to TIME` | where websocket replays stop (default a day after `-from`) |
| `-speed X` | websocket pacing: 1 real time, 2 twice as fast, 0 as fast as the client reads |

## HTTP replay

```sh
curl 'localhost:8800/replay?venue=binance&symbol=BTCUSDT&streams=trades,l2&from=2026-10-12T09:00:00Z&to=2026-10-12T09:05:00Z'
```

```text
2026-10-12T09:00:00.012345Z {"stream":"btcusdt@aggTrade","data":{...}}
2026-10-12T09:00:00.020001Z {"stream":"btcusdt@depth@100ms","data":{...}}
```

- `venue`: `hyperliquid`, `binance`, `bybit`, `okx`, `coinbase`, `kraken`, `deribit`,
  `bitget`, ...; case-insensitive.
- `symbol`: one or more symbols as the recorder spells them, comma separated or repeated.
- `streams`: comma separated `trades` (or `trade`), `bbo`, `l2`, `funding`; default all
  four.
- `from` (inclusive) and `to` (exclusive): ISO 8601 UTC times or dates.

The body is chunked `application/x-ndjson`: one `<recv_ts> <frame>` line per recorded
frame, the series merged by `recv_ts`, an empty line where the recorder's connection
dropped. It is sent as fast as the client reads. Lines come straight from the files, so
acknowledgements and REST bodies the recorder kept are included.

## Websocket replay

Connect to `/ws/<venue>` (any path below it works, so Binance's `/ws/binance/stream`
does) and send the venue's own subscribe messages:

| Venue | Subscribe | Streams |
|-------|-----------|---------|
| `hyperliquid` | `{"method":"subscribe","subscription":{"type":"trades","coin":"BTC"}}` | `trades`, `l2Book` (l2 or bbo files), `activeAssetCtx` |
| `binance` | `{"method":"SUBSCRIBE","params":["btcusdt@aggTrade"],"id":1}` | `@aggTrade`, `@bookTicker`, `@depth...`, `@markPrice...` |
| `bybit` | `{"op":"subscribe","args":["publicTrade.BTCUSDT"]}` | `publicTrade`, `orderbook.1` (bbo), `orderbook.N` (l2), `tickers` |

The server answers like the venue (subscription acks, Hyperliquid and Bybit pongs) and
then sends the recorded data frames of the subscribed series, merged by `recv_ts`, from
`-from` on. Pacing keeps the recorded gaps between frames, divided by `-speed`. The replay
starts 200ms after the first subscribe so that a client's burst of subscriptions all start
at `-from`; a later subscription joins at the current replay position. Recorded
acknowledgements, pongs and REST bodies are not sent; recorded disconnects are skipped
and counted. `from`, `to` and `speed` query parameters on the websocket URL override the
flags for that connection (`ws://localhost:8800/ws/bybit?from=2026-10-12T09:30:00Z`).

Binance clients sync their order book from `GET /fapi/v1/depth`. The recorder stores
those bodies in the `l2` files, and the server answers `GET /fapi/v1/depth?symbol=S` with
the last one a websocket replay has passed (`503` until then; binance-client retries).
With `-speed 0` the whole recording is replayed before the book syncs, so the client
reports a single snapshot; at real time it reports the deltas too.

Pointing the clients at the server:

```ocaml
Hl_client.Config.create ~ws_url:(Uri.of_string "ws://localhost:8800/ws/hyperliquid")
  ~base_url:(Uri.of_string "http://localhost:8800") ()
Bybit_client.Config.Read_only.create ~ws_public_url:(Uri.of_string "ws://localhost:8800/ws/bybit")
  ~base_url:(Uri.of_string "http://localhost:8800") ()
Binance_client.Config.Read_only.create ~ws_url:(Uri.of_string "ws://localhost:8800/ws/binance")
  ~base_url:(Uri.of_string "http://localhost:8800") ()
```

or, in a `market-recorder` config,
`(config (Custom (base_url http://localhost:8800) (ws_url ws://localhost:8800/ws/bybit)))`.

## Monitoring

- `GET /healthz`: `200 ok`.
- `GET /metrics`: Prometheus text: `market_replay_http_requests_total`,
  `market_replay_http_lines_total`, and per venue `market_replay_ws_connections_total`,
  `market_replay_ws_clients`, `market_replay_ws_frames_total`,
  `market_replay_ws_replies_total`, `market_replay_ws_gaps_skipped_total`.

## End-to-end check

`scripts/e2e-replay.sh [RECORD_SECONDS] [REPLAY_SECONDS]` (defaults 60 and 15) records
the three simulators with `market-recorder`, then checks that `GET /replay` serves every
recorded line of each series and that a second recorder, pointed at the replay server
through `Custom` endpoints, receives every recorded data frame and normalizes them into
events with no parse errors.

## Library

| Module | Purpose |
|--------|---------|
| `Raw_line` | the recorder's `<recv_ts> <frame>` line format and time parsing |
| `Source` | recorded items for a venue, symbols, streams and time range; `of_data_dir` reads with `Market_data.Raw_reader` |
| `Replay_request` | the `/replay` query |
| `Venue_protocol` | per-venue subscribe parsing, venue-shaped replies, which recorded frames are data |
| `Ws_replay` | one websocket session: subscriptions, merge, pacing |
| `Metrics` | counters for `/metrics` |
| `Server` | routes on one port |

## Limits

- Websocket replay covers Hyperliquid, Binance USD-M and Bybit linear; the read-only feed
  venues are served over HTTP only.
- Frames are sent as recorded. A client subscribing to a different variant of a stream
  than was recorded (Bybit `orderbook.200` against a recorded `orderbook.50`, Binance
  `@depth@250ms` against `@depth@100ms`) gets the recorded one.
- Hyperliquid recordings made before the recorder stopped writing `l2Book` frames under
  both `l2` and `bbo` replay those frames twice to an `l2Book` subscriber.
