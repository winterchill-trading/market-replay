open! Core
open! Async

type t = { source : Source.t }

let create source = { source }
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
    let items = Source.read t.source ~venue ~symbols ~streams ~start ~stop in
    (* One chunk per batch of lines, not per line. *)
    let body =
      Pipe.map' items ~max_queue_length:1024 ~f:(fun batch ->
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

let handler t ~body:_ _addr req =
  let uri = Cohttp.Request.uri req in
  match Cohttp.Request.meth req, Uri.path uri with
  | `GET, "/replay" -> replay_http t uri
  | _, path -> respond_text ~status:`Not_found (sprintf "no route for %s\n" path)
;;

let start t ~port =
  Cohttp_async.Server.create_expert
    ~on_handler_error:
      (`Call (fun _ exn -> Log.Global.error_s [%message "handler error" (exn : exn)]))
    (Tcp.Where_to_listen.of_port port)
    (handler t)
;;
