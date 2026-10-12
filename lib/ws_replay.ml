open! Core
open! Async
module Series = Venue_protocol.Series

module Config = struct
  type t =
    { start : Time_ns.Alternate_sexp.t
    ; stop : Time_ns.Alternate_sexp.t
    ; speed : float
    ; settle : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  let create ?stop ?(speed = 1.) ?(settle = Time_ns.Span.of_int_ms 200) ~start () =
    let stop = Option.value stop ~default:(Time_ns.add start Time_ns.Span.day) in
    if Float.(speed < 0. || not (is_finite speed))
    then raise_s [%message "Ws_replay: speed must be finite and >= 0" (speed : float)];
    if Time_ns.(stop <= start)
    then
      raise_s
        [%message
          "Ws_replay: stop must be after start"
            (start : Time_ns.Alternate_sexp.t)
            (stop : Time_ns.Alternate_sexp.t)];
    { start; stop; speed; settle }
  ;;
end

module Stats = struct
  type t =
    { frames_sent : int
    ; replies_sent : int
    ; gaps_skipped : int
    }
  [@@deriving sexp_of]
end

module Reader = struct
  type t =
    { pipe : Source.Item.t Pipe.Reader.t
    ; mutable head : Source.Item.t option
    ; mutable eof : bool
    }
end

type t =
  { config : Config.t
  ; source : Source.t
  ; venue : Market_data.Venue.t
  ; session : Venue_protocol.Session.t
  ; send : string -> unit Deferred.t
  ; time_source : Time_source.t
  ; on_frame : Source.Item.t -> unit
  ; metrics : Metrics.t option
  ; mutable subscribed : Series.Set.t
  ; mutable readers : Reader.t list
  ; mutable started_at : Time_ns.t option (** wall time the replay started *)
  ; mutable last_sent : Time_ns.t (** recv_ts of the last item replayed *)
  ; mutable closed : bool
  ; mutable changed : unit Ivar.t
  (** filled and replaced when the readers change or the session closes *)
  ; mutable start_scheduled : bool
  ; finished : unit Ivar.t
  ; mutable frames_sent : int
  ; mutable replies_sent : int
  ; mutable gaps_skipped : int
  }

let stats t =
  { Stats.frames_sent = t.frames_sent
  ; replies_sent = t.replies_sent
  ; gaps_skipped = t.gaps_skipped
  }
;;

let finished t = Ivar.read t.finished

(* The replay position in recorded time. *)
let position t =
  match t.started_at with
  | None -> t.config.start
  | Some wall0 when Float.(t.config.speed > 0.) ->
    let elapsed = Time_ns.diff (Time_source.now t.time_source) wall0 in
    Time_ns.max
      t.last_sent
      (Time_ns.add t.config.start (Time_ns.Span.scale elapsed t.config.speed))
  | Some _ -> t.last_sent
;;

(* When an item recorded at [recv_ts] is due, or [None] if it is due now. *)
let due t recv_ts =
  match t.started_at with
  | Some wall0 when Float.(t.config.speed > 0.) ->
    let offset = Time_ns.diff recv_ts t.config.start in
    let at = Time_ns.add wall0 (Time_ns.Span.scale offset (1. /. t.config.speed)) in
    if Time_ns.( > ) at (Time_source.now t.time_source) then Some at else None
  | _ -> None
;;

let signal_change t =
  let changed = t.changed in
  t.changed <- Ivar.create ();
  Ivar.fill_if_empty changed ()
;;

let close t =
  if not t.closed
  then (
    t.closed <- true;
    List.iter t.readers ~f:(fun r -> Pipe.close_read r.pipe);
    t.readers <- [];
    signal_change t;
    Ivar.fill_if_empty t.finished ())
;;

let fill_heads t =
  Deferred.List.iter t.readers ~how:`Parallel ~f:(fun (r : Reader.t) ->
    if Option.is_some r.head || r.eof
    then return ()
    else (
      match%map Pipe.read r.pipe with
      | `Eof -> r.eof <- true
      | `Ok item -> r.head <- Some item))
;;

let earliest t =
  List.fold t.readers ~init:None ~f:(fun best (r : Reader.t) ->
    match r.head, best with
    | None, _ -> best
    | Some item, None -> Some (r, item)
    | Some item, Some (_, best_item) ->
      if Time_ns.( < ) (Source.Item.recv_ts item) (Source.Item.recv_ts best_item)
      then Some (r, item)
      else best)
;;

let emit t (item : Source.Item.t) =
  t.last_sent <- Time_ns.max t.last_sent (Source.Item.recv_ts item);
  t.on_frame item;
  match item with
  | Gap _ ->
    t.gaps_skipped <- t.gaps_skipped + 1;
    Option.iter t.metrics ~f:(fun m -> Metrics.ws_gap m t.venue);
    return ()
  | Frame { stream; symbol; frame; _ } ->
    if Set.mem t.subscribed { Series.stream; symbol }
       && Venue_protocol.is_data t.venue frame
    then (
      t.frames_sent <- t.frames_sent + 1;
      Option.iter t.metrics ~f:(fun m -> Metrics.ws_frame m t.venue);
      t.send (Venue_protocol.Session.outgoing t.session frame))
    else return ()
;;

let rec loop t =
  if t.closed
  then return ()
  else (
    let%bind () = fill_heads t in
    t.readers <- List.filter t.readers ~f:(fun r -> not r.eof);
    if t.closed
    then return ()
    else (
      match earliest t with
      | None ->
        (* Everything subscribed so far has been replayed. *)
        Ivar.fill_if_empty t.finished ();
        let%bind () = Ivar.read t.changed in
        loop t
      | Some (reader, item) ->
        (match due t (Source.Item.recv_ts item) with
         | None ->
           reader.head <- None;
           let%bind () = emit t item in
           loop t
         | Some at ->
           (* A subscription made while waiting can bring an earlier frame. *)
           let%bind () =
             Deferred.any [ Time_source.at t.time_source at; Ivar.read t.changed ]
           in
           loop t)))
;;

let add_series t series =
  let fresh =
    List.dedup_and_sort series ~compare:Series.compare
    |> List.filter ~f:(fun s -> not (Set.mem t.subscribed s))
  in
  t.subscribed <- List.fold fresh ~init:t.subscribed ~f:Set.add;
  let start = position t in
  let by_symbol =
    List.Assoc.sort_and_group
      (List.map fresh ~f:(fun { Series.stream; symbol } -> symbol, stream))
      ~compare:String.compare
  in
  let readers =
    List.map by_symbol ~f:(fun (symbol, streams) ->
      { Reader.pipe =
          Source.read
            t.source
            ~venue:t.venue
            ~symbols:[ symbol ]
            ~streams
            ~start
            ~stop:t.config.stop
      ; head = None
      ; eof = false
      })
  in
  if not (List.is_empty readers)
  then (
    t.readers <- t.readers @ readers;
    signal_change t)
;;

let start_replay t =
  if not t.closed
  then (
    t.started_at <- Some (Time_source.now t.time_source);
    don't_wait_for (loop t))
;;

let create
  ?metrics
  ?(time_source = Time_source.wall_clock ())
  ?(on_frame = ignore)
  (config : Config.t)
  source
  ~venue
  ~conn_id
  ~send
  =
  { config
  ; source
  ; venue
  ; session = Venue_protocol.Session.create venue ~conn_id
  ; send
  ; time_source = Time_source.read_only time_source
  ; on_frame
  ; metrics
  ; subscribed = Series.Set.empty
  ; readers = []
  ; started_at = None
  ; last_sent = config.start
  ; closed = false
  ; changed = Ivar.create ()
  ; start_scheduled = false
  ; finished = Ivar.create ()
  ; frames_sent = 0
  ; replies_sent = 0
  ; gaps_skipped = 0
  }
;;

let reply t replies =
  Deferred.List.iter replies ~how:`Sequential ~f:(fun r ->
    t.replies_sent <- t.replies_sent + 1;
    Option.iter t.metrics ~f:(fun m -> Metrics.ws_reply m t.venue);
    t.send (Venue_protocol.Session.outgoing t.session r))
;;

let on_message t message =
  if t.closed
  then return ()
  else (
    match Venue_protocol.Session.on_message t.session ~now:(position t) message with
    | Ignore -> return ()
    | Reply replies -> reply t replies
    | Unsubscribe { series; replies } ->
      t.subscribed <- List.fold series ~init:t.subscribed ~f:Set.remove;
      reply t replies
    | Subscribe { series; replies } ->
      let%map () = reply t replies in
      add_series t series;
      if not t.start_scheduled
      then (
        t.start_scheduled <- true;
        don't_wait_for
          (let%map () = Time_source.after t.time_source t.config.settle in
           start_replay t)))
;;
