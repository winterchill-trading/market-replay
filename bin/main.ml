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
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       let server =
         Market_replay.Server.create (Market_replay.Source.of_data_dir data_dir)
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
