open! Core
open Market_replay

let show venue message =
  print_s
    [%sexp
      (Venue_protocol.on_message venue ~conn_id:"c1" message : Venue_protocol.Action.t)]
;;

let streams = Market_data.Stream.[ Trades; Bbo; L2; Funding ]

let%expect_test "binance-client subscriptions" =
  List.iter streams ~f:(fun stream ->
    let _route, params =
      Binance_client.Live_feed.stream_names
        stream
        [ Binance_protocol.Symbol.of_string "btcusdt" ]
    in
    show
      Binance
      (Yojson.Safe.to_string
         (Binance_protocol.Subscribe.Request.yojson_of_t
            { method_ = Subscribe; params; id = 7 })));
  show Binance {|{"method":"UNSUBSCRIBE","params":["btcusdt@depth5"],"id":8}|};
  show Binance "not json";
  [%expect
    {|
    (Subscribe (series (((stream Trades) (symbol BTCUSDT))))
     (replies ("{\"result\":null,\"id\":7}")))
    (Subscribe (series (((stream Bbo) (symbol BTCUSDT))))
     (replies ("{\"result\":null,\"id\":7}")))
    (Subscribe (series (((stream L2) (symbol BTCUSDT))))
     (replies ("{\"result\":null,\"id\":7}")))
    (Subscribe (series (((stream Funding) (symbol BTCUSDT))))
     (replies ("{\"result\":null,\"id\":7}")))
    (Unsubscribe (series ()) (replies ("{\"result\":null,\"id\":8}")))
    (Reply ("{\"code\":2,\"msg\":\"Invalid request\"}"))
    |}]
;;

let%expect_test "bybit-client subscriptions" =
  List.iter streams ~f:(fun stream ->
    show
      Bybit
      (Yojson.Safe.to_string
         (Bybit_protocol.Ws_request.yojson_of_t
            (Subscribe
               { req_id = Some "r1"
               ; args =
                   [ Bybit_client.Live_feed.topic
                       stream
                       (Bybit_protocol.Symbol.of_string "BTCUSDT")
                   ]
               }))));
  show Bybit {|{"op":"ping"}|};
  show Bybit {|{"op":"auth","args":["k",1,"s"]}|};
  [%expect
    {|
    (Subscribe (series (((stream Trades) (symbol BTCUSDT))))
     (replies
      ("{\"success\":true,\"ret_msg\":\"\",\"conn_id\":\"c1\",\"req_id\":\"r1\",\"op\":\"subscribe\"}")))
    (Subscribe (series (((stream Bbo) (symbol BTCUSDT))))
     (replies
      ("{\"success\":true,\"ret_msg\":\"\",\"conn_id\":\"c1\",\"req_id\":\"r1\",\"op\":\"subscribe\"}")))
    (Subscribe (series (((stream L2) (symbol BTCUSDT))))
     (replies
      ("{\"success\":true,\"ret_msg\":\"\",\"conn_id\":\"c1\",\"req_id\":\"r1\",\"op\":\"subscribe\"}")))
    (Subscribe (series (((stream Funding) (symbol BTCUSDT))))
     (replies
      ("{\"success\":true,\"ret_msg\":\"\",\"conn_id\":\"c1\",\"req_id\":\"r1\",\"op\":\"subscribe\"}")))
    (Reply
     ("{\"success\":true,\"ret_msg\":\"pong\",\"conn_id\":\"c1\",\"op\":\"ping\"}"))
    (Reply
     ("{\"success\":false,\"ret_msg\":\"error: the replay server has no private streams\",\"conn_id\":\"c1\",\"op\":\"auth\"}"))
    |}]
;;

let%expect_test "hl-client subscriptions" =
  List.iter
    (Hl_client.Live_feed.For_testing.subscribe_requests ~symbols:[ "BTC" ] ~streams)
    ~f:(show Hyperliquid);
  show Hyperliquid {|{"method":"ping"}|};
  show Hyperliquid {|{"method":"subscribe","subscription":{"type":"candle"}}|};
  show Nyse {|{"op":"subscribe"}|};
  [%expect
    {|
    (Subscribe (series (((stream Trades) (symbol BTC))))
     (replies
      ("{\"channel\":\"subscriptionResponse\",\"data\":{\"method\":\"subscribe\",\"subscription\":{\"type\":\"trades\",\"coin\":\"BTC\"}}}")))
    (Subscribe (series (((stream L2) (symbol BTC)) ((stream Bbo) (symbol BTC))))
     (replies
      ("{\"channel\":\"subscriptionResponse\",\"data\":{\"method\":\"subscribe\",\"subscription\":{\"type\":\"l2Book\",\"coin\":\"BTC\"}}}")))
    (Subscribe (series (((stream Funding) (symbol BTC))))
     (replies
      ("{\"channel\":\"subscriptionResponse\",\"data\":{\"method\":\"subscribe\",\"subscription\":{\"type\":\"activeAssetCtx\",\"coin\":\"BTC\"}}}")))
    (Reply ("{\"channel\":\"pong\"}"))
    (Reply
     ("{\"channel\":\"error\",\"data\":\"Invalid subscription {\\\"method\\\":\\\"subscribe\\\",\\\"subscription\\\":{\\\"type\\\":\\\"candle\\\"}}\"}"))
    Ignore
    |}]
