open! Core
module Md_stream = Market_data.Stream

type t =
  { venue : Market_data.Venue.t
  ; symbols : string list
  ; streams : Md_stream.t list
  ; start : Time_ns.Alternate_sexp.t
  ; stop : Time_ns.Alternate_sexp.t
  }
[@@deriving sexp_of]

let split values =
  List.concat_map values ~f:(String.split ~on:',')
  |> List.map ~f:String.strip
  |> List.filter ~f:(Fn.non String.is_empty)
;;

let parse_streams s =
  split [ s ]
  |> List.map ~f:(fun name ->
    match String.lowercase name with
    | "trade" -> Ok Md_stream.Trades
    | name ->
      (match Md_stream.of_string_opt name with
       | Some Private | None -> Or_error.error_s [%message "unknown stream" name]
       | Some stream -> Ok stream))
  |> Or_error.combine_errors
  |> Or_error.map ~f:(List.stable_dedup ~compare:Md_stream.compare)
;;

let of_uri uri =
  let one name =
    match Uri.get_query_param uri name with
    | Some v when not (String.is_empty v) -> Ok v
    | _ -> Or_error.error_s [%message "missing query parameter" name]
  in
  let open Or_error.Let_syntax in
  let%bind venue = one "venue" in
  let%bind venue =
    Market_data.Venue.of_string_opt venue
    |> Result.of_option ~error:(Error.create_s [%message "unknown venue" venue])
  in
  let%bind symbols =
    let values =
      List.concat_map (Uri.query uri) ~f:(fun (key, values) ->
        if String.equal key "symbol" then values else [])
    in
    match split values with
    | [] -> Or_error.error_s [%message "missing query parameter" "symbol"]
    | symbols -> Ok (List.stable_dedup symbols ~compare:String.compare)
  in
  let%bind streams =
    match Uri.get_query_param uri "streams" with
    | None | Some "" -> Ok [ Md_stream.Trades; Bbo; L2; Funding ]
    | Some s -> parse_streams s
  in
  let%bind start = one "from" >>= Raw_line.parse_time in
  let%bind stop = one "to" >>= Raw_line.parse_time in
  if Time_ns.( >= ) start stop
  then Or_error.error_s [%message "from must be before to"]
  else Ok { venue; symbols; streams; start; stop }
;;
