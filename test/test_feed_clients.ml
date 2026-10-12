(* The read-only feed clients' Live_feeds, pointed at the replay server, receive the
   recorded frames of their own fixture minutes as normalized events. How many frames
   arrive before the feed is closed depends on timing, so only the connection and reply
   counters are printed. *)

open! Core
open! Async
open Harness

let all_streams = Market_data.Stream.[ Trades; Bbo; L2; Funding ]

let print_counters replay ~parse_errors =
  String.split_lines (Market_replay.Metrics.render (Market_replay.Server.metrics replay))
  |> List.filter ~f:(fun line ->
    String.is_prefix line ~prefix:"market_replay_ws_connections_total"
    || String.is_prefix line ~prefix:"market_replay_ws_replies_total")
  |> List.iter ~f:print_endline;
  print_s [%message (parse_errors : int)]
;;

let%expect_test "okx-feed Live_feed over the replay" =
  let%bind replay, server = start () in
  let%bind live =
    Okx_feed.Live_feed.start
      (Okx_feed.Config.create ~url:(url server "/ws/okx?from=2026-10-12T16:53:00Z") ())
      ~symbols:[ "BTC-USDT-SWAP" ]
      ~streams:all_streams
  in
  let%bind () = summarize (Okx_feed.Live_feed.feed live) in
  print_counters replay ~parse_errors:(Okx_feed.Live_feed.stats live).parse_errors;
  [%expect
    {|
    (trade ((venue Okx) (symbol BTC-USDT-SWAP)) Sell 82580.9 0.06)
    (trade ((venue Okx) (symbol BTC-USDT-SWAP)) Buy 82581 10)
    (trade ((venue Okx) (symbol BTC-USDT-SWAP)) Sell 82580.9 5.29)
    (bbo 82576.8 82576.9)
    (bbo 82576.8 82576.9)
    (bbo 82576.8 82576.9)
    (l2 Snapshot (bids 400) (asks 400))
    (l2 Delta (bids 41) (asks 49))
    (l2 Delta (bids 30) (asks 21))
    (funding 2.80976802129E-05 (mark 82576.9))
    (funding 2.80976802129E-05 (mark 82576.8))
    (funding 2.80976802129E-05 (mark 82576.8))
    market_replay_ws_connections_total{venue="okx"} 4
    market_replay_ws_replies_total{venue="okx"} 6
    (parse_errors 0)
    |}];
  Cohttp_async.Server.close server
;;

let%expect_test "bitget-feed Live_feed over the replay" =
  let%bind replay, server = start () in
  let%bind feed, stats =
    Bitget_feed.Live_feed.create_with_stats
      (Bitget_feed.Config.create
         ~url:(url server "/ws/bitget?from=2026-10-12T16:54:00Z")
         ())
      ~symbols:[ "BTCUSDT" ]
      ~streams:all_streams
  in
  let%bind () = summarize feed in
  print_counters replay ~parse_errors:(stats ()).parse_errors;
  [%expect
    {|
    (trade ((venue Bitget) (symbol BTCUSDT)) Buy 82576 0.1161)
    (trade ((venue Bitget) (symbol BTCUSDT)) Buy 82576 0.058)
    (trade ((venue Bitget) (symbol BTCUSDT)) Buy 82576 0.1159)
    (bbo 82560 82560.1)
    (bbo 82560 82560.1)
    (bbo 82560 82560.1)
    (l2 Snapshot (bids 500) (asks 500))
    (l2 Delta (bids 5) (asks 12))
    (l2 Delta (bids 39) (asks 28))
    (funding 5.4E-05 (mark 82561.6))
    (funding 5.4E-05 (mark 82561.6))
    (funding 5.4E-05 (mark 82561.5))
    market_replay_ws_connections_total{venue="bitget"} 4
    market_replay_ws_replies_total{venue="bitget"} 4
    (parse_errors 0)
    |}];
  Cohttp_async.Server.close server
;;

let%expect_test "deribit-feed Live_feed over the replay" =
  let%bind replay, server = start () in
  let%bind live =
    Deribit_feed.Live_feed.start
      (Deribit_feed.Config.create
         ~url:(url server "/ws/deribit?from=2026-10-12T16:54:00Z")
         ())
      ~symbols:[ "BTC-PERPETUAL" ]
      ~streams:all_streams
  in
  let%bind () = summarize (Deribit_feed.Live_feed.feed live) in
  print_counters replay ~parse_errors:(Deribit_feed.Live_feed.stats live).parse_errors;
  [%expect
    {|
    (trade ((venue Deribit) (symbol BTC-PERPETUAL)) Sell 82542.5 20)
    (trade ((venue Deribit) (symbol BTC-PERPETUAL)) Sell 82542.5 20)
    (trade ((venue Deribit) (symbol BTC-PERPETUAL)) Sell 82542.5 20)
    (bbo 82542.5 82543)
    (bbo 82542.5 82543)
    (bbo 82542.5 82543)
    (l2 Snapshot (bids 1138) (asks 908))
    (l2 Delta (bids 48) (asks 72))
    (l2 Delta (bids 61) (asks 61))
    (funding 9.746E-05 (mark 82541.5))
    (funding 9.746E-05 (mark 82537.21))
    (funding 9.746E-05 (mark 82536.97))
    market_replay_ws_connections_total{venue="deribit"} 4
    market_replay_ws_replies_total{venue="deribit"} 8
    (parse_errors 0)
    |}];
  Cohttp_async.Server.close server
;;

let%expect_test "kraken-feed Live_feed over the replay, spot and futures" =
  let%bind replay, server = start () in
  let from = "?from=2026-10-12T13:34:00Z" in
  let%bind live =
    Kraken_feed.Live_feed.start
      (Kraken_feed.Config.create
         ~spot_url:(url server ("/ws/kraken" ^ from))
         ~futures_url:(url server ("/ws/kraken" ^ from))
         ())
      ~symbols:[ "BTC/USD" ]
      ~streams:all_streams
  in
  let%bind () = summarize (Kraken_feed.Live_feed.feed live) in
  print_counters replay ~parse_errors:(Kraken_feed.Live_feed.stats live).parse_errors;
  [%expect
    {|
    (trade ((venue Kraken) (symbol BTC/USD)) Sell 82471.1 0.00002396)
    (trade ((venue Kraken) (symbol BTC/USD)) Sell 82471.1 0.00001806)
    (trade ((venue Kraken) (symbol BTC/USD)) Buy 82471.2 0.00014134)
    (bbo 82471.1 82471.2)
    (bbo 82471.1 82471.2)
    (bbo 82471.1 82471.2)
    (l2 Snapshot (bids 10) (asks 10))
    (l2 Delta (bids 2) (asks 0))
    (l2 Delta (bids 2) (asks 0))
    (funding 2.49745833333E-07 (mark 82475.05034106))
    (funding 2.49745833333E-07 (mark 82473.26870615))
    (funding 2.49745833333E-07 (mark 82471.93556382))
    market_replay_ws_connections_total{venue="kraken"} 4
    market_replay_ws_replies_total{venue="kraken"} 4
    (parse_errors 0)
    |}];
  Cohttp_async.Server.close server
;;
