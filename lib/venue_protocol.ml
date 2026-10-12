open! Core
module Venue = Market_data.Venue
module Md_stream = Market_data.Stream

module Series = struct
  module T = struct
    type t =
      { stream : Md_stream.t
      ; symbol : string
      }
    [@@deriving sexp, compare, equal]
  end

  include T
  include Comparable.Make (T)
end

module Action = struct
  type t =
    | Subscribe of
        { series : Series.t list
        ; replies : string list
        }
    | Unsubscribe of
        { series : Series.t list
        ; replies : string list
        }
    | Reply of string list
    | Ignore
  [@@deriving sexp_of]
end

let supported =
  [ Venue.Binance; Bybit; Hyperliquid; Okx; Bitget; Deribit; Kraken; Coinbase ]
;;

let json = Yojson.Safe.to_string

let parse decode message =
  match decode (Yojson.Safe.from_string message) with
  | x -> Some x
  | exception _ -> None
;;

(* Small accessors for the venues parsed without a protocol library. *)
let field key : Yojson.Safe.t -> Yojson.Safe.t option = function
  | `Assoc fields -> List.Assoc.find fields key ~equal:String.equal
  | _ -> None
;;

let string_field key json =
  match field key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let list_field key json =
  match field key json with
  | Some (`List l) -> l
  | _ -> []
;;

let has_substring frame substring = String.is_substring frame ~substring

