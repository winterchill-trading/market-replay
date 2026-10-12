(** The recorder's raw line format, [<recv_ts> <frame>\n], as served by [/replay]. *)

open! Core

(** ISO 8601 UTC with microseconds, e.g. [2026-10-12T09:15:02.123456Z], exactly as
    market-recorder writes it. *)
val format_ts : Time_ns.t -> string

(** Parses a [from]/[to] value: an ISO 8601 time with a UTC offset or [Z]
    ([2026-10-12T09:15:00Z], fractional seconds allowed), or a bare date ([2026-10-12],
    midnight UTC). *)
val parse_time : string -> Time_ns.t Or_error.t

(** [<recv_ts> <frame>\n]. Newlines inside [frame] become spaces, as in the recorder. *)
val frame : recv_ts:Time_ns.t -> string -> string

(** The empty line the recorder writes for a disconnect. *)
val disconnect : string
