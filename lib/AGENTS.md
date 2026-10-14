# lib: market-replay library

Library `market-replay` (module `Market_replay`):

- `Raw_line`: the recorder's line format; `format_ts` round-trips through `Market_data.Raw_minute.Line.parse`.
- `Source`: recorded items for a venue, symbols, streams and range, merged by `recv_ts`. `of_data_dir`
  reads through `Market_data.Raw_reader`; `of_items` is for tests.
- `Replay_request`: the `/replay` query.
- `Venue_protocol`: parses each venue's subscribe and ping messages with the protocol libraries' codecs.
- `Ws_replay`: one websocket session. A k-way merge accepts series added mid-replay, paces on a
  `Time_source`, waits 200 ms after the first subscribe, and has an optional hold after each item.
- `Metrics`, `Server`: Prometheus text, and all routes on one port (same-port websocket upgrade).

Rules:

- Do not add a route that changes what a client receives from the recording.
- Keep pacing on `Time_source`; a real clock in this path breaks the synthetic-clock tests.
