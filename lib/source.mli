(** Where recorded frames come from: the recorder's raw minute files, or a list of items
    in tests. *)

open! Core
module Md_stream := Market_data.Stream
open! Async

module Item : sig
  type t =
    | Frame of
        { recv_ts : Time_ns.t
        ; stream : Md_stream.t
        ; symbol : string
        ; frame : string
        }
    | Gap of
        { recv_ts : Time_ns.t
        ; stream : Md_stream.t
        ; symbol : string
        } (** the recorder's connection dropped (an empty raw line) *)
  [@@deriving sexp_of, compare, equal]

  val recv_ts : t -> Time_ns.t
  val stream : t -> Md_stream.t
  val symbol : t -> string
end

type t

(** The items of [venue] for [symbols] and [streams] with [recv_ts] in [[start, stop)], in
    [recv_ts] order; ties keep the order of [symbols]. Closing the reader stops reading. *)
val read
  :  t
  -> venue:Market_data.Venue.t
  -> symbols:string list
  -> streams:Md_stream.t list
  -> start:Time_ns.t
  -> stop:Time_ns.t
  -> Item.t Pipe.Reader.t

(** An in-memory source; items of one venue must be in [recv_ts] order per symbol. *)
val of_items : (Market_data.Venue.t * Item.t) list -> t

(** The recorder's raw minute files under [<data_dir>/raw], read with
    {!Market_data.Raw_reader}. [on_error] (default: logged) gets unreadable files and
    lines. *)
val of_data_dir : ?on_error:(Error.t -> unit) -> string -> t
