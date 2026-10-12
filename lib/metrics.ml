open! Core
module Venue = Market_data.Venue

module Per_venue = struct
  type t =
    { mutable connections : int
    ; mutable clients : int
    ; mutable frames : int
    ; mutable replies : int
    ; mutable gaps : int
    }
end

type t =
  { mutable http_requests : int
  ; mutable http_lines : int
  ; venues : Per_venue.t Venue.Table.t
  }

let create () = { http_requests = 0; http_lines = 0; venues = Venue.Table.create () }
let http_request t = t.http_requests <- t.http_requests + 1
let http_lines t n = t.http_lines <- t.http_lines + n

let venue t v =
  Hashtbl.find_or_add t.venues v ~default:(fun () ->
    { Per_venue.connections = 0; clients = 0; frames = 0; replies = 0; gaps = 0 })
;;

let ws_connected t v =
  let p = venue t v in
  p.connections <- p.connections + 1;
  p.clients <- p.clients + 1
;;

let ws_disconnected t v =
  let p = venue t v in
  p.clients <- p.clients - 1
;;

let ws_frame t v =
  let p = venue t v in
  p.frames <- p.frames + 1
;;

let ws_reply t v =
  let p = venue t v in
  p.replies <- p.replies + 1
;;

let ws_gap t v =
  let p = venue t v in
  p.gaps <- p.gaps + 1
;;

let ws_clients t =
  Hashtbl.fold t.venues ~init:0 ~f:(fun ~key:_ ~data acc -> acc + data.clients)
;;

let render t =
  let b = Buffer.create 1024 in
  let metric name kind help =
    bprintf b "# HELP %s %s\n# TYPE %s %s\n" name help name kind
  in
  metric "market_replay_http_requests_total" "counter" "GET /replay requests accepted";
  bprintf b "market_replay_http_requests_total %d\n" t.http_requests;
  metric "market_replay_http_lines_total" "counter" "raw lines served over HTTP";
  bprintf b "market_replay_http_lines_total %d\n" t.http_lines;
  let venues =
    Hashtbl.to_alist t.venues
    |> List.sort ~compare:(fun (a, _) (b, _) -> Venue.compare a b)
  in
  let per_venue name kind help f =
    metric name kind help;
    List.iter venues ~f:(fun (v, p) ->
      bprintf b "%s{venue=\"%s\"} %d\n" name (Venue.to_string v) (f p))
  in
  per_venue
    "market_replay_ws_connections_total"
    "counter"
    "websocket sessions opened"
    (fun p -> p.connections);
  per_venue "market_replay_ws_clients" "gauge" "websocket sessions open" (fun p ->
    p.clients);
  per_venue
    "market_replay_ws_frames_total"
    "counter"
    "recorded frames sent over websockets"
    (fun p -> p.frames);
  per_venue
    "market_replay_ws_replies_total"
    "counter"
    "acknowledgements and pongs sent"
    (fun p -> p.replies);
  per_venue
    "market_replay_ws_gaps_skipped_total"
    "counter"
    "recorded disconnects skipped"
    (fun p -> p.gaps);
  Buffer.contents b
;;
