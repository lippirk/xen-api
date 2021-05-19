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

(**
 * @winbind group Access Control
*)
module D = Debug.Make (struct
  let name = "extauth_plugin_ADwinbind"
end)

open D
open Xapi_stdext_std.Xstringext
open Auth_signature

let krbtgt = "KRBTGT"

let net_cmd = !Xapi_globs.net_cmd

let wb_cmd = !Xapi_globs.wb_cmd

let tdb_tool = !Xapi_globs.tdb_tool

let debug_level = !Xapi_globs.winbind_debug_level |> string_of_int

let call_wbinfo (args : string list) : (string, exn) result =
  try
    let stdout = Helpers.call_script ~log_output:Never wb_cmd args in
    Ok stdout
  with e -> Error e

module Winbind = struct
  let name = "winbind"

  let is_ad_enabled ~__context =
    ( Helpers.get_localhost ~__context |> fun self ->
      Db.Host.get_external_auth_type ~__context ~self )
    |> fun x -> x = Xapi_globs.auth_type_AD

  let start ~timeout ~wait_until_success =
    Xapi_systemctl.start ~timeout ~wait_until_success name

  let stop ~timeout ~wait_until_success =
    Xapi_systemctl.stop ~timeout ~wait_until_success name

  let init_service ~__context =
    if is_ad_enabled ~__context then
      start ~wait_until_success:false ~timeout:5.

  let resolve_KRBTGT () : bool =
    try
      Helpers.call_script ~log_output:Never wb_cmd ["-n"; krbtgt] |> ignore ;
      true
    with _ -> false

  let check_ready_to_serve ~timeout =
    (* we _need_ to use a username contained in our domain, otherwise the following tests won't work.
       Microsoft KB/Q243330 article provides the KRBTGT account as a well-known built-in SID in AD
       Microsoft KB/Q229909 article says that KRBTGT account cannot be renamed or enabled, making
       it the perfect target for such a test using a username (Administrator account can be renamed) *)
    try
      Helpers.retry_until_timeout ~timeout
        (Printf.sprintf "Checking %s ready to serve" name)
        resolve_KRBTGT
    with e ->
      let msg =
        Printf.sprintf
          "%s cannot serve after checking for %f seconds, error: %s" name
          timeout
          (ExnHelper.string_of_exn e)
      in
      error "Service not ready error: %s" msg ;
      raise (Auth_service_error (E_GENERIC, msg))
end

let get_service_name () =
  (fun __context ->
    Helpers.get_localhost ~__context |> fun host ->
    Db.Host.get_external_auth_service_name ~__context ~self:host)
  |> Server_helpers.exec_with_new_task "retrieving external auth service name"

let query_domain_workgroup domain =
  let key = "Pre-Win2k Domain" in
  let err_msg = Printf.sprintf "Failed to lookup domain %s workgroup" domain in
  try
    let lines =
      Helpers.call_script ~log_output:On_failure net_cmd
        ["ads"; "lookup"; "-S"; domain; "-d"; debug_level]
    in
    match Xapi_cmd_result.of_output_opt ~sep:':' ~key ~lines with
    | Some v ->
        v
    | None ->
        raise (Auth_service_error (E_LOOKUP, err_msg))
  with _ -> raise (Auth_service_error (E_LOOKUP, err_msg))

let config_winbind_damon ~domain ~workgroup =
  let open Xapi_stdext_unix in
  let smb_config = "/etc/samba/smb.conf" in
  let conf_contents =
    String.concat "\n"
      [
        "# autogenerated by xapi"
      ; "[global]"
      ; "kerberos method = secrets and keytab"
      ; Printf.sprintf "realm = %s" domain
      ; "security = ADS"
      ; "template shell = /bin/bash"
      ; "winbind offline logon = Yes"
      ; "winbind refresh tickets = Yes"
      ; "winbind enum groups = no"
      ; "winbind enum users = no"
      ; "kerberos encryption types = strong"
      ; Printf.sprintf "workgroup = %s" workgroup
      ; "idmap config * : range = 3000000-3999999"
      ; Printf.sprintf "idmap config %s: backend = rid" domain
      ; Printf.sprintf "idmap config %s: range = 2000000-2999999" domain
      ; Printf.sprintf "log level = %s" debug_level
      ; "idmap config * : backend = tdb"
      ; "" (* Empty line at the end *)
      ]
  in
  let len = String.length conf_contents in
  Unixext.atomic_write_to_file smb_config 0o0644 (fun fd ->
      let (_ : int) = Unix.single_write_substring fd conf_contents 0 len in
      ())

