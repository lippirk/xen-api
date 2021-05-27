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

let ( let* ) = Result.bind

let ( <!> ) x f = Rresult.R.reword_error f x

let maybe_raise (x : ('a, exn) result) : 'a =
  match x with Ok x -> x | Error e -> raise e

let generic_ex fmt =
  Printf.kprintf
    (fun msg -> Auth_signature.(Auth_service_error (E_GENERIC, msg)))
    fmt

let net_cmd = !Xapi_globs.net_cmd

let wb_cmd = !Xapi_globs.wb_cmd

let tdb_tool = !Xapi_globs.tdb_tool

let debug_level = !Xapi_globs.winbind_debug_level |> string_of_int

let ntlm_auth uname passwd : (unit, exn) result =
  try
    let args = ["--username"; uname] in
    let _stdout =
      Helpers.call_script ~log_output:Never ~stdin:passwd
        !Xapi_globs.ntlm_auth_cmd args
    in
    Ok ()
  with e -> Error e

let call_ldap (query : string) : (string, exn) result =
  try
    let args = ["ads"; "search"; "--machine-pass"; query] in
    let stdout =
      Helpers.call_script ~log_output:On_failure !Xapi_globs.net_cmd args
    in
    Ok stdout
  with e -> Error e

let call_wbinfo (args : string list) : (string, exn) result =
  try
    (* we trust wbinfo will not print any sensitive info on failure *)
    let stdout = Helpers.call_script ~log_output:On_failure wb_cmd args in
    Ok stdout
  with e -> Error e

module Ldap = struct
  type user = {
      upn: string
    ; account_disabled: bool
    ; account_expired: bool
    ; account_locked: bool
    ; password_expired: bool
  }
  [@@deriving rpcty]

  let string_of_user x =
    Rpcmarshal.marshal user.Rpc.Types.ty x |> Jsonrpc.to_string

  let parse_user stdout : (user, string) result =
    let module Map = Map.Make (String) in
    let module P = struct
      open Angstrom

      let is_space = function ' ' -> true | _ -> false

      let s = take_while is_space

      let ns = take_while @@ fun x -> not (is_space x)

      let is_whitespace = function
        | ' ' | '\n' | '\t' | '\r' ->
            true
        | _ ->
            false

      let ws = skip_while is_whitespace

      (* example inputs: "key: value\n" or "key: value with spaces\r\n" *)
      let kvp =
        let* key = s *> take_while (fun x -> x <> ':') <* char ':' in
        let* value =
          s *> take_while (function '\n' | '\r' -> false | _ -> true)
          <* (end_of_line <|> end_of_input)
        in
        return (key, value)

      let header =
        let* num_replies =
          choice ~failure_msg:"unexpected header"
            [string "Got" *> char ' ' *> ns <* char ' ' <* string "replies"]
        in
        match num_replies with
        | "1" ->
            return ()
        | _ ->
            Printf.sprintf "got %s replies" num_replies |> fail

      let p =
        let* () = ws *> header <* ws in
        let* l = ws *> many kvp <* ws <* end_of_input in
        return (l |> List.to_seq |> Map.of_seq)

      let parse (x : string) : (string Map.t, string) result =
        parse_string ~consume:All p x
    end in
    let ldap fmt = fmt |> Printf.kprintf @@ Printf.sprintf "ldap %s" in
    let* kvps = P.parse stdout <!> ldap "parsing failed '%s'" in
    let get_string k =
      match Map.find_opt k kvps with
      | None ->
          Error (ldap "missing key '%s'" k)
      | Some x ->
          Ok x
    in
    let get_int of_string k =
      let* str = get_string k in
      try Ok (of_string str)
      with _ -> Error (ldap "invalid value for key '%s'" k)
    in
    let* upn = get_string "userPrincipalName" in
    let* user_account_control = get_int Int32.of_string "userAccountControl" in
    let* account_expires = get_int Int64.of_string "accountExpires" in
    let account_expired =
      (* see https://docs.microsoft.com/en-us/windows/win32/adschema/a-accountexpires *)
      let windows_nt_time_to_unix_time x =
        Int64.sub (Int64.div x 10000000L) 11644473600L
      in
      match account_expires with
      | 0L | 9223372036854775807L ->
          false
      | i ->
          let expire_unix_time =
            windows_nt_time_to_unix_time i |> Int64.to_float
          in
          expire_unix_time < Unix.time ()
    in
    Ok
      {
        upn
      ; account_expired
        (* see https://docs.microsoft.com/en-us/windows/win32/adschema/a-useraccountcontrol
         * for bit flag docs *)
      ; account_disabled= Int32.logand user_account_control 2l <> 0l
      ; account_locked= Int32.logand user_account_control 16l <> 0l
      ; password_expired= Int32.logand user_account_control 8388608l <> 0l
      }

  let query_user sid =
    let query = Printf.sprintf "(&(objectClass=user)(objectSid=%s))" sid in
    let* stdout =
      call_ldap query <!> fun _ -> generic_ex "ldap query failed: '%s'" query
    in
    parse_user stdout <!> generic_ex "%s"
end

module Wbinfo = struct
  let can_resolve_krbtgt () =
    match call_wbinfo ["-n"; krbtgt] with Ok _ -> true | Error _ -> false

  let sid_of_name name =
    (* example:
     *
     * $ wbinfo -n user@domain.net
       S-1-2-34-... SID_USER (1)
     * $ wbinfo -n DOMAIN\user
       # similar output *)
    let args = ["-n"; name] in
    let* stdout =
      call_wbinfo args <!> fun _ ->
      generic_ex "'wbinfo %s' failed" (String.concat " " args)
    in
    match String.split_on_char ' ' stdout with
    | sid :: _ ->
        Ok (String.trim sid)
    | [] ->
        Error
          (generic_ex "unable to find SID in output of 'wbinfo %s'"
             (String.concat " " args))

  let name_of_sid sid =
    (* example:
     * $ wbinfo -s S-1-5-21-3143668282-2591278241-912959342-502
       CONNAPP\krbtgt 1 *)
    let args = ["-s"; sid] in
    let* stdout =
      call_wbinfo args <!> fun _ ->
      generic_ex "'wbinfo %s' failed" (String.concat " " args)
    in
    (* we need to drop everything after the last space *)
    match List.rev (String.split_on_char ' ' stdout) with
    | [] ->
        Error (generic_ex "parsing 'wbinfo %s' failed" (String.concat " " args))
    | _ :: xs ->
        Ok (List.rev xs |> String.concat " " |> String.trim)

  let gid_of_sid sid =
    let args = ["-Y"; sid] in
    let* stdout =
      call_wbinfo args <!> fun _ ->
      generic_ex "'wbinfo %s' failed" (String.concat " " args)
    in
    try Ok (String.trim stdout |> int_of_string)
    with _ ->
      Error (generic_ex "parsing 'wbinfo %s' failed" (String.concat " " args))

  let user_domgroups sid =
    (* example:
     *
     * $ wbinfo --user-domgroups S-1-2-34-...
       S-1-2-34-...
       S-1-5-21-...
       ... *)
    let args = ["--user-domgroups"; sid] in
    let* stdout =
      call_wbinfo args <!> fun _ ->
      generic_ex "'wbinfo %s' failed" (String.concat " " args)
    in
    Ok (String.split_on_char '\n' stdout |> List.map String.trim)

  let uid_of_sid sid =
    let args = ["-S"; sid] in
    let* stdout =
      call_wbinfo args <!> fun _ ->
      generic_ex "'wbinfo %s' failed" (String.concat " " args)
    in
    try Ok (String.trim stdout |> int_of_string)
    with _ ->
      Error (generic_ex "parsing 'wbinfo %s' failed" (String.concat " " args))

  type uid_info = {user_name: string; uid: int; gid: int; gecos: string}
  [@@deriving rpcty]

  let string_of_uid_info x =
    Rpcmarshal.marshal uid_info.Rpc.Types.ty x |> Jsonrpc.to_string

  let parse_uid_info stdout =
    (* looks like one line from /etc/passwd: https://en.wikipedia.org/wiki/Passwd#Password_file *)
    let err =
      let msg = "could not parse 'wbinfo --uid-info'" in
      Error msg
    in
    match String.split_on_char ':' stdout with
    | [user_name; _passwd; uid; gid; gecos; _homedir; _shell] -> (
      try Ok {user_name; uid= int_of_string uid; gid= int_of_string gid; gecos}
      with _ -> err
    )
    | _ ->
        err

  let uid_info_of_uid (uid : int) =
    let args = ["--uid-info"; string_of_int uid] in
    let* stdout =
      call_wbinfo args <!> fun _ ->
      generic_ex "'wbinfo %s' failed" (String.concat " " args)
    in
    parse_uid_info stdout <!> generic_ex "%s"
end

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
    else
      debug "Skip starting %s as AD is not enabled" name

  let check_ready_to_serve ~timeout =
    (* we _need_ to use a username contained in our domain, otherwise the following tests won't work.
       Microsoft KB/Q243330 article provides the KRBTGT account as a well-known built-in SID in AD
       Microsoft KB/Q229909 article says that KRBTGT account cannot be renamed or enabled, making
       it the perfect target for such a test using a username (Administrator account can be renamed) *)
    let resolve_KRBTGT () =
      try
        Helpers.call_script ~log_output:Never wb_cmd ["-n"; "KRBTGT"] |> ignore ;
        true
      with _ -> false
    in
    try
      Helpers.retry_until_timeout ~timeout
        (Printf.sprintf "Checking %s ready to serve" name)
        resolve_KRBTGT ;
      debug "Service %s is ready to serve request" name
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
        debug "Succeed to clean the machine account for domain %s" service_name
      with _ ->
        let msg =
          Printf.sprintf "Failed to clean the machine account for domain %s"
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
    Helpers.FileSys.rmrf ~rm_top:false folder ;
    debug "Succeed to clean local winbind resources"
  with e ->
    let msg = "Failed to clean local samba resources" in
    error "%s : %s" msg (ExnHelper.string_of_exn e) ;
    raise (Auth_service_error (E_GENERIC, msg))

let domainify_uname ~domain uname =
  let open Astring.String in
  if
    is_infix ~affix:domain uname
    || is_infix ~affix:"@" uname
    || is_infix ~affix:{|\|} uname
    || uname = krbtgt
  then
    uname
  else
    Printf.sprintf "%s@%s" uname domain

module AuthADWinbind : Auth_signature.AUTH_MODULE = struct
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

  (* subject_id get_subject_identifier(string subject_name)

      Takes a subject_name (as may be entered into the XenCenter UI when defining subjects --
      see Access Control wiki page); and resolves it to a subject_id against the external
      auth/directory service.
      Raises Not_found (*Subject_cannot_be_resolved*) if authentication is not succesful.
  *)
  let get_subject_identifier _subject_name =
    "get_subject_identifier To be implemented in CP-36087"

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
    ["To be implemented in CP-36088"]

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
      debug "Succeed to join domain %s" service_name
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
    persist_extauth_config ~domain:"" ~user:"" ~ou_conf:[] ;
    debug "Succeed to disable external auth for %s" service_name

  (* unit on_xapi_initialize(bool system_boot)

      Called internally by xapi whenever it starts up. The system_boot flag is true iff xapi is
      starting for the first time after a host boot
  *)
  let on_xapi_initialize system_boot =
    debug "on_xapi_initialize To be implemented in CP-36089"

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
