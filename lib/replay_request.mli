(** The query of [GET /replay]:

    {v
/replay?venue=binance&symbol=BTCUSDT&streams=trades,l2&from=2026-10-12T09:00:00Z&to=2026-10-12T09:05:00Z
    v}

    - [venue]: a {!Market_data.Venue} name, case-insensitive;
    - [symbol]: one or more venue symbols, comma separated or repeated, as the recorder
      spells them;
    - [streams] (optional, default [trades,bbo,l2,funding]): comma separated stream names;
      [trade] is accepted for [trades];
    - [from], [to]: ISO 8601 UTC times or dates ({!Raw_line.parse_time}); [from] is
      inclusive, [to] exclusive. *)

open! Core

type t =
  { venue : Market_data.Venue.t
  ; symbols : string list
  ; streams : Market_data.Stream.t list
  ; start : Time_ns.t
  ; stop : Time_ns.t
  }
[@@deriving sexp_of]

val of_uri : Uri.t -> t Or_error.t

(** The streams of a comma separated list, in order, without duplicates. *)
val parse_streams : string -> Market_data.Stream.t list Or_error.t
