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
 * @group Pool Management
*)

module Mutex = Xapi_stdext_threads.Threadext.Mutex
module Unixext = Xapi_stdext_unix.Unixext

module D = Debug.Make (struct let name = "pool_role" end)

open D

(** The role of this node *)
type t =
  | Master
  | Slave of string * string option
  (* (ip, fqdn) *)
  | Broken

module T : sig
  val string_of : t -> string

  val of_string : string -> t option
end = struct
  open Angstrom

  let is_ws = function
    | ' ' ->
        true
    | '\t' ->
        true
    | '\n' ->
        true
    | '\r' ->
        true
    | _ ->
        false

  let is_not_ws x = is_ws x |> not

  let ip_str =
    take_while is_not_ws >>= fun ip ->
    match Ipaddr.of_string ip with
    | Error _ ->
        Printf.sprintf "pool_role.ml: cannot parse ip: %s" ip |> fail
    | Ok _ ->
        return ip

  let broken = string "broken" <* end_of_input >>| fun _ -> Broken

  let master = string "master" <* end_of_input >>| fun _ -> Master

  let slave =
    string "slave:" *> ip_str >>= fun ip ->
    end_of_input *> return (Slave (ip, None))
    <|> ( char ' ' *> take_while is_not_ws >>= fun hostname ->
          end_of_input *> return (Slave (ip, Some hostname)) )

  let of_string x =
    parse_string (master <|> broken <|> slave) x |> Stdlib.Result.to_option

  let string_of = function
    | Master ->
        "master"
    | Broken ->
        "broken"
    | Slave (ip, None) ->
        Printf.sprintf "slave:%s" ip
    | Slave (ip, Some fqdn) ->
        Printf.sprintf "slave:%s %s" ip fqdn
end

let string_of = T.string_of

let role = ref None

let role_unit_tests = ref false

let role_m = Mutex.create ()

let with_pool_role_lock f = Mutex.execute role_m f

let set_pool_role_for_test () =
  with_pool_role_lock (fun _ ->
      role := Some Master ;
      role_unit_tests := true)

let is_unit_test () = with_pool_role_lock (fun _ -> !role_unit_tests)

let read_pool_role () =
  try
    Astring.String.trim (Unixext.string_of_file !Constants.pool_config_file)
    |> T.of_string
    |> Option.get
  with _ ->
    (* If exec name is suite.opt, we're running as unit tests *)
    if "xapi" <> Filename.basename Sys.executable_name then (
      debug
        "Executable name is not 'xapi', so we must be running in unit-test \
         mode; setting pool-role to 'Master'" ;
      Master
    ) else (
      error "Failed to read pool role from %s" !Constants.pool_config_file ;
      Broken
    )

let get_role () =
  with_pool_role_lock (fun _ ->
      match !role with
      | Some x ->
          x
      | None ->
          let r = read_pool_role () in
          role := Some r ;
          r)

let is_master () = get_role () = Master

let is_slave () = match get_role () with Slave _ -> true | _ -> false

let is_broken () = get_role () = Broken

exception This_host_is_a_master

exception This_host_is_broken

let get_master_address () =
  match get_role () with
  | Slave (ip, _) ->
      ip
  | Master ->
      raise This_host_is_a_master
  | Broken ->
      raise This_host_is_broken
