type pkg_info = {
  name : string;
  version : string;
  depends : string list;
  build : string list list;
  install : string list list;
  url : string option;
  checksum : string option;
  exported_env : (string * string * string) list;
}

let parse_pkg_ident s =
  (* "name.version" *)
  match String.index_opt s '.' with
  | None -> (s, "dev")
  | Some i ->
    (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))

let read_pkg_list_section content section_name =
  (* Find "section_name: [" and read quoted entries until "]" *)
  let lines = String.split_on_char '\n' content in
  let in_section = ref false in
  let results = ref [] in
  List.iter
    (fun line ->
      let line = String.trim line in
      if line = section_name ^ ": [" then in_section := true
      else if !in_section && line = "]" then in_section := false
      else if !in_section then begin
        (* Extract quoted string *)
        match String.index_opt line '"' with
        | None -> ()
        | Some q1 ->
          (match String.index_from_opt line (q1 + 1) '"' with
           | None -> ()
           | Some q2 ->
             let s = String.sub line (q1 + 1) (q2 - q1 - 1) in
             results := s :: !results)
      end)
    lines;
  List.rev !results

let read_installed ~switch_dir =
  let path =
    List.fold_left Filename.concat switch_dir
      [ ".opam-switch"; "switch-state" ]
  in
  let ic = open_in path in
  let content =
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let n = in_channel_length ic in
        really_input_string ic n)
  in
  let idents = read_pkg_list_section content "installed" in
  List.map parse_pkg_ident idents

let read_compiler_pkgs ~switch_dir =
  let path =
    List.fold_left Filename.concat switch_dir
      [ ".opam-switch"; "switch-state" ]
  in
  let ic = open_in path in
  let content =
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let n = in_channel_length ic in
        really_input_string ic n)
  in
  let idents = read_pkg_list_section content "compiler" in
  List.map parse_pkg_ident idents

let read_opam_file path =
  OpamParser.FullPos.file path

let opam_ident_to_dune s =
  (* Handle _:var (self-reference) *)
  if String.length s > 2 && String.sub s 0 2 = "_:" then
    let var = String.sub s 2 (String.length s - 2) in
    "%{pkg-self:" ^ var ^ "}"
  else
    match s with
    | "name" -> "%{pkg-self:name}"
    | "jobs" -> "%{jobs}"
    | "make" -> "%{make}"
    | "prefix" -> "%{prefix}"
    | "lib" -> "%{lib}"
    | "bin" -> "%{bin}"
    | "doc" -> "%{doc}"
    | "share" -> "%{share}"
    | "man" -> "%{man}"
    | _ -> "%{" ^ s ^ "}"

let translate_opam_string_vars s =
  (* Replace opam %{_:var}% with dune %{pkg-self:var}
     and %{var}% with %{var} *)
  let buf = Buffer.create (String.length s) in
  let i = ref 0 in
  let len = String.length s in
  while !i < len do
    if !i + 1 < len && s.[!i] = '%' && s.[!i + 1] = '{' then begin
      (* Find closing }% *)
      match String.index_from_opt s (!i + 2) '}' with
      | Some j when j + 1 < len && s.[j + 1] = '%' ->
        let var = String.sub s (!i + 2) (j - !i - 2) in
        (* Translate opam variable reference *)
        let dune_var =
          if String.length var > 2 && String.sub var 0 2 = "_:" then
            "pkg-self:" ^ String.sub var 2 (String.length var - 2)
          else if String.contains var ':' then
            (* Cross-package reference: %{pkg-name:var}% → %{pkg:pkg-name:var} *)
            "pkg:" ^ var
          else var
        in
        Buffer.add_string buf "%{";
        Buffer.add_string buf dune_var;
        Buffer.add_char buf '}';
        i := j + 2
      | _ ->
        Buffer.add_char buf s.[!i];
        incr i
    end
    else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf

let extract_value (v : OpamParserTypes.FullPos.value) =
  match v.pelem with
  | OpamParserTypes.FullPos.String s -> Some (translate_opam_string_vars s)
  | OpamParserTypes.FullPos.Ident s -> Some (opam_ident_to_dune s)
  | _ -> None

