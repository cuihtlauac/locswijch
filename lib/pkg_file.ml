type source = {
  url : string;
  checksum : string option;
}

type t = {
  name : string;
  version : string;
  depends : string list;
  source : source option;
  build : Sexp_parser.t list option;
  install : Sexp_parser.t list option;
  exported_env : (string * string * string) list;
}

let parse_name_version_from_filename path =
  let base = Filename.basename path in
  (* Format: <name>.<version>.pkg *)
  let base = Filename.chop_extension base in (* remove .pkg *)
  match String.index_opt base '.' with
  | None -> (base, "dev")
  | Some i ->
    let name = String.sub base 0 i in
    let version = String.sub base (i + 1) (String.length base - i - 1) in
    (name, version)

let extract_depends sexps =
  match Sexp_parser.find_field "depends" sexps with
  | None -> []
  | Some [ Sexp_parser.List (Atom "all_platforms" :: deps) ] ->
    List.filter_map
      (fun d ->
        match d with
        | Sexp_parser.Atom name -> Some name
        | Sexp_parser.List (Atom name :: _) -> Some name
        | _ -> None)
      deps
  | Some deps ->
    List.filter_map
      (fun d ->
        match d with
        | Sexp_parser.Atom name -> Some name
        | Sexp_parser.List (Atom name :: _) -> Some name
        | _ -> None)
      deps

let extract_source sexps =
  match Sexp_parser.find_field "source" sexps with
  | Some [ Sexp_parser.List (Atom "fetch" :: fields) ] ->
    let url =
      match Sexp_parser.find_field "url" fields with
      | Some [ Atom u ] -> Some u
      | _ -> None
    in
    let checksum =
      match Sexp_parser.find_field "checksum" fields with
      | Some [ Atom c ] -> Some c
      | _ -> None
    in
    (match url with
     | Some url -> Some { url; checksum }
     | None -> None)
  | _ -> None

let extract_build sexps =
  match Sexp_parser.find_field "build" sexps with
  | None -> None
  | Some content -> Some content

let extract_install sexps =
  match Sexp_parser.find_field "install" sexps with
  | None -> None
  | Some content -> Some content

let extract_exported_env sexps =
  match Sexp_parser.find_field "exported_env" sexps with
  | None -> []
  | Some envs ->
    List.filter_map
      (fun sexp ->
        match sexp with
        | Sexp_parser.List [ Atom op; Atom var; Atom value ] ->
          Some (op, var, value)
        | Sexp_parser.List [ Atom op; Atom var; List _ ] ->
          (* env values with complex expressions - skip *)
          Some (op, var, "")
        | _ -> None)
      envs

let load path =
  let name, version = parse_name_version_from_filename path in
  let sexps = Sexp_parser.parse_file path in
  (* version field in file overrides filename-derived version *)
  let version =
    match Sexp_parser.find_field "version" sexps with
    | Some [ Atom v ] -> v
    | _ -> version
  in
  let depends = extract_depends sexps in
  let source = extract_source sexps in
  let build = extract_build sexps in
  let install = extract_install sexps in
  let exported_env = extract_exported_env sexps in
  { name; version; depends; source; build; install; exported_env }

let load_all ~lock_dir =
  let entries = Sys.readdir lock_dir in
  Array.to_list entries
  |> List.filter (fun name -> Filename.check_suffix name ".pkg")
  |> List.map (fun name -> load (Filename.concat lock_dir name))

let parse_digest_dir dirname =
  (* Format: <name>.<version>-<hex_digest> *)
  match String.index_opt dirname '.' with
  | None -> None
  | Some dot_pos ->
    let after_dot = String.sub dirname (dot_pos + 1)
        (String.length dirname - dot_pos - 1) in
    (* Find the last '-' which separates version from digest *)
    match String.rindex_opt after_dot '-' with
    | None -> None
    | Some dash_pos ->
      let name = String.sub dirname 0 dot_pos in
      let version = String.sub after_dot 0 dash_pos in
      let digest = String.sub after_dot (dash_pos + 1)
          (String.length after_dot - dash_pos - 1) in
      Some (name, version, digest)

let read_ocaml_pkg ~lock_dir =
  let lock_dune = Filename.concat lock_dir "lock.dune" in
  if not (Sys.file_exists lock_dune) then None
  else
    let sexps = Sexp_parser.parse_file lock_dune in
    match Sexp_parser.find_field "ocaml" sexps with
    | Some [ Atom name ] -> Some name
    | _ -> None