let from_config ~name ~err_msg ~config_params =
  match List.assoc_opt name config_params with
  | Some v ->
      v
  | _ ->
      raise (Auth_service_error (E_GENERIC, err_msg))

let all_number_re = Re.Perl.re {|^\d+$|} |> Re.Perl.compile

let assert_hostname_valid () =
  let hostname =
    (fun __context ->
      Helpers.get_localhost ~__context |> fun host ->
      Db.Host.get_hostname ~__context ~self:host)
    |> Server_helpers.exec_with_new_task "retrieving hostname"
  in
  let all_numbers = Re.matches all_number_re hostname <> [] in
  if all_numbers then
    raise
      (Auth_service_error
         ( E_GENERIC
         , Printf.sprintf "hostname '%s' cannot contain only digits." hostname
         ))

let assert_domain_equal_service_name ~service_name ~config_params =
  (* For legeacy support, if domain exist in config_params, it must be equal to service_name *)
  let domain_key = "domain" in
  match List.assoc_opt domain_key config_params with
  | Some domain when domain <> service_name ->
      raise
        (Auth_service_error
           (E_GENERIC, "if present, config:domain must match service-name."))
  | _ ->
      ()

let extract_ou_config ~config_params =
  try
    let ou = from_config ~name:"ou" ~err_msg:"" ~config_params in
    ([("ou", ou)], [Printf.sprintf "createcomputer=%s" ou])
  with Auth_service_error _ -> ([], [])

let persist_extauth_config ~domain ~user ~ou_conf =
  let value =
    match (domain, user) with
    | "", "" ->
        []
    | _ ->
        [("domain", domain); ("user", user)] @ ou_conf
  in
  (fun __context ->
    Helpers.get_localhost ~__context |> fun self ->
    Db.Host.set_external_auth_configuration ~__context ~self ~value ;
    Db.Host.get_name_label ~__context ~self
    |> debug "update external_auth_configuration for host %s")
  |> Server_helpers.exec_with_new_task "update external_auth_configuration"

let clean_machine_account ~service_name = function
  | Some u, Some p -> (
      (* Clean machine account in DC *)
      let env = [|Printf.sprintf "PASSWD=%s" p|] in
      let args = ["ads"; "leave"; "-U"; u; "-d"; debug_level] in
      try
        Helpers.call_script ~env net_cmd args |> ignore ;
        debug "Cleaning the machine account for domain %s succeeded"
          service_name
      with _ ->
        let msg =
          Printf.sprintf "Cleaning the machine account for domain %s failed"
            service_name
        in
        debug "%s" msg ;
        raise (Auth_service_error (E_GENERIC, msg))
    )
  | _ ->
      debug
        "username or password not provided, skip cleaning the machine account"

(* Clean local resources like machine password *)
let clean_local_resources () : unit =
  let folder = "/var/lib/samba/private" in
  let secrets_tdb = Filename.concat folder "secrets.tdb" in
  try
    (* Erase secrets database before clean the files *)
    Helpers.call_script tdb_tool [secrets_tdb; "erase"] |> ignore ;
    (* Clean local resource files *)
    Helpers.FileSys.rmrf ~rm_top:false folder
  with e ->
    let msg = "Failed to clean local samba resources" in
    error "%s : %s" msg (ExnHelper.string_of_exn e) ;
    raise (Auth_service_error (E_GENERIC, msg))

