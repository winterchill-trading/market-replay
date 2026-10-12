(** The replay server: one port for HTTP and websockets.

    - [GET /replay?...] ({!Replay_request}): the recorded lines in [recv_ts] order, in the
      recorder's raw format ({!Raw_line}), as a chunked [application/x-ndjson] body, as
      fast as the client reads. A disconnect is an empty line.

    - [GET /ws/<venue>] (and any path below it, so a client's own suffix such as Binance's
      [/stream] works): a websocket speaking the venue's subscribe protocol
      ({!Venue_protocol}) and replaying the subscribed series ({!Ws_replay}) from the
      server's [ws] config. The query parameters [from], [to] and [speed] override it per
      connection; without a server [ws] config, [from] is required.

    Anything else is [404]. *)

open! Core
open! Async

type t

(** [time_source] (default the wall clock) paces websocket replays. *)
val create : ?ws:Ws_replay.Config.t -> ?time_source:Time_source.t -> Source.t -> t

(** Listens on [port] (0 picks a free one). *)
val start : t -> port:int -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t
