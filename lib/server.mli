(** The replay server: one port for HTTP and websockets.

    - [GET /replay?...] ({!Replay_request}): the recorded lines in [recv_ts] order, in the
      recorder's raw format ({!Raw_line}), as a chunked [application/x-ndjson] body, as
      fast as the client reads. A disconnect is an empty line.

    Anything else is [404]. *)

open! Core
open! Async

type t

val create : Source.t -> t

(** Listens on [port] (0 picks a free one). *)
val start : t -> port:int -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t
