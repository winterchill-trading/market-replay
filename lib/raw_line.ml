open! Core

let format_ts time =
  let date, ofday = Time_ns.to_date_ofday time ~zone:Time_float.Zone.utc in
  let (p : Time_ns.Span.Parts.t) =
    Time_ns.Span.to_parts (Time_ns.Ofday.to_span_since_start_of_day ofday)
  in
  sprintf "%sT%02d:%02d:%02d.%03d%03dZ" (Date.to_string date) p.hr p.min p.sec p.ms p.us
;;

let parse_time s =
  match Date.of_string s with
  | date when String.length s = 10 ->
    Ok (Time_ns.of_date_ofday ~zone:Time_float.Zone.utc date Time_ns.Ofday.start_of_day)
  | _ | (exception _) ->
    (match Time_ns.of_string_with_utc_offset s with
     | time -> Ok time
     | exception _ -> Or_error.error_s [%message "not an ISO 8601 UTC time" s])
;;

let one_line frame =
  if String.mem frame '\n' || String.mem frame '\r'
  then
    String.map frame ~f:(function
      | '\n' | '\r' -> ' '
      | c -> c)
  else frame
;;

let frame ~recv_ts frame = String.concat [ format_ts recv_ts; " "; one_line frame; "\n" ]
let disconnect = "\n"
