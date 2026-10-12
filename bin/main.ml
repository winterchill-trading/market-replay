open! Core
open! Async

let command =
  Command.async
    ~summary:"Replay recorded raw market data over HTTP and websockets"
    (let%map_open.Command port =
       flag
         "-port"
         (optional_with_default 8800 int)
         ~doc:"PORT listen port (default 8800)"
     and data_dir =
       flag "-data-dir" (required string) ~doc:"DIR the recorder's data directory"
     and from =
       flag
         "-from"
         (optional string)
         ~doc:"TIME websocket replays start here (ISO 8601 UTC or a date)"
     and to_ =
       flag
         "-to"
         (optional string)
         ~doc:"TIME websocket replays stop here (default +1 day)"
     and speed =
       flag
         "-speed"
         (optional_with_default 1. float)
         ~doc:"X websocket replay speed: 1 real time, 0 as fast as possible (default 1)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       let time s = Market_replay.Raw_line.parse_time s |> ok_exn in
       let ws =
         Option.map from ~f:(fun from ->
           Market_replay.Ws_replay.Config.create
             ?stop:(Option.map to_ ~f:time)
             ~speed
             ~start:(time from)
             ())
       in
       let server =
         Market_replay.Server.create ?ws (Market_replay.Source.of_data_dir data_dir)
       in
       let%bind http = Market_replay.Server.start server ~port in
       Log.Global.info
         "market-replay: listening on %d, data in %s"
         (Cohttp_async.Server.listening_on http)
         data_dir;
       Deferred.never ())
    ~behave_nicely_in_pipeline:false
;;

let () = Command_unix.run command
