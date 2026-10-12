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

let supported = [ Venue.Binance; Bybit; Hyperliquid ]
let json = Yojson.Safe.to_string

let parse decode message =
  match decode (Yojson.Safe.from_string message) with
  | x -> Some x
  | exception _ -> None
;;

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

module Session = struct
  type t =
    { venue : Venue.t
    ; conn_id : string
    }

  let create venue ~conn_id = { venue; conn_id }

  let on_message t ~now:_ message : Action.t =
    match t.venue with
    | Binance -> Binance.on_message message
    | Bybit -> Bybit.on_message ~conn_id:t.conn_id message
    | Hyperliquid -> Hyperliquid.on_message message
    | Okx | Coinbase | Kraken | Deribit | Bitget | Nyse | Cboe | Cme -> Ignore
  ;;

  let outgoing _ frame = frame
end

let on_message venue ~conn_id message =
  Session.on_message (Session.create venue ~conn_id) ~now:Time_ns.epoch message
;;

let is_data (venue : Venue.t) frame =
  match venue with
  | Binance -> Binance.is_data frame
  | Bybit -> Bybit.is_data frame
  | Hyperliquid -> Hyperliquid.is_data frame
  | Okx | Coinbase | Kraken | Deribit | Bitget | Nyse | Cboe | Cme -> true
;;
