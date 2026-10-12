open! Core
module Md_stream = Market_data.Stream
open! Async

module Item = struct
  type t =
    | Frame of
        { recv_ts : Time_ns.Alternate_sexp.t
        ; stream : Md_stream.t
        ; symbol : string
        ; frame : string
        }
    | Gap of
        { recv_ts : Time_ns.Alternate_sexp.t
        ; stream : Md_stream.t
        ; symbol : string
        }
  [@@deriving sexp_of, compare, equal]

  let recv_ts = function
    | Frame { recv_ts; _ } | Gap { recv_ts; _ } -> recv_ts
  ;;

  let stream = function
    | Frame { stream; _ } | Gap { stream; _ } -> stream
  ;;

  let symbol = function
    | Frame { symbol; _ } | Gap { symbol; _ } -> symbol
  ;;
end

type t =
  { read_symbol :
      venue:Market_data.Venue.t
      -> symbol:string
      -> streams:Md_stream.t list
      -> start:Time_ns.t
      -> stop:Time_ns.t
      -> Item.t Pipe.Reader.t
  }

let read t ~venue ~symbols ~streams ~start ~stop =
  let seen = String.Hash_set.create () in
  let symbols =
    List.filter symbols ~f:(fun s ->
      (not (Hash_set.mem seen s))
      &&
      (Hash_set.add seen s;
       true))
  in
  match symbols with
  | [ symbol ] -> t.read_symbol ~venue ~symbol ~streams ~start ~stop
  | symbols ->
    Market_data.Merge.sorted
      (List.map symbols ~f:(fun symbol ->
         t.read_symbol ~venue ~symbol ~streams ~start ~stop))
      ~compare:(fun a b -> Time_ns.compare (Item.recv_ts a) (Item.recv_ts b))
;;

let of_items items =
  let read_symbol ~venue ~symbol ~streams ~start ~stop =
    List.filter_map items ~f:(fun (v, item) ->
      Option.some_if
        (Market_data.Venue.equal v venue
         && String.equal (Item.symbol item) symbol
         && List.mem streams (Item.stream item) ~equal:Md_stream.equal
         && Time_ns.(Item.recv_ts item >= start && Item.recv_ts item < stop))
        item)
    |> Pipe.of_list
  in
  { read_symbol }
;;

let of_data_dir ?on_error data_dir =
  let read_symbol ~venue ~symbol ~streams ~start ~stop =
    Market_data.Raw_reader.read
      ?on_error
      ~streams
      ~data_dir
      ~venue
      ~symbol
      ~start
      ~stop
      ()
    |> Pipe.map ~f:(function
      | Market_data.Raw_reader.Item.Frame { recv_ts; stream; frame } ->
        Item.Frame { recv_ts; stream; symbol; frame }
      | Gap { recv_ts; stream } -> Gap { recv_ts; stream; symbol })
  in
  { read_symbol }
;;
