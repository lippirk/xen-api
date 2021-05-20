(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
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
(**
 * @group Access Control
*)

module D = Debug.Make (struct let name = "xapi_auth" end)

module Unixext = Xapi_stdext_unix.Unixext
open Auth_signature
open Extauth

let call_with_exception_handler fn =
  try fn () with
  | Extauth.Extauth_is_disabled ->
      raise (Api_errors.Server_error (Api_errors.auth_is_disabled, []))
  | Extauth.Unknown_extauth_type msg ->
      raise (Api_errors.Server_error (Api_errors.auth_unknown_type, [msg]))
  | Not_found | Auth_signature.Subject_cannot_be_resolved ->
      raise
        (Api_errors.Server_error (Api_errors.subject_cannot_be_resolved, []))
  | Auth_signature.Auth_service_error (errtag, msg) ->
      raise (Api_errors.Server_error (Api_errors.auth_service_error, [msg]))
  | e ->
      raise
        (Api_errors.Server_error
           (Api_errors.auth_service_error, [ExnHelper.string_of_exn e]))

(* PRECONDITION: All of these additional calls require a valid session to be presented.*)
(* ==> the session validity is already checked in every server.ml call by using Session_check.check *)

let get_subject_identifier ~__context ~subject_name =
  call_with_exception_handler (fun () ->
      (Ext_auth.d ()).get_subject_identifier subject_name)

let get_group_membership ~__context ~subject_identifier =
  call_with_exception_handler (fun () ->
      (Ext_auth.d ()).query_group_membership subject_identifier)

let get_subject_information_from_identifier ~__context ~subject_identifier =
  call_with_exception_handler (fun () ->
      (Ext_auth.d ()).query_subject_information subject_identifier)

let sanity_check ~__context =
  let qsi name =
    try
      let res = (Ext_auth.d ()).get_subject_identifier name in
      D.debug "bena: get_subject_identifier SUCCESS %s: %s" name res
    with e ->
      D.error "bena: get_subject_identifier %s FAIL. ex: %s" name
        (Printexc.to_string e)
  in
  qsi "KRBTGT" ;
  qsi "ladmin" ;

  let qgm name =
    try
      let sid = (Ext_auth.d ()).get_subject_identifier name in
      let res = (Ext_auth.d ()).query_group_membership sid in
      let res_str = res |> String.concat "; " |> Printf.sprintf "[ %s ]" in
      D.debug "bena: query_group_membership SUCCESS %s: %s" name res_str
    with e ->
      D.error "bena: query_group_membership %s FAIL. ex: %s" name
        (Printexc.to_string e)
  in
  qgm "KRBTGT" ;
  qgm "ladmin" ;

  let auth uname password =
    try
      let res = (Ext_auth.d ()).authenticate_username_password uname password in
      D.debug "bena: auth SUCCESS uname=%s password=%s: %s" uname password res
    with e ->
      D.error "bena: auth uname=%s passwd=%s FAIL ex: %s" uname password
        (Printexc.to_string e)
  in
  (* auth "KRBTGT" "AAAAA" ; *)
  auth "ladmin" "12345678"

let sanity_check ~__context = Thread.delay 10. ; sanity_check ~__context
