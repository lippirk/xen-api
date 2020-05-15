 let product_version () = Inventory.lookup ~default:"" "PRODUCT_VERSION" 
 let product_version_text () = Inventory.lookup ~default:"" "PRODUCT_VERSION_TEXT" 
 let product_version_text_short () = Inventory.lookup ~default:"" "PRODUCT_VERSION_TEXT_SHORT" 
 let platform_name () = Inventory.lookup ~default:"" "PLATFORM_NAME" 
 let platform_version () = Inventory.lookup ~default:"0.0.0" "PLATFORM_VERSION" 
 let product_brand () = Inventory.lookup ~default:"" "PRODUCT_BRAND" 
 let build_number () = Inventory.lookup ~default:"" "BUILD_NUMBER" 

let git_id = ""
let hostname = "localhost"
let date = Build_info.date

let (xapi_version_major, xapi_version_minor) =
  let version_of_string v =
    try
      Scanf.sscanf v "%d.%d.%s" (fun maj min _rest -> Some (maj, min))
    with _ ->
      None
  in
  let env_version = version_of_string Build_info.version in (* derived from XAPI_VERSION env var *)
  let ov = "%%VERSION_NUM%%" in
  Printf.eprintf "env_version=%s, ov=%s" Build_info.version ov;
  let opam_version = version_of_string ov in
  match (env_version, opam_version) with
  | (Some ((maj, min)), None) | (None, Some ((maj, min))) -> (maj, min)
  | (None, None)                                          -> failwith (Printf.sprintf "Cannot determine xapi version: ov=%s" ov)
  | (Some (e_maj, e_min), Some (o_maj, o_min))            ->
      (* did you call dune subst when building with make? *)
      failwith (Printf.sprintf "Didn't expect two xapi versions - (%d,%d) and (%d,%d)" e_maj e_min o_maj o_min)
