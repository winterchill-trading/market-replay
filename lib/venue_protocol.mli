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

(** The venues served over websockets: Binance, Bybit and Hyperliquid. *)
val supported : Market_data.Venue.t list

(** [conn_id] names the connection where the venue echoes one (Bybit). Malformed messages
    become an error reply in the venue's shape, or [Ignore]. *)
val on_message : Market_data.Venue.t -> conn_id:string -> string -> Action.t

(** Whether a recorded frame of this venue is data to pass on, rather than an
    acknowledgement, pong or REST body the recorder kept in the same file. *)
val is_data : Market_data.Venue.t -> string -> bool
