(* A replay server over the fixtures, and helpers to read a client's feed from it. *)

open! Core
open! Async
open Market_replay

let start () =
  Log.Global.set_output [];
  let ws =
    Ws_replay.Config.create
      ~speed:0.
      ~settle:(Time_ns.Span.of_int_ms 50)
      ~start:(Raw_line.parse_time "2026-10-12T13:35:00Z" |> ok_exn)
      ()
  in
  let replay = Server.create ~ws (Source.of_data_dir "fixtures") in
  let%map server = Server.start replay ~port:0 in
  replay, server
;;

let print_ws_metrics replay =
  String.split_lines (Metrics.render (Server.metrics replay))
  |> List.filter ~f:(String.is_prefix ~prefix:"market_replay_ws_")
  |> List.iter ~f:print_endline
;;

let url server path =
  Uri.of_string
    (sprintf "ws://localhost:%d%s" (Cohttp_async.Server.listening_on server) path)
;;

(* Reads up to [n] values, giving up after 3s without one (binance-client retries a failed
   depth snapshot after 1s). *)
let take pipe n =
  let rec go acc n =
    if n = 0
    then return (List.rev acc)
    else (
      match%bind
        Clock_ns.with_timeout (Time_ns.Span.of_sec 3.) (Pipe.values_available pipe)
      with
      | `Timeout | `Result `Eof -> return (List.rev acc)
      | `Result `Ok ->
        (match Pipe.read_now pipe with
         | `Ok x -> go (x :: acc) (n - 1)
         | `Nothing_available | `Eof -> go acc n))
  in
  go [] n
;;

let summarize (feed : Market_data.Feed.t) =
  let module F = (val feed) in
  let%bind trades = take F.trades 3 in
  let%bind bbo = take F.bbo 3 in
  let%bind l2 = take F.l2 3 in
  let%bind funding = take F.funding 3 in
  List.iter trades ~f:(fun (x : Market_data.Trade.t) ->
    print_s
      [%message
        "trade"
          ~_:(x.instrument : Market_data.Instrument.t)
          ~_:(x.side : Market_data.Side.t)
          ~_:(x.price : Market_data.Price.t)
          ~_:(x.size : Market_data.Size.t)]);
  List.iter bbo ~f:(fun (x : Market_data.Bbo.t) ->
    print_s
      [%message
        "bbo"
          ~_:(x.bid_price : Market_data.Price.t)
          ~_:(x.ask_price : Market_data.Price.t)]);
  List.iter l2 ~f:(fun (x : Market_data.L2_update.t) ->
    print_s
      [%message
        "l2"
          ~_:(x.kind : Market_data.L2_update.Kind.t)
          ~bids:(List.length x.bids : int)
          ~asks:(List.length x.asks : int)]);
  List.iter funding ~f:(fun (x : Market_data.Funding.t) ->
    print_s
      [%message "funding" ~_:(x.rate : float) ~mark:(x.mark_price : Market_data.Price.t)]);
  F.close ()
;;
