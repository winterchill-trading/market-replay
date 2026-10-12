open! Core
open Market_replay

let%expect_test "format and parse round trip at microsecond precision" =
  let t = Raw_line.parse_time "2026-10-12T09:15:02.123456Z" |> ok_exn in
  print_endline (Raw_line.format_ts t);
  print_string (Raw_line.frame ~recv_ts:t "{\"a\":\n1}");
  [%expect
    {|
    2026-10-12T09:15:02.123456Z
    2026-10-12T09:15:02.123456Z {"a": 1}
    |}]
;;

let%expect_test "parse_time accepts dates, offsets and rejects junk" =
  List.iter
    [ "2026-10-12"; "2026-10-12T09:15:00Z"; "2026-10-12T11:15:00+02:00"; "yesterday" ]
    ~f:(fun s ->
      match Raw_line.parse_time s with
      | Ok t -> print_endline (Raw_line.format_ts t)
      | Error e -> print_s [%sexp (e : Error.t)]);
  [%expect
    {|
    2026-10-12T00:00:00.000000Z
    2026-10-12T09:15:00.000000Z
    2026-10-12T09:15:00.000000Z
    ("not an ISO 8601 UTC time" yesterday)
    |}]
;;

let%expect_test "format_ts agrees with Raw_minute's parser" =
  Quickcheck.test (Int.gen_incl 0 4_000_000_000_000_000) ~f:(fun us ->
    let t = Time_ns.of_int_ns_since_epoch (us * 1000) in
    let line = String.rstrip (Raw_line.frame ~recv_ts:t "x") in
    match Market_data.Raw_minute.Line.parse line with
    | Ok (Frame { recv_ts; payload }) ->
      [%test_result: Time_ns.Alternate_sexp.t] recv_ts ~expect:t;
      [%test_result: string] payload ~expect:"x"
    | _ -> failwith line);
  [%expect {| |}]
;;
