open! Core
open! Async

type t =
  { source : Source.t
  ; ws : Ws_replay.Config.t option
  ; time_source : Time_source.t
  ; mutable next_conn_id : int
  ; metrics : Metrics.t
  ; binance_depth : string String.Table.t
  (** the last recorded [GET /fapi/v1/depth] body replayed, per symbol *)
  ; binance_depth_served_at : Time_ns.t String.Table.t
  (** when [GET /fapi/v1/depth] last served a body, per symbol *)
  }

let create ?ws ?(time_source = Time_source.wall_clock ()) source =
  { source
  ; ws
  ; time_source = Time_source.read_only time_source
  ; next_conn_id = 0
  ; metrics = Metrics.create ()
  ; binance_depth = String.Table.create ()
  ; binance_depth_served_at = String.Table.create ()
  }
;;

let binance_depth_body ~(venue : Market_data.Venue.t) (item : Source.Item.t) =
  match venue, item with
  | Binance, Frame { stream = L2; symbol; frame; _ }
    when String.is_prefix frame ~prefix:{|{"lastUpdateId"|} -> Some (symbol, frame)
  | _ -> None
;;

let on_frame t ~venue item =
  Option.iter (binance_depth_body ~venue item) ~f:(fun (symbol, frame) ->
    Hashtbl.set t.binance_depth ~key:symbol ~data:frame)
;;

(* The number after [key] in a Binance frame. *)
let int_after frame ~key =
  Option.bind (String.substr_index frame ~pattern:key) ~f:(fun i ->
    let start = i + String.length key in
    let stop =
      String.lfindi frame ~pos:start ~f:(fun _ c -> not (Char.is_digit c))
      |> Option.value ~default:(String.length frame)
    in
    Option.try_with (fun () ->
      Int.of_string (String.sub frame ~pos:start ~len:(stop - start))))
;;

(* A speed 0 replay held for a depth snapshot goes on once the snapshot has been served
   and no client asked again for [depth_quiet] (binance-client asks again 200 ms after a
   snapshot that does not join its buffered diffs), or after [depth_hold_timeout]. *)
let depth_quiet = Time_ns.Span.of_int_ms 300
let depth_hold_timeout = Time_ns.Span.of_int_sec 3
let depth_poll = Time_ns.Span.of_int_ms 20

(* At speed 0 a whole recording replays before binance-client gets its depth snapshot (it
   asks on the first diff and retries after 200 ms or, on a [503], a second), so its book
   syncs once, at the end. After a recorded snapshot, the replay stops at the first diff
   that reaches the snapshot's [lastUpdateId] (the one the book joins at) until the client
   has fetched the snapshot: the diffs before it are buffered by the client, the ones
   after it arrive as deltas. *)
let binance_hold t =
  let pending = String.Table.create () in
  fun (item : Source.Item.t) ->
    match item with
    | Frame { stream = L2; symbol; frame; _ } ->
      if String.is_prefix frame ~prefix:{|{"lastUpdateId"|}
      then (
        Option.iter (int_after frame ~key:{|"lastUpdateId":|}) ~f:(fun id ->
          Hashtbl.set pending ~key:symbol ~data:id);
        return ())
      else (
        match Hashtbl.find pending symbol, int_after frame ~key:{|,"u":|} with
        | Some last_update_id, Some u when u >= last_update_id ->
          Hashtbl.remove pending symbol;
          let held_at = Time_source.now t.time_source in
          let rec wait () =
            let now = Time_source.now t.time_source in
            let served_and_quiet =
              match Hashtbl.find t.binance_depth_served_at symbol with
              | Some at ->
                Time_ns.(at >= held_at)
                && Time_ns.Span.(Time_ns.diff now at >= depth_quiet)
              | None -> false
            in
            if served_and_quiet
               || Time_ns.Span.(Time_ns.diff now held_at >= depth_hold_timeout)
            then return ()
            else (
              let%bind () = Time_source.after t.time_source depth_poll in
              wait ())
          in
          wait ()
        | _ -> return ())
    | Frame _ | Gap _ -> return ()
;;

let binance_depth t uri =
  let json = Cohttp.Header.of_list [ "content-type", "application/json" ] in
  let respond ~status body =
    let%map response = Cohttp_async.Server.respond_string ~headers:json ~status body in
    `Response response
  in
  match Uri.get_query_param uri "symbol" with
  | None -> respond ~status:`Bad_request {|{"code":-1102,"msg":"symbol is required"}|}
  | Some symbol ->
    let symbol = String.uppercase symbol in
    (match Hashtbl.find t.binance_depth symbol with
     | Some body ->
       Hashtbl.set
         t.binance_depth_served_at
         ~key:symbol
         ~data:(Time_source.now t.time_source);
       respond ~status:`OK body
     | None ->
       respond
         ~status:`Service_unavailable
         {|{"code":-1,"msg":"no depth snapshot replayed yet"}|})
;;

let text = Cohttp.Header.of_list [ "content-type", "text/plain; charset=utf-8" ]

let respond_text ~status body =
  let%map response = Cohttp_async.Server.respond_string ~headers:text ~status body in
  `Response response
;;

let line = function
  | Source.Item.Frame { recv_ts; frame; _ } -> Raw_line.frame ~recv_ts frame
  | Gap _ -> Raw_line.disconnect
;;

let replay_http t uri =
  match Replay_request.of_uri uri with
  | Error error -> respond_text ~status:`Bad_request (Error.to_string_hum error ^ "\n")
  | Ok { venue; symbols; streams; start; stop } ->
    Metrics.http_request t.metrics;
    let items = Source.read t.source ~venue ~symbols ~streams ~start ~stop in
    (* One chunk per batch of lines, not per line. *)
    let body =
      Pipe.map' items ~max_queue_length:1024 ~f:(fun batch ->
        Metrics.http_lines t.metrics (Queue.length batch);
        return (Queue.singleton (String.concat (List.map (Queue.to_list batch) ~f:line))))
    in
    let%map response =
      Cohttp_async.Server.respond
        ~headers:(Cohttp.Header.of_list [ "content-type", "application/x-ndjson" ])
        ~body:(Cohttp_async.Body.of_pipe body)
        `OK
    in
    `Response response
;;

(* The session config: the server's, with [from], [to] and [speed] from the query. *)
let ws_config t uri =
  let open Or_error.Let_syntax in
  let param name ~f =
    match Uri.get_query_param uri name with
    | None | Some "" -> Ok None
    | Some v -> f v >>| Option.some
  in
  let%bind start = param "from" ~f:Raw_line.parse_time in
  let%bind stop = param "to" ~f:Raw_line.parse_time in
  let%bind speed =
    param "speed" ~f:(fun v -> Or_error.try_with (fun () -> Float.of_string v))
  in
  match start, t.ws with
  | None, None ->
    Or_error.error_s
      [%message "no replay start: pass ?from= or start the server with -from"]
  | Some start, _ ->
    let settle = Option.map t.ws ~f:(fun (c : Ws_replay.Config.t) -> c.settle) in
    let speed =
      Option.first_some
        speed
        (Option.map t.ws ~f:(fun (c : Ws_replay.Config.t) -> c.speed))
    in
    Or_error.try_with (fun () -> Ws_replay.Config.create ?stop ?speed ?settle ~start ())
  | None, Some config ->
    Or_error.try_with (fun () ->
      Ws_replay.Config.create
        ~stop:(Option.value stop ~default:config.stop)
        ~speed:(Option.value speed ~default:config.speed)
        ~settle:config.settle
        ~start:config.start
        ())
;;

let handle_ws t ~venue ~config reader writer =
  let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
  let incoming, outgoing = Websocket.pipes ws in
  let conn_id = sprintf "replay-%d" t.next_conn_id in
  t.next_conn_id <- t.next_conn_id + 1;
  Metrics.ws_connected t.metrics venue;
  let session =
    Ws_replay.create
      ~metrics:t.metrics
      ~time_source:t.time_source
      config
      t.source
      ~venue
      ~conn_id
      ~on_frame:(on_frame t ~venue)
      ?hold:
        (match venue with
         | Binance when Float.(config.Ws_replay.Config.speed = 0.) ->
           Some (binance_hold t)
         | _ -> None)
      ~send:(fun frame -> Pipe.write_if_open outgoing frame)
  in
  let%map () =
    Pipe.iter incoming ~f:(fun message -> Ws_replay.on_message session message)
  in
  Ws_replay.close session;
  Metrics.ws_disconnected t.metrics venue;
  Pipe.close outgoing
;;

let header_is req name value =
  match Cohttp.Header.get (Cohttp.Request.headers req) name with
  | Some v ->
    String.split v ~on:','
    |> List.exists ~f:(fun v -> String.Caseless.equal (String.strip v) value)
  | None -> false
;;

let ws_upgrade t req ~venue =
  let uri = Cohttp.Request.uri req in
  match
    ( Market_data.Venue.of_string_opt venue
    , Cohttp.Header.get (Cohttp.Request.headers req) "sec-websocket-key" )
  with
  | None, _ -> respond_text ~status:`Not_found (sprintf "unknown venue %s\n" venue)
  | Some venue, _
    when not (List.mem Venue_protocol.supported venue ~equal:Market_data.Venue.equal) ->
    respond_text
      ~status:`Not_found
      (sprintf "no websocket replay for %s\n" (Market_data.Venue.to_string venue))
  | Some _, None -> respond_text ~status:`Bad_request "missing Sec-WebSocket-Key\n"
  | Some venue, Some key ->
    (match ws_config t uri with
     | Error error -> respond_text ~status:`Bad_request (Error.to_string_hum error ^ "\n")
     | Ok config ->
       let headers =
         Cohttp.Header.of_list
           [ "upgrade", "websocket"
           ; "connection", "Upgrade"
           ; ( "sec-websocket-accept"
             , Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key )
           ]
       in
       (* [Http.Response.make], unlike [Cohttp.Response.make], does not add
          [transfer-encoding: chunked], which is invalid on a 101. *)
       let response = Http.Response.make ~status:`Switching_protocols ~headers () in
       return
         (`Expert
           (response, fun reader writer -> handle_ws t ~venue ~config reader writer)))
