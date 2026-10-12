(* The venue clients' own Live_feeds, pointed at the replay server, receive the recorded
   frames as normalized events. *)

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
  Server.start (Server.create ~ws (Source.of_data_dir "fixtures")) ~port:0
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

let%expect_test "hl-client Live_feed over the replay" =
  let%bind server = start () in
  let%bind feed =
    Hl_client.Live_feed.create
      (Hl_client.Config.create
         ~ws_url:(url server "/ws/hyperliquid")
         ~base_url:(Uri.of_string "http://localhost:1")
         ())
      ~symbols:[ "BTC" ]
      ~streams:[ Trades; Bbo; L2; Funding ]
  in
  let%bind () = summarize feed in
  [%expect
    {|
    (trade ((venue Hyperliquid) (symbol BTC)) Sell 82525 0.01671)
    (trade ((venue Hyperliquid) (symbol BTC)) Sell 82525 0.01669)
    (trade ((venue Hyperliquid) (symbol BTC)) Sell 82525 0.00075)
    (bbo 82514 82515)
    (bbo 82492 82493)
    (bbo 82478 82479)
    (l2 Snapshot (bids 20) (asks 20))
    (l2 Snapshot (bids 20) (asks 20))
    (l2 Snapshot (bids 20) (asks 20))
    (funding 8.8036E-06 (mark 82528))
    (funding 8.8233E-06 (mark 82521))
    (funding 8.8233E-06 (mark 82521))
    |}];
  Cohttp_async.Server.close server
;;

let%expect_test "bybit-client Live_feed over the replay" =
  let%bind server = start () in
  let%bind feed =
    Bybit_client.Live_feed.connect
      (Bybit_client.Config.Read_only.create
         ~ws_public_url:(url server "/ws/bybit")
         ~base_url:(Uri.of_string "http://localhost:1")
         ())
      ~symbols:[ "BTCUSDT" ]
      ~streams:[ Trades; Bbo; L2; Funding ]
  in
  let%bind () = summarize (Bybit_client.Live_feed.feed feed) in
  [%expect
    {|
    (trade ((venue Bybit) (symbol BTCUSDT)) Sell 82597.2 0.001)
    (trade ((venue Bybit) (symbol BTCUSDT)) Sell 82597.2 0.001)
    (trade ((venue Bybit) (symbol BTCUSDT)) Buy 82597.3 0.008)
    (bbo 82597.2 82597.3)
    (bbo 82597.2 82597.3)
    (bbo 82597.2 82597.3)
    (l2 Snapshot (bids 50) (asks 50))
    (l2 Delta (bids 3) (asks 2))
    (l2 Delta (bids 3) (asks 2))
    (funding 3.021E-05 (mark 82607.57))
    (funding 3.021E-05 (mark 82607.57))
    (funding 3.021E-05 (mark 82605.98))
    |}];
  Cohttp_async.Server.close server
;;

let%expect_test "binance-client Live_feed over the replay" =
  let%bind server = start () in
  let%bind feed =
    Binance_client.Live_feed.create
      (Binance_client.Config.Read_only.create
         ~ws_url:(url server "/ws/binance")
         ~base_url:(Uri.with_scheme (url server "") (Some "http"))
         ())
      ~symbols:[ "BTCUSDT" ]
      ~streams:[ Trades; Bbo; L2; Funding ]
  in
  let%bind () = summarize feed in
  [%expect
    {|
    (trade ((venue Binance) (symbol BTCUSDT)) Buy 82613.6 0.005)
    (trade ((venue Binance) (symbol BTCUSDT)) Sell 82613.5 0.001)
    (trade ((venue Binance) (symbol BTCUSDT)) Buy 82613.6 0.007)
    (bbo 82613.5 82613.6)
    (bbo 82613.5 82613.6)
    (bbo 82613.5 82613.6)
    (l2 Snapshot (bids 908) (asks 765))
    (funding 3.61E-05 (mark 82621.50711594))
    (funding 3.61E-05 (mark 82620.67168116))
    (funding 3.61E-05 (mark 82620.22276812))
    |}];
  Cohttp_async.Server.close server
;;
