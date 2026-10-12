(** One websocket replay session: the client's subscribe messages pick recorded series,
    which are replayed merged by [recv_ts] from [start], paced by [speed].

    The replay starts [settle] after the first subscription, so the burst of subscribe
    messages a client sends on connect all start at [start]. A later subscription joins at
    the current replay position. Pacing keeps the recorded gaps between frames: with
    [speed = 1.] a frame recorded [d] after [start] is sent [d] after the replay started,
    with [speed = 2.] after [d / 2]; [speed = 0.] sends as fast as the client reads.
    Recorded disconnects (gaps) are skipped and counted. *)

open! Core
open! Async

module Config : sig
  type t =
    { start : Time_ns.t
    ; stop : Time_ns.t
    ; speed : float
    ; settle : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  (** [stop] defaults to a day after [start], [speed] to [1.], [settle] to 200ms. Raises
      if [speed] is negative or not finite, or [stop <= start]. *)
  val create
    :  ?stop:Time_ns.t
    -> ?speed:float
    -> ?settle:Time_ns.Span.t
    -> start:Time_ns.t
    -> unit
    -> t
end

module Stats : sig
  type t =
    { frames_sent : int (** recorded frames passed to the client *)
    ; replies_sent : int (** acknowledgements and pongs *)
    ; gaps_skipped : int
    }
  [@@deriving sexp_of]
end

type t

(** [send] writes one text frame to the client; its deferred is the pushback. [metrics]
    counts frames, replies and skipped gaps under [venue]. [on_frame] sees every item
    replayed, sent or not; the replay then waits for [hold item] before the next one (the
    server holds a speed 0 Binance replay at a recorded depth snapshot until the client
    has fetched it). *)
val create
  :  ?metrics:Metrics.t
  -> ?time_source:Time_source.t
  -> ?on_frame:(Source.Item.t -> unit)
  -> ?hold:(Source.Item.t -> unit Deferred.t)
  -> Config.t
  -> Source.t
  -> venue:Market_data.Venue.t
  -> conn_id:string
  -> send:(string -> unit Deferred.t)
  -> t

(** Handles one message from the client. *)
val on_message : t -> string -> unit Deferred.t

(** Stops the replay and closes the readers. *)
val close : t -> unit

val stats : t -> Stats.t

(** Becomes determined when every subscribed series has been replayed up to [stop], or the
    session is closed. *)
val finished : t -> unit Deferred.t
