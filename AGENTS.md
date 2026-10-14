# market-replay: agent guide

## Purpose

A tardis-machine style replay server for the raw minute files `market-recorder` writes. Recorded
frames come back over HTTP as raw lines, or over websockets that speak each venue's own subscribe
protocol, so the venue clients and everything built on them run against history unchanged.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `market-replay` (module `Market_replay`): raw line format, sources, request parsing, venue protocols, the websocket session, metrics, the server |
| `bin/` | The `market-replay` binary: `-data-dir`, `-port` (8800), `-from`, `-to`, `-speed` |
| `test/` | Pacing and mid-replay subscription tests, client tests against recorded fixtures |
| `scripts/` | `e2e-replay.sh`, the record-then-replay check |
| `.github/` | CI workflow |

## Build, test, docs

Run from this repository, inside the workspace:

    opam exec --switch 5.2.0+ox -- dune build --root .. @market-replay/all
    opam exec --switch 5.2.0+ox -- dune build --root .. @market-replay/runtest

Several agents building at once need `DUNE_BUILD_DIR=_build-market-replay`.

Standalone, outside the workspace: add the organization's opam repository
(`opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git`), install
the published dependencies, then run `dune build` here.

## Conventions

- Format this repository only: `dune build --root .. @market-replay/fmt --auto-promote`. Never
  `dune fmt` at the workspace root.
- Every module has an `.mli`; every public value has an odoc comment.
- Replayed frames are sent as recorded. Do not rewrite a frame to satisfy a client; a mismatch is a
  finding to report, not a fix to hide.
- The venue protocol codecs come from the protocol libraries (`binance-protocol`, `bybit-protocol`,
  `hl-protocol`) where they exist; do not re-implement a codec here.

## Routes

| Route | Behaviour |
| --- | --- |
| `GET /replay?venue=&symbol=&streams=&from=&to=` | Recorded `<recv_ts> <frame>` lines, merged by `recv_ts`, chunked NDJSON, as fast as the client reads |
| `GET /ws/<venue>[/...]` | Websocket for the eight crypto venues; subscribe messages are acknowledged like the venue does |
| `GET /fapi/v1/depth?symbol=` | The last recorded Binance depth snapshot, for book sync (503 before one is passed) |
| `GET /healthz`, `GET /metrics` | `ok`, and Prometheus counters |

## Dependencies

- Depends on sibling repositories `market-data`, `hl-protocol`, `binance-protocol`, `bybit-protocol`,
  and cohttp-async and async_websocket. Tests use the clients and the five feed libraries.
- Used by nothing in the organization yet.
- CI pin order is the `pins:` list in `.github/workflows/ci.yml`, in dependency order.

## CI

`.github/workflows/ci.yml` runs the ox-setup action with the pins, then `dune build` and `dune test`.
Its tests use fixtures copied under `test/fixtures/raw`. To check a run, use `gh run list --limit 1`
and at most one `gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- Pacing uses `Time_source`; tests use a synthetic clock at speeds 1, 2 and 0. Do not add sleeps.
- At speed 0 the Binance replay stops at the diff that a depth snapshot joins at, until the snapshot is
  served; the stop is documented in the README.
- A late subscription joins the replay at the current position, not from the start.
- A subscription to a different variant of a stream receives the recorded variant (Bybit `orderbook.200`
  against a recorded `orderbook.50`). Say so when a test depends on it.
- Recorded disconnects are skipped on websockets, not replayed as dropped connections.

## Where to read more

- `README.md` (HTTP and websocket replay, monitoring, end-to-end check, limits)
- `../specs/repos/market-replay.md` (design and known gaps)
- `../specs/design/data-platform.md` and `../specs/adr/0004-tardis-compatible-raw-format.md`
- `../oxcaml-claude-skills/AGENTS.md`, `../oxcaml-claude-skills/GOTCHAS.md`
- Skill `async-http-websocket` in `../oxcaml-claude-skills/skills/`

## Never do

- Serve or commit recorded data outside the workspace.
- Run `opam install`, `upgrade` or `pin` that would change `ocaml-variants`, `core`, `base`, `async` or
  `ppx_jane` on the shared `5.2.0+ox` switch.
- Publish, tag or release.
- Poll CI in a loop.
