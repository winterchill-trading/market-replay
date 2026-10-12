open! Core
open Market_replay

let show query =
  match Replay_request.of_uri (Uri.of_string ("/replay?" ^ query)) with
  | Ok t -> print_s [%sexp (t : Replay_request.t)]
  | Error e -> print_s [%sexp (e : Error.t)]
;;

let%expect_test "full query" =
  show
    "venue=Binance&symbol=BTCUSDT,ETHUSDT&streams=trade,l2,trades&from=2026-10-12T09:00:00Z&to=2026-10-12T09:05:00.5Z";
  [%expect
    {|
    ((venue Binance) (symbols (BTCUSDT ETHUSDT)) (streams (Trades L2))
     (start "2026-10-12 09:00:00Z") (stop "2026-10-12 09:05:00.5Z"))
    |}];
  show "venue=bybit&symbol=BTCUSDT&symbol=ETHUSDT&from=2026-10-12&to=2026-10-13";
  [%expect
    {|
    ((venue Bybit) (symbols (BTCUSDT ETHUSDT)) (streams (Trades Bbo L2 Funding))
     (start "2026-10-12 00:00:00Z") (stop "2026-10-13 00:00:00Z"))
    |}]
;;

let%expect_test "errors" =
  show "symbol=BTCUSDT&from=2026-10-12&to=2026-10-13";
  show "venue=ftx&symbol=BTCUSDT&from=2026-10-12&to=2026-10-13";
  show "venue=okx&from=2026-10-12&to=2026-10-13";
  show "venue=okx&symbol=X&streams=trades,private&from=2026-10-12&to=2026-10-13";
  show "venue=okx&symbol=X&from=2026-10-13&to=2026-10-12";
  show "venue=okx&symbol=X&from=noon&to=2026-10-12";
  [%expect
    {|
    ("missing query parameter" venue)
    ("unknown venue" ftx)
    ("missing query parameter" symbol)
    ("unknown stream" private)
    "from must be before to"
    ("not an ISO 8601 UTC time" noon)
    |}]
;;