module Binance = struct
  open Binance_protocol

  let series_of (name : Stream_name.t) : Series.t list =
    let one stream symbol = [ { Series.stream; symbol = Symbol.to_string symbol } ] in
    match name with
    | Agg_trade symbol -> one Trades symbol
    | Book_ticker symbol -> one Bbo symbol
    | Diff_depth { symbol; _ } -> one L2 symbol
    | Mark_price { symbol; _ } -> one Funding symbol
    | Partial_depth _ | Other _ -> []
  ;;

  let on_message message : Action.t =
    match parse Subscribe.Request.t_of_yojson message with
    | None ->
      Reply
        [ json
            (Subscribe.Response.yojson_of_t
               (Error { code = 2; msg = "Invalid request"; id = None }))
        ]
    | Some { method_; params; id } ->
      let replies =
        [ json (Subscribe.Response.yojson_of_t (Result { result = `Null; id })) ]
      in
      let series = List.concat_map params ~f:series_of in
      (match method_ with
       | Subscribe -> Subscribe { series; replies }
       | Unsubscribe -> Unsubscribe { series; replies }
       | List_subscriptions ->
         Reply
           [ json (Subscribe.Response.yojson_of_t (Result { result = `List []; id })) ])
  ;;

  let is_data frame =
    String.is_prefix frame ~prefix:{|{"stream":|}
    ||
    match Yojson.Safe.from_string frame with
    | `Assoc fields ->
      List.Assoc.mem fields "stream" ~equal:String.equal
      && List.Assoc.mem fields "data" ~equal:String.equal
    | _ | (exception _) -> false
  ;;
end

module Bybit = struct
  open Bybit_protocol

  let series_of (topic : Topic.t) : Series.t list =
    let one stream symbol = [ { Series.stream; symbol = Symbol.to_string symbol } ] in
    match topic with
    | Public_trade symbol -> one Trades symbol
    | Orderbook { depth = 1; symbol } -> one Bbo symbol
    | Orderbook { symbol; _ } -> one L2 symbol
    | Tickers symbol -> one Funding symbol
    | Order _ | Execution _ | Position _ | Wallet | Other _ -> []
  ;;

  let ack ~conn_id ~req_id ~op ~ret_msg ~success =
    json
      (Op_response.yojson_of_t
         { success = Some success
         ; ret_msg = Some ret_msg
         ; conn_id = Some conn_id
         ; req_id
         ; op
         ; args = None
         })
  ;;

  let on_message ~conn_id message : Action.t =
    match parse Ws_request.t_of_yojson message with
    | None ->
      Reply
        [ ack
            ~conn_id
            ~req_id:None
            ~op:"unknown"
            ~ret_msg:"error: invalid request"
            ~success:false
        ]
    | Some (Subscribe { req_id; args }) ->
      Subscribe
        { series = List.concat_map args ~f:series_of
        ; replies = [ ack ~conn_id ~req_id ~op:"subscribe" ~ret_msg:"" ~success:true ]
        }
    | Some (Unsubscribe { req_id; args }) ->
      Unsubscribe
        { series = List.concat_map args ~f:series_of
        ; replies = [ ack ~conn_id ~req_id ~op:"unsubscribe" ~ret_msg:"" ~success:true ]
        }
    | Some (Ping { req_id }) ->
      Reply [ ack ~conn_id ~req_id ~op:"ping" ~ret_msg:"pong" ~success:true ]
    | Some (Auth { req_id; _ }) ->
      Reply
        [ ack
            ~conn_id
            ~req_id
            ~op:"auth"
            ~ret_msg:"error: the replay server has no private streams"
            ~success:false
        ]
  ;;

  let is_data frame = String.is_substring frame ~substring:{|"topic":|}
end

module Hyperliquid = struct
  open Hl_protocol

  let series_of_subscription (sub : Subscription.t) : Series.t list =
    match sub with
    | Trades { coin } -> [ { stream = Trades; symbol = Coin.to_string coin } ]
    | L2_book { coin } ->
      let symbol = Coin.to_string coin in
      [ { stream = L2; symbol }; { stream = Bbo; symbol } ]
    | Order_updates _ | User_fills _ | All_mids -> []
  ;;

  (* [activeAssetCtx] is not a [Subscription.t]. *)
  let active_asset_ctx json : Series.t list option =
    let open Yojson.Safe.Util in
    match member "subscription" json with
    | `Assoc _ as sub ->
      (match member "type" sub, member "coin" sub with
       | `String "activeAssetCtx", `String coin ->
         Some [ { stream = Funding; symbol = coin } ]
       | _ -> None)
    | _ | (exception _) -> None
  ;;

  let echo request_json =
    json (`Assoc [ "channel", `String "subscriptionResponse"; "data", request_json ])
  ;;

  let error message =
    json (Ws_message.yojson_of_t (Error ("Invalid subscription " ^ message)))
  ;;

  let on_message message : Action.t =
    match Yojson.Safe.from_string message with
    | exception _ -> Reply [ error message ]
    | request_json ->
      let method_ =
        match Yojson.Safe.Util.member "method" request_json with
        | `String m -> m
        | _ | (exception _) -> ""
      in
      let series =
        match Ws_request.t_of_yojson request_json with
        | Subscribe sub | Unsubscribe sub -> Some (series_of_subscription sub)
        | Ping -> Some []
        | exception _ -> active_asset_ctx request_json
      in
      (match method_, series with
       | "ping", _ -> Reply [ json (Ws_message.yojson_of_t Pong) ]
       | "subscribe", Some series -> Subscribe { series; replies = [ echo request_json ] }
       | "unsubscribe", Some series ->
         Unsubscribe { series; replies = [ echo request_json ] }
       | _ -> Reply [ error message ])
  ;;

  (* The channel name, without parsing the frame. *)
  let channel frame =
    let key = {|"channel":"|} in
    Option.bind (String.substr_index frame ~pattern:key) ~f:(fun i ->
      let start = i + String.length key in
      Option.map (String.index_from frame start '"') ~f:(fun stop ->
        String.sub frame ~pos:start ~len:(stop - start)))
  ;;

  let is_data frame =
    match channel frame with
    | Some ("subscriptionResponse" | "pong" | "error") -> false
    | Some _ | None -> true
  ;;
end

module Okx = struct
  let series_of arg : Series.t list =
    match string_field "channel" arg, string_field "instId" arg with
    | Some channel, Some symbol ->
      let one stream = [ { Series.stream; symbol } ] in
      (match channel with
       | "trades" | "trades-all" -> one Trades
       | "bbo-tbt" -> one Bbo
       | "books" | "books5" | "books-l2-tbt" | "books50-l2-tbt" | "books-elp" -> one L2
       | "funding-rate" | "mark-price" -> one Funding
       (* [index-tickers] of the index is recorded in the swap's funding files. *)
       | _ -> [])
    | _ -> []
  ;;

  let error ~conn_id message =
    json
      (`Assoc
        [ "event", `String "error"
        ; "code", `String "60012"
        ; "msg", `String ("Invalid request: " ^ message)
        ; "connId", `String conn_id
        ])
  ;;

  let on_message ~conn_id message : Action.t =
    if String.equal (String.strip message) "ping"
    then Reply [ "pong" ]
    else (
      match Yojson.Safe.from_string message with
      | exception _ -> Reply [ error ~conn_id message ]
      | request ->
        let args = list_field "args" request in
        let ack op arg =
          json (`Assoc [ "event", `String op; "arg", arg; "connId", `String conn_id ])
        in
        (match string_field "op" request with
         | Some (("subscribe" | "unsubscribe") as op) when not (List.is_empty args) ->
           let series = List.concat_map args ~f:series_of in
           let replies = List.map args ~f:(ack op) in
           if String.equal op "subscribe"
           then Subscribe { series; replies }
           else Unsubscribe { series; replies }
         | _ -> Reply [ error ~conn_id message ]))
  ;;

  (* Pushes start with [arg]; acks, errors and notices carry an [event]. *)
  let is_data frame =
    String.is_prefix frame ~prefix:{|{"arg":|}
    || ((not (has_substring frame {|"event":|})) && has_substring frame {|"data":|})
  ;;
end

module Bitget = struct
  let series_of arg : Series.t list =
    match string_field "channel" arg, string_field "instId" arg with
    | Some channel, Some symbol ->
      let one stream = [ { Series.stream; symbol } ] in
      (match channel with
       | "trade" -> one Trades
       | "books1" -> one Bbo
       | "books" | "books5" | "books15" -> one L2
       | "ticker" -> one Funding
       | _ -> [])
    | _ -> []
  ;;

  let error message =
    json
      (`Assoc
        [ "event", `String "error"
        ; "code", `Int 30001
        ; "msg", `String ("invalid request: " ^ message)
        ])
  ;;

  let on_message message : Action.t =
    if String.equal (String.strip message) "ping"
    then Reply [ "pong" ]
    else (
      match Yojson.Safe.from_string message with
      | exception _ -> Reply [ error message ]
      | request ->
        let args = list_field "args" request in
        let ack op arg = json (`Assoc [ "event", `String op; "arg", arg ]) in
        (match string_field "op" request with
         | Some (("subscribe" | "unsubscribe") as op) when not (List.is_empty args) ->
           let series = List.concat_map args ~f:series_of in
           let replies = List.map args ~f:(ack op) in
           if String.equal op "subscribe"
           then Subscribe { series; replies }
           else Unsubscribe { series; replies }
         | _ -> Reply [ error message ]))
  ;;

  (* Pushes start with [action]; acks and errors carry an [event]. *)
  let is_data frame =
    String.is_prefix frame ~prefix:{|{"action":|}
    || ((not (has_substring frame {|"event":|})) && has_substring frame {|"data":|})
  ;;
end

module Deribit = struct
  (* [trades.BTC-PERPETUAL.100ms], [quote.BTC-PERPETUAL], [book.BTC-PERPETUAL.100ms] or
     [book.BTC-PERPETUAL.none.10.100ms], [ticker.BTC-PERPETUAL.100ms]. *)
  let series_of channel : Series.t list =
    match String.split channel ~on:'.' with
    | kind :: symbol :: _ ->
      let one stream = [ { Series.stream; symbol } ] in
      (match kind with
       | "trades" -> one Trades
       | "quote" -> one Bbo
       | "book" -> one L2
       | "ticker" -> one Funding
       | _ -> [])
    | _ -> []
  ;;

  let us time =
    `Intlit Int63.(to_string (Time_ns.to_int63_ns_since_epoch time / of_int 1000))
  ;;

  let response ~now ~id body =
    json
      (`Assoc
        ([ "jsonrpc", `String "2.0"; "id", id ]
         @ body
         @ [ "usIn", us now; "usOut", us now; "usDiff", `Int 0; "testnet", `Bool false ]))
  ;;

  let error ~now ~id ~code message =
    response
      ~now
      ~id
      [ "error", `Assoc [ "code", `Int code; "message", `String message ] ]
  ;;

  let on_message ~now message : Action.t =
    match Yojson.Safe.from_string message with
    | exception _ -> Reply [ error ~now ~id:`Null ~code:(-32700) "parse_error" ]
    | request ->
      let id = Option.value (field "id" request) ~default:`Null in
      let channels () =
        Option.value_map (field "params" request) ~default:[] ~f:(list_field "channels")
        |> List.filter_map ~f:(function
          | `String c -> Some c
          | _ -> None)
      in
      let result value = response ~now ~id [ "result", value ] in
      (match string_field "method" request with
       | Some (("public/subscribe" | "public/unsubscribe") as method_) ->
         let channels = channels () in
         let series = List.concat_map channels ~f:series_of in
         let replies = [ result (`List (List.map channels ~f:(fun c -> `String c))) ] in
         if String.equal method_ "public/subscribe"
         then Subscribe { series; replies }
         else Unsubscribe { series; replies }
       | Some ("public/set_heartbeat" | "public/disable_heartbeat") ->
         Reply [ result (`String "ok") ]
       | Some "public/test" ->
         Reply [ result (`Assoc [ "version", `String "market-replay" ]) ]
       | Some _ | None -> Reply [ error ~now ~id ~code:(-32601) "Method not found" ])
  ;;

  (* Notifications; responses, heartbeats and test requests are not passed on. *)
  let is_data frame = has_substring frame {|"method":"subscription"|}
end

module Kraken = struct
  let iso time = `String (Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc)

  let strings json key =
    list_field key json
    |> List.filter_map ~f:(function
      | `String s -> Some s
      | _ -> None)
  ;;

  (* Spot v2: [{"method": "subscribe", "params": {"channel": ..., "symbol": [...]}}]. *)
  module Spot = struct
    let series_of ~channel symbol : Series.t list =
      let one stream = [ { Series.stream; symbol } ] in
      match channel with
      | "trade" -> one Trades
      | "ticker" -> one Bbo
      | "book" -> one L2
      | _ -> []
    ;;

    let reply ~now ~method_ ~req_id fields =
      json
        (`Assoc
          ([ "method", `String method_ ]
           @ fields
           @ Option.value_map req_id ~default:[] ~f:(fun id -> [ "req_id", id ])
           @ [ "time_in", iso now; "time_out", iso now ]))
    ;;

    let on_message ~now ~method_ request : Action.t =
      let req_id = field "req_id" request in
      let params = Option.value (field "params" request) ~default:(`Assoc []) in
      match method_, string_field "channel" params with
      | "ping", _ -> Reply [ reply ~now ~method_:"pong" ~req_id [] ]
      | ("subscribe" | "unsubscribe"), Some channel ->
        let symbols = strings params "symbol" in
        let others =
          match params with
          | `Assoc fields ->
            List.filter fields ~f:(fun (key, _) -> not (String.equal key "symbol"))
          | _ -> []
        in
        let ack symbol =
          reply
            ~now
            ~method_
            ~req_id
            [ "result", `Assoc (others @ [ "symbol", `String symbol ])
            ; "success", `Bool true
            ]
        in
        let series = List.concat_map symbols ~f:(series_of ~channel) in
        let replies = List.map symbols ~f:ack in
        if String.equal method_ "subscribe"
        then Subscribe { series; replies }
        else Unsubscribe { series; replies }
      | _ ->
        Reply
          [ reply
              ~now
              ~method_
              ~req_id
              [ "error", `String "Unsupported request"; "success", `Bool false ]
          ]
    ;;
  end

  (* Futures v1: [{"event": "subscribe", "feed": ..., "product_ids": [...]}]. *)
  module Futures = struct
    let on_message ~event request : Action.t =
      let symbols = strings request "product_ids" in
      match event, string_field "feed" request with
      | ("subscribe" | "unsubscribe"), Some feed ->
        let series : Series.t list =
          match feed with
          | "ticker" ->
            List.map symbols ~f:(fun symbol -> { Series.stream = Funding; symbol })
          | _ -> []
        in
        let replies =
          [ json
              (`Assoc
                [ "event", `String (event ^ "d")
                ; "feed", `String feed
                ; "product_ids", `List (List.map symbols ~f:(fun s -> `String s))
                ])
          ]
        in
        if String.equal event "subscribe"
        then Subscribe { series; replies }
        else Unsubscribe { series; replies }
      | _ ->
        Reply
          [ json (`Assoc [ "event", `String "error"; "message", `String "Invalid feed" ])
          ]
    ;;
  end

  let on_message ~now message : Action.t =
    match Yojson.Safe.from_string message with
    | exception _ ->
      Reply
        [ json (`Assoc [ "error", `String "Malformed request"; "success", `Bool false ]) ]
    | request ->
      (match string_field "method" request, string_field "event" request with
       | Some method_, _ -> Spot.on_message ~now ~method_ request
       | None, Some event -> Futures.on_message ~event request
       | None, None ->
         Reply
           [ json
               (`Assoc [ "error", `String "Malformed request"; "success", `Bool false ])
           ])
  ;;

  (* Spot pushes have a [channel] other than [heartbeat] and [status]; futures pushes a
     [feed] and no [event]. Acks and pongs carry [method] or [event]. *)
  let is_data frame =
    if String.is_prefix frame ~prefix:{|{"channel":"|}
    then
      not
        (String.is_prefix frame ~prefix:{|{"channel":"heartbeat"|}
         || String.is_prefix frame ~prefix:{|{"channel":"status"|})
    else
      (not (String.is_prefix frame ~prefix:{|{"method":|}))
      && has_substring frame {|"feed":"|}
      && not (has_substring frame {|"event":"|})
  ;;
end

module Coinbase = struct
  (* What a connection is subscribed to, echoed in every [subscriptions] reply, and the
     next [sequence_num]: Coinbase numbers every frame of a connection, so recorded
     numbers are replaced. *)
  type t =
    { mutable subscriptions : String.Set.t String.Map.t
    ; mutable sequence : int
    }

  let create () = { subscriptions = String.Map.empty; sequence = 0 }

  let series_of ~channel symbol : Series.t list =
    let one stream = [ { Series.stream; symbol } ] in
    match channel with
    | "market_trades" -> one Trades
    | "ticker" | "ticker_batch" -> one Bbo
    | "level2" | "l2_data" -> one L2
    | _ -> []
  ;;

  let error message =
    json (`Assoc [ "type", `String "error"; "message", `String message ])
  ;;

  let subscriptions t ~now =
    json
      (`Assoc
        [ "channel", `String "subscriptions"
        ; "client_id", `String ""
        ; ( "timestamp"
          , `String (Time_ns.to_string_iso8601_basic now ~zone:Time_float.Zone.utc) )
        ; "sequence_num", `Int 0
        ; ( "events"
          , `List
              [ `Assoc
                  [ ( "subscriptions"
                    , `Assoc
                        (Map.to_alist t.subscriptions
                         |> List.map ~f:(fun (channel, ids) ->
                           ( channel
                           , `List (Set.to_list ids |> List.map ~f:(fun s -> `String s)) ))
                        ) )
                  ]
              ] )
        ])
  ;;

  let on_message t ~now message : Action.t =
    match Yojson.Safe.from_string message with
    | exception _ -> Reply [ error "malformed request" ]
    | request ->
      let product_ids =
        list_field "product_ids" request
        |> List.filter_map ~f:(function
          | `String s -> Some s
          | _ -> None)
      in
      (match string_field "type" request, string_field "channel" request with
       | Some (("subscribe" | "unsubscribe") as type_), Some channel ->
         let ids =
           String.Set.of_list
             (if String.equal channel "heartbeats" then [ channel ] else product_ids)
         in
         let current =
           Map.find t.subscriptions channel |> Option.value ~default:String.Set.empty
         in
         let updated =
           if String.equal type_ "subscribe"
           then Set.union current ids
           else Set.diff current ids
         in
         t.subscriptions
         <- (if Set.is_empty updated
             then Map.remove t.subscriptions channel
             else Map.set t.subscriptions ~key:channel ~data:updated);
         let series = List.concat_map product_ids ~f:(series_of ~channel) in
         let replies = [ subscriptions t ~now ] in
         if String.equal type_ "subscribe"
         then Subscribe { series; replies }
         else Unsubscribe { series; replies }
       | _ -> Reply [ error "Failed to subscribe" ])
  ;;

  let sequence_key = {|"sequence_num":|}

  (* Replaces the number after the first [sequence_num]. *)
  let outgoing t frame =
    match String.substr_index frame ~pattern:sequence_key with
    | None -> frame
    | Some i ->
      let start = i + String.length sequence_key in
      let stop =
        String.lfindi frame ~pos:start ~f:(fun _ c -> not (Char.is_digit c))
        |> Option.value ~default:(String.length frame)
      in
      let sequence = t.sequence in
      t.sequence <- sequence + 1;
      String.concat
        [ String.prefix frame start
        ; Int.to_string sequence
        ; String.drop_prefix frame stop
        ]
  ;;

  (* Recorded [subscriptions] replies and [heartbeats] are not passed on. *)
  let is_data frame =
    String.is_prefix frame ~prefix:{|{"channel":"|}
    && not
         (String.is_prefix frame ~prefix:{|{"channel":"subscriptions"|}
          || String.is_prefix frame ~prefix:{|{"channel":"heartbeats"|})
  ;;
end

module Session = struct
  type t =
    { venue : Venue.t
    ; conn_id : string
    ; coinbase : Coinbase.t
    }

  let create venue ~conn_id = { venue; conn_id; coinbase = Coinbase.create () }

  let on_message t ~now message : Action.t =
    match t.venue with
    | Binance -> Binance.on_message message
    | Bybit -> Bybit.on_message ~conn_id:t.conn_id message
    | Hyperliquid -> Hyperliquid.on_message message
    | Okx -> Okx.on_message ~conn_id:t.conn_id message
    | Bitget -> Bitget.on_message message
    | Deribit -> Deribit.on_message ~now message
    | Kraken -> Kraken.on_message ~now message
    | Coinbase -> Coinbase.on_message t.coinbase ~now message
    | Nyse | Cboe | Cme -> Ignore
  ;;

  let outgoing t frame =
    match t.venue with
    | Coinbase -> Coinbase.outgoing t.coinbase frame
    | _ -> frame
  ;;
end

let on_message venue ~conn_id message =
  Session.on_message (Session.create venue ~conn_id) ~now:Time_ns.epoch message
;;

let is_data (venue : Venue.t) frame =
  match venue with
  | Binance -> Binance.is_data frame
  | Bybit -> Bybit.is_data frame
  | Hyperliquid -> Hyperliquid.is_data frame
  | Okx -> Okx.is_data frame
  | Bitget -> Bitget.is_data frame
  | Deribit -> Deribit.is_data frame
  | Kraken -> Kraken.is_data frame
  | Coinbase -> Coinbase.is_data frame
  | Nyse | Cboe | Cme -> true
;;
