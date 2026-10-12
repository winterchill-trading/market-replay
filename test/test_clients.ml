(* The venue clients' own Live_feeds, pointed at the replay server, receive the recorded
   frames as normalized events. *)

open! Core
open! Async
open Harness

let%expect_test "hl-client Live_feed over the replay" =
  let%bind replay, server = start () in
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
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
  print_ws_metrics replay;
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
    market_replay_ws_connections_total{venue="hyperliquid"} 1
    market_replay_ws_clients{venue="hyperliquid"} 0
    market_replay_ws_frames_total{venue="hyperliquid"} 43
    market_replay_ws_replies_total{venue="hyperliquid"} 3
    market_replay_ws_gaps_skipped_total{venue="hyperliquid"} 0
    |}];
  Cohttp_async.Server.close server
;;

let%expect_test "bybit-client Live_feed over the replay" =
  let%bind _replay, server = start () in
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
  let%bind _replay, server = start () in
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
