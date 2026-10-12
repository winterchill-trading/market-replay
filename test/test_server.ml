open! Core
open! Async
open Market_replay

let ts s = Raw_line.parse_time s |> ok_exn

let source =
  Source.of_items
    [ ( Binance
      , Frame
          { recv_ts = ts "2026-10-12T09:00:00.1Z"
          ; stream = Trades
          ; symbol = "BTCUSDT"
          ; frame = {|{"stream":"btcusdt@aggTrade","data":{}}|}
          } )
    ; ( Binance
      , Gap { recv_ts = ts "2026-10-12T09:00:00.1Z"; stream = Trades; symbol = "BTCUSDT" }
      )
    ; ( Binance
      , Frame
          { recv_ts = ts "2026-10-12T09:00:00.2Z"
          ; stream = L2
          ; symbol = "BTCUSDT"
          ; frame = {|{"stream":"btcusdt@depth@100ms","data":{}}|}
          } )
    ; ( Binance
      , Frame
          { recv_ts = ts "2026-10-12T09:00:00.3Z"
          ; stream = Bbo
          ; symbol = "BTCUSDT"
          ; frame = {|{"stream":"btcusdt@bookTicker","data":{}}|}
          } )
    ]
;;

let get server path =
  let port = Cohttp_async.Server.listening_on server in
  let%bind response, body =
    Cohttp_async.Client.get (Uri.of_string (sprintf "http://localhost:%d%s" port path))
  in
  let%map body = Cohttp_async.Body.to_string body in
  printf
    "%d %s\n%s"
    (Cohttp.Code.code_of_status (Cohttp.Response.status response))
    (Option.value
       (Cohttp.Header.get (Cohttp.Response.headers response) "transfer-encoding")
       ~default:"-")
    body
;;

let%expect_test "GET /replay streams raw lines" =
  let%bind server = Server.start (Server.create source) ~port:0 in
  let%bind () =
    get
      server
      "/replay?venue=binance&symbol=BTCUSDT&streams=trade,l2&from=2026-10-12T09:00:00Z&to=2026-10-12T09:01:00Z"
  in
  [%expect
    {|
    200 chunked
    2026-10-12T09:00:00.100000Z {"stream":"btcusdt@aggTrade","data":{}}

    2026-10-12T09:00:00.200000Z {"stream":"btcusdt@depth@100ms","data":{}}
    |}];
  let%bind () = get server "/replay?venue=binance" in
  let%bind () = get server "/nope" in
  [%expect
    {|
    400 -
    ("missing query parameter" symbol)
    404 -
    no route for /nope
    |}];
  Cohttp_async.Server.close server
;;