module AuthADWinbind : Auth_signature.AUTH_MODULE = struct
  (* subject_id get_subject_identifier(string subject_name)

      Takes a subject_name (as may be entered into the XenCenter UI when defining subjects --
      see Access Control wiki page); and resolves it to a subject_id against the external
      auth/directory service.
      Raises Not_found (*Subject_cannot_be_resolved*) if authentication is not succesful.
  *)
  let get_subject_identifier subject_name =
    (* example:
     *
     * $ wbinfo -n user@domain.net
       S-1-2-34-... SID_USER (1)
     * $ wbinfo -n DOMAIN\user
       # similar output *)
    let subject_name =
      domainify_uname ~domain:(get_service_name ()) subject_name
    in
    let args = ["-n"; subject_name] in
    match call_wbinfo args with
    | Error e ->
        let msg =
          Printf.sprintf "couldn't find SID for subject name '%s'" subject_name
        in
        raise
          (Auth_signature.Auth_service_error (Auth_signature.E_GENERIC, msg))
    | Ok stdout -> (
      match String.split_on_char ' ' stdout with
      | sid :: _ ->
          String.trim sid
      | _ ->
          (* we'd like to also log stdout for debugging purposes, but it may
           * contain sensitive info *)
          let msg =
            Printf.sprintf "unable to find SID in output of 'wbinfo %s'"
              (String.concat " " args)
          in
          raise
            (Auth_signature.Auth_service_error (Auth_signature.E_GENERIC, msg))
    )

  (* subject_id Authenticate_username_password(string username, string password)

      Takes a username and password, and tries to authenticate against an already configured
      auth service (see XenAPI requirements Wiki page for details of how auth service configuration
      takes place and the appropriate values are stored within the XenServer Metadata).
      If authentication is successful then a subject_id is returned representing the account
      corresponding to the supplied credentials (where the subject_id is in a namespace managed by
      the auth module/service itself -- e.g. maybe a SID or something in the AD case).
      Raises auth_failure if authentication is not successful
  *)

  let authenticate_username_password username password =
    "authenticate_ticket To be implemented in CP-35399"

  (* subject_id Authenticate_ticket(string ticket)

      As above but uses a ticket as credentials (i.e. for single sign-on)
  *)
  (* not implemented now, not needed for our tests, only for a *)
  (* future single sign-on feature *)
  let authenticate_ticket tgt =
    failwith "extauth_plugin authenticate_ticket not implemented"

  (* ((string*string) list) query_subject_information(string subject_identifier)

      Takes a subject_identifier and returns the user record from the directory service as
      key/value pairs. In the returned string*string map, there _must_ be a key called
      subject_name that refers to the name of the account (e.g. the user or group name as may
      be displayed in XenCenter). There is no other requirements to include fields from the user
      record -- initially qI'd imagine that we wouldn't bother adding anything else here, but
      it's a string*string list anyway for possible future expansion.
      Raises Not_found (*Subject_cannot_be_resolved*) if subject_id cannot be resolved by external auth service
  *)
  let query_subject_information subject_identifier =
    failwith "extauth_plugin authenticate_ticket not implemented"

  (* (string list) query_group_membership(string subject_identifier)

      Takes a subject_identifier and returns its group membership (i.e. a list of subject
      identifiers of the groups that the subject passed in belongs to). The set of groups returned
      _must_ be transitively closed wrt the is_member_of relation if the external directory service
      supports nested groups (as AD does for example)
  *)
  let query_group_membership subject_identifier =
    (* example:
     *
     * $ wbinfo --user-domgroups S-1-2-34-...
       S-1-2-34-...
       S-1-5-21-...
       ... *)
    let args = ["--user-domgroups"; subject_identifier] in
    match call_wbinfo args with
    | Error _ ->
        let msg =
          Printf.sprintf "group membership query failed. SID='%s'"
            subject_identifier
        in
        raise Auth_signature.(Auth_service_error (E_GENERIC, msg))
    | Ok stdout ->
        String.split_on_char '\n' stdout |> List.map String.trim

  (* unit on_enable(((string*string) list) config_params)

      Called internally by xapi _on each host_ when a client enables an external auth service for the
      pool via the XenAPI [see AD integration wiki page]. The config_params here are the ones passed
      by the client as part of the corresponding XenAPI call.
      On receiving this hook, the auth module should:
      (i) do whatever it needs to do (if anything) to register with the external auth/directory
          service [using the config params supplied to get access]
      (ii) Write the config_params that it needs to store persistently in the XenServer metadata
          into the Pool.external_auth_configuration field. [Note - the rationale for making the plugin
          write the config params it needs long-term into the XenServer metadata itself is so it can
          explicitly filter any one-time credentials [like AD username/password for example] that it
          does not need long-term.]
  *)
  let on_enable config_params =
    let user =
      from_config ~name:"user" ~err_msg:"enable requires username"
        ~config_params
    in
    let pass =
      from_config ~name:"pass" ~err_msg:"enable requires password"
        ~config_params
    in

    assert_hostname_valid () ;

    let service_name = get_service_name () in
    assert_domain_equal_service_name ~service_name ~config_params ;

    query_domain_workgroup service_name |> fun workgroup ->
    config_winbind_damon ~domain:service_name ~workgroup ;

    let ou_conf, ou_param = extract_ou_config ~config_params in

    let args =
      [
        "ads"
      ; "join"
      ; service_name
      ; "-U"
      ; user
      ; "-d"
      ; debug_level
      ; "--no-dns-updates"
      ]
      @ ou_param
    in
    debug "Joining domain %s with user %s" service_name user ;
    let env = [|Printf.sprintf "PASSWD=%s" pass|] in
    try
      Helpers.call_script ~env net_cmd args |> ignore ;
      Winbind.start ~timeout:5. ~wait_until_success:true ;
      Winbind.check_ready_to_serve ~timeout:300. ;
      persist_extauth_config ~domain:service_name ~user ~ou_conf ;
      debug "Joined domain %s successfully" service_name
    with
    | Forkhelpers.Spawn_internal_error _ ->
        let msg = Printf.sprintf "Failed to join domain %s" service_name in
        error "Join domain error: %s" msg ;
        raise (Auth_service_error (E_GENERIC, msg))
    | Xapi_systemctl.Systemctl_fail _ ->
        let msg = Printf.sprintf "Failed to start %s" Winbind.name in
        error "Start daemon error: %s" msg ;
        raise (Auth_service_error (E_GENERIC, msg))
    | e ->
        let msg =
          Printf.sprintf
            "Failed to enable extauth for domain %s with user %s, error: %s"
            service_name user
            (ExnHelper.string_of_exn e)
        in
        error "Enable extauth error: %s" msg ;
        raise (Auth_service_error (E_GENERIC, msg))

  (* unit on_disable()

      Called internally by xapi _on each host_ when a client disables an auth service via the XenAPI.
      The hook will be called _before_ the Pool configuration fields relating to the external-auth
      service are cleared (i.e. so you can access the config params you need from the pool metadata
      within the body of the on_disable method)
  *)
  let on_disable config_params =
    let user = List.assoc_opt "user" config_params in
    let pass = List.assoc_opt "pass" config_params in
    let service_name = get_service_name () in
    clean_machine_account ~service_name (user, pass) ;
    (* Clean local resources *)
    clean_local_resources () ;
    (* Clean extauth config *)
    persist_extauth_config ~domain:"" ~user:"" ~ou_conf:[]

  (* unit on_xapi_initialize(bool system_boot)

      Called internally by xapi whenever it starts up. The system_boot flag is true iff xapi is
      starting for the first time after a host boot
  *)
  let on_xapi_initialize system_boot =
    let ( let* ) = Result.bind in
    let max_retries = 12 in
    Server_helpers.exec_with_new_task "winbind: on_xapi_initialize"
    @@ fun __context ->
    let try_init (attempt_n : int) : (unit, unit) result =
      let* () =
        try
          Winbind.init_service ~__context ;
          Ok ()
        with _ ->
          D.warn "attempt=%i/%i. init_service failed" attempt_n max_retries ;
          Error ()
      in
      if Winbind.resolve_KRBTGT () then
        Ok ()
      else (
        D.warn "attempt=%i/%i. resolve_KRBTGT" attempt_n max_retries ;
        Error ()
      )
    in
    let rec retry = function
      | 0 ->
          let msg =
            Printf.sprintf "winbind is not available after %i tries" max_retries
          in
          raise
            (Auth_signature.Auth_service_error (Auth_signature.E_GENERIC, msg))
      | n -> (
        match try_init n with
        | Ok () ->
            D.debug "winbind daemon checks succeeded"
        | Error () ->
            (retry [@tailcall]) (n - 1)
      )
    in
    retry max_retries

  (* unit on_xapi_exit()

      Called internally when xapi is doing a clean exit.
  *)
  let on_xapi_exit () = debug "on_xapi_exit To be implemented in CP-36089"

  (* Implement the single value required for the module signature *)
  let methods =
    {
      Auth_signature.authenticate_username_password
    ; Auth_signature.authenticate_ticket
    ; Auth_signature.get_subject_identifier
    ; Auth_signature.query_subject_information
    ; Auth_signature.query_group_membership
    ; Auth_signature.on_enable
    ; Auth_signature.on_disable
    ; Auth_signature.on_xapi_initialize
    ; Auth_signature.on_xapi_exit
    }
end
