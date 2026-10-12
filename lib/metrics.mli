(** Counters for [/metrics], in the Prometheus text format:

    - [market_replay_http_requests_total]: [GET /replay] requests accepted;
    - [market_replay_http_lines_total]: raw lines served over HTTP (disconnect lines
      included);
    - [market_replay_ws_connections_total{venue}]: websocket sessions opened;
    - [market_replay_ws_clients{venue}]: websocket sessions open now;
    - [market_replay_ws_frames_total{venue}]: recorded frames sent over websockets;
    - [market_replay_ws_replies_total{venue}]: acknowledgements and pongs sent;
    - [market_replay_ws_gaps_skipped_total{venue}]: recorded disconnects skipped. *)

open! Core

type t

val create : unit -> t
val http_request : t -> unit
val http_lines : t -> int -> unit
val ws_connected : t -> Market_data.Venue.t -> unit
val ws_disconnected : t -> Market_data.Venue.t -> unit
val ws_frame : t -> Market_data.Venue.t -> unit
val ws_reply : t -> Market_data.Venue.t -> unit
val ws_gap : t -> Market_data.Venue.t -> unit

(** Open websocket sessions over all venues. *)
val ws_clients : t -> int

val render : t -> string
