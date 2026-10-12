(** A replay server over the fixtures, and helpers to read a client's feed from it. *)

open! Core
open! Async
open Market_replay

(** A replay server on an ephemeral port over [fixtures/], replaying at speed 0 from
    2026-10-12T13:35:00Z with a 50 ms settle. *)
val start
  :  unit
  -> (Server.t * (Socket.Address.Inet.t, int) Cohttp_async.Server.t) Deferred.t

(** The server's [/ws/...] metrics lines. *)
val print_ws_metrics : Server.t -> unit

(** [ws://localhost:<port><path>]. *)
val url : (Socket.Address.Inet.t, int) Cohttp_async.Server.t -> string -> Uri.t

(** Prints up to three trades, BBOs, L2 updates and funding updates of the feed, then
    closes it. *)
val summarize : Market_data.Feed.t -> unit Deferred.t
