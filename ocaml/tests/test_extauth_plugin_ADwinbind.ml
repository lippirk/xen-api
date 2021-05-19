(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Test_highlevel

module ExtractOuConfig = Generic.MakeStateless (struct
  module Io = struct
    type input_t = (string * string) list

    type output_t = (string * string) list * string list

    let string_of_input_t = Test_printers.(assoc_list string string)

    let string_of_output_t =
      Test_printers.(pair (assoc_list string string) (list string))
  end

  let transform x = Extauth_plugin_ADwinbind.extract_ou_config x

  let tests =
    `QuickAndAutoDocumented
      [
        ([("auth-type", "AD"); ("service-name", "conappada.local")], ([], []))
      ; ( [
            ("auth-type", "AD")
          ; ("service-name", "conappada.local")
          ; ("ou", "TOU")
          ]
        , ([("ou", "TOU")], ["createcomputer=TOU"]) )
      ]
end)

let test_domainify_uname =
  let open Extauth_plugin_ADwinbind in
  let check uname exp () =
    let msg = Printf.sprintf "%s -> %s" uname exp in
    let ac = domainify_uname ~domain:"domain.net" uname in
    Alcotest.(check string) msg exp ac
  in
  let matrix =
    [
      ("KRBTGT", "KRBTGT")
    ; ({|user|}, {|user@domain.net|})
    ; ({|user@domain.net|}, {|user@domain.net|})
    ; ({|DOMAIN\user|}, {|DOMAIN\user|})
      (* if username already contains a domain, DO NOT try and correct it *)
    ; ({|user@unknowndomain.net|}, {|user@unknowndomain.net|})
    ; ({|UNKNOWNDOMAIN\user|}, {|UNKNOWNDOMAIN\user|})
    ]
  in
  matrix
  |> List.map @@ fun (inp, exp) ->
     ("test_domainify_uname", `Quick, check inp exp)

let tests =
  [
    ("ADwinbind:extract_ou_config", ExtractOuConfig.tests)
  ; ("ADwinbind", test_domainify_uname)
  ]
