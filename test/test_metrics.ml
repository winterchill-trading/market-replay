open! Core
open Market_replay

let%expect_test "render" =
  let m = Metrics.create () in
  Metrics.http_request m;
  Metrics.http_lines m 42;
  Metrics.ws_connected m Bybit;
  Metrics.ws_connected m Binance;
  Metrics.ws_connected m Binance;
  Metrics.ws_disconnected m Binance;
  Metrics.ws_frame m Binance;
  Metrics.ws_reply m Bybit;
  Metrics.ws_gap m Bybit;
  print_string (Metrics.render m);
  printf "clients %d\n" (Metrics.ws_clients m);
  [%expect
    {|
    # HELP market_replay_http_requests_total GET /replay requests accepted
    # TYPE market_replay_http_requests_total counter
    market_replay_http_requests_total 1
    # HELP market_replay_http_lines_total raw lines served over HTTP
    # TYPE market_replay_http_lines_total counter
    market_replay_http_lines_total 42
    # HELP market_replay_ws_connections_total websocket sessions opened
    # TYPE market_replay_ws_connections_total counter
    market_replay_ws_connections_total{venue="binance"} 2
    market_replay_ws_connections_total{venue="bybit"} 1
    # HELP market_replay_ws_clients websocket sessions open
    # TYPE market_replay_ws_clients gauge
    market_replay_ws_clients{venue="binance"} 1
    market_replay_ws_clients{venue="bybit"} 1
    # HELP market_replay_ws_frames_total recorded frames sent over websockets
    # TYPE market_replay_ws_frames_total counter
    market_replay_ws_frames_total{venue="binance"} 1
    market_replay_ws_frames_total{venue="bybit"} 0
    # HELP market_replay_ws_replies_total acknowledgements and pongs sent
    # TYPE market_replay_ws_replies_total counter
    market_replay_ws_replies_total{venue="binance"} 0
    market_replay_ws_replies_total{venue="bybit"} 1
    # HELP market_replay_ws_gaps_skipped_total recorded disconnects skipped
    # TYPE market_replay_ws_gaps_skipped_total counter
    market_replay_ws_gaps_skipped_total{venue="binance"} 0
    market_replay_ws_gaps_skipped_total{venue="bybit"} 1
    clients 2
    |}]
;;