;;

let%expect_test "okx-feed subscriptions" =
  List.iter streams ~f:(fun stream ->
    show
      Okx
      (Okx_feed.Wire.Request.to_string
         Subscribe
         (Okx_feed.Live_feed.args stream ~symbols:[ "BTC-USDT-SWAP" ])));
  show Okx {|{"op":"unsubscribe","args":[{"channel":"books","instId":"BTC-USDT-SWAP"}]}|};
  show Okx "ping";
  show Okx {|{"op":"login"}|};
  [%expect
    {|
    (Subscribe (series (((stream Trades) (symbol BTC-USDT-SWAP))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"channel\":\"trades\",\"instId\":\"BTC-USDT-SWAP\"},\"connId\":\"c1\"}")))
    (Subscribe (series (((stream Bbo) (symbol BTC-USDT-SWAP))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"channel\":\"bbo-tbt\",\"instId\":\"BTC-USDT-SWAP\"},\"connId\":\"c1\"}")))
    (Subscribe (series (((stream L2) (symbol BTC-USDT-SWAP))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"channel\":\"books\",\"instId\":\"BTC-USDT-SWAP\"},\"connId\":\"c1\"}")))
    (Subscribe
     (series
      (((stream Funding) (symbol BTC-USDT-SWAP))
       ((stream Funding) (symbol BTC-USDT-SWAP))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"channel\":\"funding-rate\",\"instId\":\"BTC-USDT-SWAP\"},\"connId\":\"c1\"}"
       "{\"event\":\"subscribe\",\"arg\":{\"channel\":\"mark-price\",\"instId\":\"BTC-USDT-SWAP\"},\"connId\":\"c1\"}"
       "{\"event\":\"subscribe\",\"arg\":{\"channel\":\"index-tickers\",\"instId\":\"BTC-USDT\"},\"connId\":\"c1\"}")))
    (Unsubscribe (series (((stream L2) (symbol BTC-USDT-SWAP))))
     (replies
      ("{\"event\":\"unsubscribe\",\"arg\":{\"channel\":\"books\",\"instId\":\"BTC-USDT-SWAP\"},\"connId\":\"c1\"}")))
    (Reply (pong))
    (Reply
     ("{\"event\":\"error\",\"code\":\"60012\",\"msg\":\"Invalid request: {\\\"op\\\":\\\"login\\\"}\",\"connId\":\"c1\"}"))
    |}]
;;

let%expect_test "bitget-feed subscriptions" =
  let config = Bitget_feed.Config.create () in
  List.iter streams ~f:(fun stream ->
    show
      Bitget
      (Bitget_feed.Wire.subscribe [ Bitget_feed.Live_feed.arg config stream "BTCUSDT" ]));
  show
    Bitget
    (Bitget_feed.Wire.unsubscribe [ Bitget_feed.Live_feed.arg config L2 "BTCUSDT" ]);
  show Bitget "ping";
  show Bitget {|{"op":"login","args":[]}|};
  [%expect
    {|
    (Subscribe (series (((stream Trades) (symbol BTCUSDT))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"instType\":\"USDT-FUTURES\",\"channel\":\"trade\",\"instId\":\"BTCUSDT\"}}")))
    (Subscribe (series (((stream Bbo) (symbol BTCUSDT))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"instType\":\"USDT-FUTURES\",\"channel\":\"books1\",\"instId\":\"BTCUSDT\"}}")))
    (Subscribe (series (((stream L2) (symbol BTCUSDT))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"instType\":\"USDT-FUTURES\",\"channel\":\"books\",\"instId\":\"BTCUSDT\"}}")))
    (Subscribe (series (((stream Funding) (symbol BTCUSDT))))
     (replies
      ("{\"event\":\"subscribe\",\"arg\":{\"instType\":\"USDT-FUTURES\",\"channel\":\"ticker\",\"instId\":\"BTCUSDT\"}}")))
    (Unsubscribe (series (((stream L2) (symbol BTCUSDT))))
     (replies
      ("{\"event\":\"unsubscribe\",\"arg\":{\"instType\":\"USDT-FUTURES\",\"channel\":\"books\",\"instId\":\"BTCUSDT\"}}")))
    (Reply (pong))
    (Reply
     ("{\"event\":\"error\",\"code\":30001,\"msg\":\"invalid request: {\\\"op\\\":\\\"login\\\",\\\"args\\\":[]}\"}"))
    |}]
