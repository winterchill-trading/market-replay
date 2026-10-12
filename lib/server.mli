(** The replay server: one port for HTTP and websockets.

    - [GET /replay?...] ({!Replay_request}): the recorded lines in [recv_ts] order, in the
      recorder's raw format ({!Raw_line}), as a chunked [application/x-ndjson] body, as
      fast as the client reads. A disconnect is an empty line.

    - [GET /ws/<venue>] (and any path below it, so a client's own suffix such as Binance's
      [/stream] works): a websocket speaking the venue's subscribe protocol
      ({!Venue_protocol}) and replaying the subscribed series ({!Ws_replay}) from the
      server's [ws] config. The query parameters [from], [to] and [speed] override it per
      connection; without a server [ws] config, [from] is required.

    - [GET /fapi/v1/depth?symbol=S]: Binance's REST depth snapshot, which binance-client
      fetches to sync its book: the last recorded snapshot body of [S] that a websocket
      replay has passed, or [503] until one has. The recorder stores these bodies in the
      [l2] files; they are not sent over the websocket. At speed 0 a Binance replay stops
      at the diff that a recorded snapshot joins at until the snapshot has been served and
      not asked for again for 300 ms (at most 3 s), so the diffs after it reach the client
      once its book has synced.

    - [GET /healthz]: [200 ok] while the server runs.
    - [GET /metrics]: {!Metrics.render}.

    Anything else is [404]. *)

open! Core
open! Async

type t

(** [time_source] (default the wall clock) paces websocket replays. *)
val create : ?ws:Ws_replay.Config.t -> ?time_source:Time_source.t -> Source.t -> t

val metrics : t -> Metrics.t

(** Listens on [port] (0 picks a free one). *)
val start : t -> port:int -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t