;;

let handler t ~body:_ _addr req =
  let uri = Cohttp.Request.uri req in
  match Cohttp.Request.meth req, String.split (Uri.path uri) ~on:'/' with
  | `GET, [ ""; "healthz" ] -> respond_text ~status:`OK "ok\n"
  | `GET, [ ""; "metrics" ] ->
    let%map response =
      Cohttp_async.Server.respond_string
        ~headers:
          (Cohttp.Header.of_list
             [ "content-type", "text/plain; version=0.0.4; charset=utf-8" ])
        (Metrics.render t.metrics)
    in
    `Response response
  | `GET, [ ""; "replay" ] -> replay_http t uri
  | `GET, [ ""; "fapi"; "v1"; "depth" ] -> binance_depth t uri
  | `GET, "" :: "ws" :: venue :: _ when header_is req "upgrade" "websocket" ->
    ws_upgrade t req ~venue
  | _, _ -> respond_text ~status:`Not_found (sprintf "no route for %s\n" (Uri.path uri))
;;

let metrics t = t.metrics

let start t ~port =
  Cohttp_async.Server.create_expert
    ~on_handler_error:
      (`Call (fun _ exn -> Log.Global.error_s [%message "handler error" (exn : exn)]))
    (Tcp.Where_to_listen.of_port port)
    (handler t)
;;