;;

let%expect_test "deribit-feed subscriptions" =
  let config = Deribit_feed.Config.create () in
  show
    Deribit
    (Deribit_feed.Wire.subscribe
       ~id:2
       (List.map streams ~f:(fun stream ->
          Deribit_feed.Live_feed.channel config stream "BTC-PERPETUAL")));
  show Deribit (Deribit_feed.Wire.set_heartbeat ~id:1 ~seconds:30);
  show Deribit (Deribit_feed.Wire.test ~id:0);
  show Deribit {|{"jsonrpc":"2.0","id":9,"method":"private/buy","params":{}}|};
  [%expect
    {|
    (Subscribe
     (series
      (((stream Trades) (symbol BTC-PERPETUAL))
       ((stream Bbo) (symbol BTC-PERPETUAL)) ((stream L2) (symbol BTC-PERPETUAL))
       ((stream Funding) (symbol BTC-PERPETUAL))))
     (replies
      ("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[\"trades.BTC-PERPETUAL.100ms\",\"quote.BTC-PERPETUAL\",\"book.BTC-PERPETUAL.100ms\",\"ticker.BTC-PERPETUAL.100ms\"],\"usIn\":0,\"usOut\":0,\"usDiff\":0,\"testnet\":false}")))
    (Reply
     ("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"ok\",\"usIn\":0,\"usOut\":0,\"usDiff\":0,\"testnet\":false}"))
    (Reply
     ("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"version\":\"market-replay\"},\"usIn\":0,\"usOut\":0,\"usDiff\":0,\"testnet\":false}"))
    (Reply
     ("{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"usIn\":0,\"usOut\":0,\"usDiff\":0,\"testnet\":false}"))
    |}]
;;

let%expect_test "is_data" =
  List.iter
    [ Market_data.Venue.Binance, {|{"stream":"btcusdt@aggTrade","data":{}}|}
    ; Binance, {|{"result":null,"id":1}|}
    ; Binance, {|{"lastUpdateId":1,"E":2,"T":3,"bids":[],"asks":[]}|}
    ; Bybit, {|{"topic":"publicTrade.BTCUSDT","type":"snapshot","data":[]}|}
    ; Bybit, {|{"success":true,"ret_msg":"","op":"subscribe","conn_id":"x"}|}
    ; Hyperliquid, {|{"channel":"trades","data":[]}|}
    ; Hyperliquid, {|{"channel":"subscriptionResponse","data":{}}|}
    ; Hyperliquid, {|{"channel":"pong"}|}
    ; Okx, {|{"arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"data":[]}|}
    ; Okx, {|{"event":"subscribe","arg":{"channel":"trades"},"connId":"a"}|}
    ; Okx, "pong"
    ; Bitget, {|{"action":"snapshot","arg":{"channel":"trade"},"data":[]}|}
    ; Bitget, {|{"event":"subscribe","arg":{"channel":"trade"}}|}
    ; Bitget, "pong"
    ; Deribit, {|{"jsonrpc":"2.0","method":"subscription","params":{"channel":"x"}}|}
    ; Deribit, {|{"jsonrpc":"2.0","method":"heartbeat","params":{"type":"test_request"}}|}
    ; Deribit, {|{"jsonrpc":"2.0","id":3,"result":"ok"}|}
    ]
    ~f:(fun (venue, frame) -> printf "%b %s\n" (Venue_protocol.is_data venue frame) frame);
  [%expect
    {|
    true {"stream":"btcusdt@aggTrade","data":{}}
    false {"result":null,"id":1}
    false {"lastUpdateId":1,"E":2,"T":3,"bids":[],"asks":[]}
    true {"topic":"publicTrade.BTCUSDT","type":"snapshot","data":[]}
    false {"success":true,"ret_msg":"","op":"subscribe","conn_id":"x"}
    true {"channel":"trades","data":[]}
    false {"channel":"subscriptionResponse","data":{}}
    false {"channel":"pong"}
    true {"arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"data":[]}
    false {"event":"subscribe","arg":{"channel":"trades"},"connId":"a"}
    false pong
    true {"action":"snapshot","arg":{"channel":"trade"},"data":[]}
    false {"event":"subscribe","arg":{"channel":"trade"}}
    false pong
    true {"jsonrpc":"2.0","method":"subscription","params":{"channel":"x"}}
    false {"jsonrpc":"2.0","method":"heartbeat","params":{"type":"test_request"}}
    false {"jsonrpc":"2.0","id":3,"result":"ok"}
    |}]
;;