let extract_string_list items = List.filter_map extract_value items

let is_single_command items =
  (* If all items are strings/idents (not sublists), it's a single command *)
  List.for_all
    (fun (item : OpamParserTypes.FullPos.value) ->
      match item.pelem with
      | OpamParserTypes.FullPos.String _ | OpamParserTypes.FullPos.Ident _ -> true
      | _ -> false)
    items

let extract_command_lists items =
  if is_single_command items then
    (* Single command: [make "all" "PREFIX=..."] *)
    let cmd = extract_string_list items in
    if cmd = [] then [] else [ cmd ]
  else
    List.filter_map
      (fun (item : OpamParserTypes.FullPos.value) ->
        match item.pelem with
        | OpamParserTypes.FullPos.List { pelem = args; _ } ->
          let cmd = extract_string_list args in
          if cmd = [] then None else Some cmd
        | OpamParserTypes.FullPos.Option
            ({ pelem = List { pelem = args; _ }; _ }, _) ->
          (* Command with filter, e.g. ["cmd" "arg"] {condition} *)
          let cmd = extract_string_list args in
          if cmd = [] then None else Some cmd
        | _ -> None)
      items

let read_package_opam ~switch_dir ~name ~version =
  let pkg_dir =
    List.fold_left Filename.concat switch_dir
      [ ".opam-switch"; "packages"; name ^ "." ^ version ]
  in
  let opam_path = Filename.concat pkg_dir "opam" in
  if not (Sys.file_exists opam_path) then
    { name; version; depends = []; build = []; install = [];
      url = None; checksum = None; exported_env = [] }
  else
    let file = read_opam_file opam_path in
    let depends = ref [] in
    let build = ref [] in
    let install = ref [] in
    let url = ref None in
    let checksum = ref None in
    let exported_env = ref [] in
    List.iter
      (fun (item : OpamParserTypes.FullPos.opamfile_item) ->
        match item.pelem with
        | OpamParserTypes.FullPos.Variable (name_node, value) ->
          (match name_node.pelem, value.pelem with
           | "depends", OpamParserTypes.FullPos.List { pelem = deps; _ } ->
             depends :=
               List.filter_map
                 (fun (d : OpamParserTypes.FullPos.value) ->
                   match d.pelem with
                   | OpamParserTypes.FullPos.String s -> Some s
                   | OpamParserTypes.FullPos.Ident s -> Some s
                   | OpamParserTypes.FullPos.Option
                       ({ pelem = String s; _ }, _) ->
                     Some s
                   | OpamParserTypes.FullPos.Option
                       ({ pelem = Ident s; _ }, _) ->
                     Some s
                   | _ -> None)
                 deps
           | "build", OpamParserTypes.FullPos.List { pelem = cmds; _ } ->
             build := extract_command_lists cmds
           | "install", OpamParserTypes.FullPos.List { pelem = cmds; _ } ->
             install := extract_command_lists cmds
           | _ -> ())
        | OpamParserTypes.FullPos.Section
            { section_kind = { pelem = "url"; _ };
              section_items = { pelem = items; _ }; _ } ->
          List.iter
            (fun (item : OpamParserTypes.FullPos.opamfile_item) ->
              match item.pelem with
              | OpamParserTypes.FullPos.Variable (n, v) ->
                (match n.pelem, v.pelem with
                 | "src", OpamParserTypes.FullPos.String s -> url := Some s
                 | "checksum", OpamParserTypes.FullPos.String s ->
                   checksum := Some s
                 | "checksum",
                   OpamParserTypes.FullPos.List { pelem = cs; _ } ->
                   (match cs with
                    | { pelem = OpamParserTypes.FullPos.String s; _ } :: _ ->
                      checksum := Some s
                    | _ -> ())
                 | _ -> ())
              | _ -> ())
            items
        | _ -> ())
      file.file_contents;
    let _ = exported_env in
    { name; version; depends = !depends; build = !build; install = !install;
      url = !url; checksum = !checksum; exported_env = [] }
