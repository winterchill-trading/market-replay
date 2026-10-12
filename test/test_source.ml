open! Core
open! Async
open Market_replay

let ts s = Raw_line.parse_time s |> ok_exn

let frame ?(stream = Market_data.Stream.Trades) symbol at payload =
  Source.Item.Frame { recv_ts = ts at; stream; symbol; frame = payload }
;;

let source =
  Source.of_items
    [ Binance, frame "BTCUSDT" "2026-10-12T09:00:00.1Z" "b1"
    ; Binance, frame "BTCUSDT" "2026-10-12T09:00:00.3Z" "b3"
    ; Binance, frame ~stream:L2 "BTCUSDT" "2026-10-12T09:00:00.35Z" "bl2"
    ; Binance, frame "ETHUSDT" "2026-10-12T09:00:00.2Z" "e2"
    ; Binance, frame "ETHUSDT" "2026-10-12T09:00:00.3Z" "e3"
    ; Bybit, frame "BTCUSDT" "2026-10-12T09:00:00.15Z" "other venue"
    ; Binance, frame "BTCUSDT" "2026-10-12T09:01:00Z" "after stop"
    ]
;;

let show ~symbols ~streams =
  let%map items =
    Source.read
      source
      ~venue:Binance
      ~symbols
      ~streams
      ~start:(ts "2026-10-12T09:00:00Z")
      ~stop:(ts "2026-10-12T09:01:00Z")
    |> Pipe.to_list
  in
  List.iter items ~f:(function
    | Frame { recv_ts; symbol; frame; _ } ->
      printf "%s %s %s\n" (Raw_line.format_ts recv_ts) symbol frame
    | Gap _ -> print_endline "gap")
;;

let%expect_test "symbols merge by recv_ts, ties in request order" =
  let%bind () = show ~symbols:[ "ETHUSDT"; "BTCUSDT"; "ETHUSDT" ] ~streams:[ Trades ] in
  [%expect
    {|
    2026-10-12T09:00:00.100000Z BTCUSDT b1
    2026-10-12T09:00:00.200000Z ETHUSDT e2
    2026-10-12T09:00:00.300000Z ETHUSDT e3
    2026-10-12T09:00:00.300000Z BTCUSDT b3
    |}];
  let%bind () = show ~symbols:[ "BTCUSDT" ] ~streams:[ Trades; L2 ] in
  [%expect
    {|
    2026-10-12T09:00:00.100000Z BTCUSDT b1
    2026-10-12T09:00:00.300000Z BTCUSDT b3
    2026-10-12T09:00:00.350000Z BTCUSDT bl2
    |}];
  return ()
;;

let write_file path contents =
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  Writer.save path ~contents
;;

let%expect_test "of_data_dir reads recorder minute files" =
  let dir = Filename_unix.temp_dir "market-replay" "" in
  let raw = dir ^/ "raw/binance" in
  let%bind () =
    write_file
      (raw ^/ "trades/BTCUSDT/2026/10/12/09-00.ndjson")
      "2026-10-12T09:00:01.000000Z t1\n\n2026-10-12T09:00:03.000000Z t3\n"
  in
  let%bind () =
    write_file
      (raw ^/ "l2/BTCUSDT/2026/10/12/09-00.ndjson")
      "2026-10-12T09:00:02.000000Z d2\n"
  in
  let%bind items =
    Source.read
      (Source.of_data_dir dir)
      ~venue:Binance
      ~symbols:[ "BTCUSDT" ]
      ~streams:[ Trades; L2 ]
      ~start:(ts "2026-10-12T09:00:00Z")
      ~stop:(ts "2026-10-12T09:01:00Z")
    |> Pipe.to_list
  in
  List.iter items ~f:(fun item -> print_s [%sexp (item : Source.Item.t)]);
  [%expect
    {|
    (Frame (recv_ts "2026-10-12 09:00:01Z") (stream Trades) (symbol BTCUSDT)
     (frame t1))
    (Gap (recv_ts "2026-10-12 09:00:01Z") (stream Trades) (symbol BTCUSDT))
    (Frame (recv_ts "2026-10-12 09:00:02Z") (stream L2) (symbol BTCUSDT)
     (frame d2))
    (Frame (recv_ts "2026-10-12 09:00:03Z") (stream Trades) (symbol BTCUSDT)
     (frame t3))
    |}];
  return ()
;;
