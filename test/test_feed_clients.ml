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
