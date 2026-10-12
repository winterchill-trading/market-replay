open! Core
open! Async
open Market_replay

let ts s = Raw_line.parse_time s |> ok_exn
let start = ts "2026-10-12T09:00:00Z"

let trade symbol offset_ms =
  ( Market_data.Venue.Hyperliquid
  , Source.Item.Frame
      { recv_ts = Time_ns.add start (Time_ns.Span.of_int_ms offset_ms)
      ; stream = Trades
      ; symbol
      ; frame = sprintf {|{"channel":"trades","data":"%s+%d"}|} symbol offset_ms
      } )
;;

let source =
  Source.of_items
    [ trade "BTC" 0
    ; trade "BTC" 1000
    ; ( Hyperliquid
      , Gap
          { recv_ts = Time_ns.add start (Time_ns.Span.of_int_ms 1000)
          ; stream = Trades
          ; symbol = "BTC"
          } )
    ; trade "BTC" 3000
    ; trade "ETH" 1500
    ; trade "ETH" 2500
    ]
;;

let subscribe coin =
  sprintf {|{"method":"subscribe","subscription":{"type":"trades","coin":"%s"}}|} coin
;;

(* Runs a session on a synthetic clock, printing what is sent and when (ms since the
   session was created). *)
let run ?(late = []) ~speed () =
  let time_source = Time_source.create ~now:(ts "2026-01-01T00:00:00Z") () in
  let t0 = Time_source.now time_source in
  let send frame =
    printf
      "%5d %s\n"
      (Time_ns.Span.to_int_ms (Time_ns.diff (Time_source.now time_source) t0))
      frame;
    return ()
  in
  let session =
    Ws_replay.create
      ~time_source:(Time_source.read_only time_source)
      (Ws_replay.Config.create ~speed ~start ())
      source
      ~venue:Hyperliquid
      ~conn_id:"c"
      ~send
  in
  let%bind () = Ws_replay.on_message session (subscribe "BTC") in
  let%bind () = Ws_replay.on_message session {|{"method":"ping"}|} in
  let late = ref late in
  let rec step n =
    if n = 0
    then return ()
    else (
      let%bind () =
        match !late with
        | (at_ms, message) :: rest
          when Time_ns.Span.to_int_ms (Time_ns.diff (Time_source.now time_source) t0)
               >= at_ms ->
          late := rest;
          Ws_replay.on_message session message
        | _ -> return ()
      in
      let%bind () =
        Time_source.advance_by_alarms_by time_source (Time_ns.Span.of_int_ms 100)
      in
      let%bind () = Scheduler.yield_until_no_jobs_remain () in
      step (n - 1))
  in
  let%map () = step 60 in
  print_s [%sexp (Ws_replay.stats session : Ws_replay.Stats.t)];
  Ws_replay.close session
;;

let%expect_test "real time keeps recorded gaps after the settle delay" =
  let%bind () = run ~speed:1. () in
  [%expect
    {|
        0 {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"trades","coin":"BTC"}}}
        0 {"channel":"pong"}
      200 {"channel":"trades","data":"BTC+0"}
     1200 {"channel":"trades","data":"BTC+1000"}
     3200 {"channel":"trades","data":"BTC+3000"}
    ((frames_sent 3) (replies_sent 2) (gaps_skipped 1))
    |}];
  return ()
;;

let%expect_test "double speed, and a late subscription joins at the position" =
  let%bind () = run ~speed:2. ~late:[ 1000, subscribe "ETH" ] () in
  [%expect
    {|
        0 {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"trades","coin":"BTC"}}}
        0 {"channel":"pong"}
      200 {"channel":"trades","data":"BTC+0"}
      700 {"channel":"trades","data":"BTC+1000"}
     1000 {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"trades","coin":"ETH"}}}
     1450 {"channel":"trades","data":"ETH+2500"}
     1700 {"channel":"trades","data":"BTC+3000"}
    ((frames_sent 4) (replies_sent 3) (gaps_skipped 1))
    |}];
  return ()
;;

let%expect_test "speed 0 sends everything at once" =
  let%bind () = run ~speed:0. () in
  [%expect
    {|
        0 {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"trades","coin":"BTC"}}}
        0 {"channel":"pong"}
      200 {"channel":"trades","data":"BTC+0"}
      200 {"channel":"trades","data":"BTC+1000"}
      200 {"channel":"trades","data":"BTC+3000"}
    ((frames_sent 3) (replies_sent 2) (gaps_skipped 1))
    |}];
  return ()
;;

let%expect_test "a request naming one series twice replays it once" =
  let source =
    Source.of_items
      [ ( Okx
        , Frame
            { recv_ts = start
            ; stream = Funding
            ; symbol = "BTC-USDT-SWAP"
            ; frame = {|{"arg":{"channel":"mark-price"},"data":[]}|}
            } )
      ]
  in
  let session =
    Ws_replay.create
      (Ws_replay.Config.create ~speed:0. ~settle:Time_ns.Span.zero ~start ())
      source
      ~venue:Okx
      ~conn_id:"c"
      ~send:(fun frame ->
        print_endline frame;
        return ())
  in
  let%bind () =
    Ws_replay.on_message
      session
      {|{"op":"subscribe","args":[{"channel":"funding-rate","instId":"BTC-USDT-SWAP"},{"channel":"mark-price","instId":"BTC-USDT-SWAP"}]}|}
  in
  let%bind () = Ws_replay.finished session in
  print_s [%sexp (Ws_replay.stats session : Ws_replay.Stats.t)];
  Ws_replay.close session;
  [%expect
    {|
    {"event":"subscribe","arg":{"channel":"funding-rate","instId":"BTC-USDT-SWAP"},"connId":"c"}
    {"event":"subscribe","arg":{"channel":"mark-price","instId":"BTC-USDT-SWAP"},"connId":"c"}
    {"arg":{"channel":"mark-price"},"data":[]}
    ((frames_sent 1) (replies_sent 2) (gaps_skipped 0))
    |}];
  return ()
;;

let%expect_test "hold pauses the replay after an item" =
  let release = Ivar.create () in
  let hold item =
    match (item : Source.Item.t) with
    | Frame { frame; _ } when String.is_substring frame ~substring:"BTC+0" ->
      print_endline "holding";
      Ivar.read release
    | _ -> return ()
  in
  let session =
    Ws_replay.create
      ~hold
      (Ws_replay.Config.create ~speed:0. ~settle:Time_ns.Span.zero ~start ())
      source
      ~venue:Hyperliquid
      ~conn_id:"c"
      ~send:(fun frame ->
        print_endline frame;
        return ())
  in
  let%bind () = Ws_replay.on_message session (subscribe "BTC") in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
  print_endline "released";
  Ivar.fill_exn release ();
  let%bind () = Ws_replay.finished session in
  Ws_replay.close session;
  [%expect
    {|
    {"channel":"subscriptionResponse","data":{"method":"subscribe","subscription":{"type":"trades","coin":"BTC"}}}
    {"channel":"trades","data":"BTC+0"}
    holding
    released
    {"channel":"trades","data":"BTC+1000"}
    {"channel":"trades","data":"BTC+3000"}
    |}];
  return ()
;;
