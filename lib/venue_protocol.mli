(** What a replay websocket says to a client, per venue: parse the client's real subscribe
    messages, answer like the venue, and pick which recorded frames to pass on.

    - Binance USD-M ([/ws/binance], any path below it, e.g. the combined
      [/ws/binance/stream]): [{"method": "SUBSCRIBE", "params": [...], "id": n}] is
      answered with [{"result": null, "id": n}]. [<s>@aggTrade] is [Trades],
      [<s>@bookTicker] [Bbo], [<s>@depth...] [L2], [<s>@markPrice...] [Funding]. Recorded
      subscription responses and REST depth snapshots are not passed on.
    - Bybit v5 linear ([/ws/bybit]): [{"op": "subscribe", "args": [...]}] is answered with
      a [success] ack, [{"op": "ping"}] with a pong. [publicTrade.<s>] is [Trades],
      [orderbook.1.<s>] [Bbo], [orderbook.<n>.<s>] [L2], [tickers.<s>] [Funding]. Only
      recorded frames with a [topic] are passed on (acks and pongs are not).
    - Hyperliquid ([/ws/hyperliquid]): [{"method": "subscribe", "subscription": {...}}] is
      answered with a [subscriptionResponse] echo, [{"method": "ping"}] with
      [{"channel": "pong"}]. [trades] is [Trades], [l2Book] [L2] (or [Bbo], where the
      recorder files [l2Book] frames when only [Bbo] was recorded), [activeAssetCtx]
      [Funding].
    - OKX v5 public ([/ws/okx]): [{"op": "subscribe", "args": [...]}] is answered with one
      [{"event": "subscribe", "arg": ...}] per argument, the text [ping] with [pong].
      [trades] is [Trades], [bbo-tbt] [Bbo], [books...] [L2], [funding-rate] and
      [mark-price] [Funding] (the recorded funding files also hold [index-tickers]).
      Pushes (frames with [arg] and [data] and no [event]) are passed on.
    - Bitget v2 public ([/ws/bitget]): the same [op]/[args] shape and [ping]/[pong] as
      OKX, acks without a connection id. [trade] is [Trades], [books1] [Bbo], [books],
      [books5] and [books15] [L2], [ticker] [Funding].
    - Deribit JSON-RPC ([/ws/deribit]): [public/subscribe] and [public/unsubscribe] are
      answered with the channel list, [public/set_heartbeat] with [ok], [public/test] with
      a version; other methods get a JSON-RPC error. [trades.<s>...] is [Trades],
      [quote.<s>] [Bbo], [book.<s>...] [L2], [ticker.<s>...] [Funding]. Only
      [subscription] notifications are passed on.
    - Kraken ([/ws/kraken], for both of its APIs): spot v2
      [{"method": "subscribe", "params": {"channel": ..., "symbol": [...]}}] is answered
      with one ack per symbol, [{"method": "ping"}] with a pong; [trade] is [Trades],
      [ticker] [Bbo], [book] [L2]. Futures v1
      [{"event": "subscribe", "feed": "ticker", "product_ids": [...]}] is answered with
      [subscribed]; [ticker] is [Funding]. Heartbeats, status frames, acks and pongs are
      not passed on.

    Other venues are refused. Symbols are returned as the recorder spells them in its
    directories (Binance and Bybit uppercase). *)

open! Core

module Series : sig
  type t =
    { stream : Market_data.Stream.t
    ; symbol : string
    }
  [@@deriving sexp, compare, equal]

  include Comparable.S with type t := t
end

module Action : sig
  type t =
    | Subscribe of
        { series : Series.t list
        (** recorded series to replay; may be empty for an unsupported stream *)
        ; replies : string list
        }
    | Unsubscribe of
        { series : Series.t list
        ; replies : string list
        }
    | Reply of string list (** pings and anything answered without replaying *)
    | Ignore
  [@@deriving sexp_of]
end

(** The venues served over websockets. *)
val supported : Market_data.Venue.t list

(** One client connection. Venues whose replies depend on what the connection did before
    (Coinbase numbers every frame of a connection) keep that state here. *)
module Session : sig
  type t

  (** [conn_id] names the connection where the venue echoes one (Bybit, OKX). *)
  val create : Market_data.Venue.t -> conn_id:string -> t

  (** Parses a client message. [now] is the replay position, for replies that carry a
      time. Malformed messages become an error reply in the venue's shape, or [Ignore]. *)
  val on_message : t -> now:Time_ns.t -> string -> Action.t

  (** The text to send for a reply or a recorded data frame on this connection. *)
  val outgoing : t -> string -> string
end

(** [on_message] of a fresh {!Session} at [Time_ns.epoch]. *)
val on_message : Market_data.Venue.t -> conn_id:string -> string -> Action.t

(** Whether a recorded frame of this venue is data to pass on, rather than an
    acknowledgement, pong or REST body the recorder kept in the same file. *)
val is_data : Market_data.Venue.t -> string -> bool
