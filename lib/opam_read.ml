type pkg_info = {
  name : string;
  version : string;
  depends : string list;
  build : string list list;
  install : string list list;
  url : string option;
  checksum : string option;
  exported_env : (string * string * string) list;
  extra_sources : (string * string * string option) list;
  build_env : (string * string * string) list;
  substs : string list;
}

(* Predicate for %{pkg:installed}% translation. Set by read_package_opam
   from the caller-supplied installed set; the translators below are shared
   string helpers with no room to thread it through. *)
let is_installed : (string -> bool) ref = ref (fun _ -> true)

(* Host platform variables (os, os-family, os-distribution, os-version,
   arch) for static filter evaluation. Set by read_package_opam from the
   caller-supplied list; empty means unknown, leaving filters that mention
   them unevaluated. Same global-ref pattern as is_installed above. *)
let host_vars : (string * string) list ref = ref []
let set_host_vars vars = host_vars := vars

(* "a+b:installed" means all of a and b are installed. *)
let resolve_installed_var var =
  let pkgs =
    String.sub var 0 (String.length var - 10) |> String.split_on_char '+'
  in
  if List.for_all !is_installed pkgs then "true" else "false"

(* ---------- Static filter evaluation ----------

   Filters are evaluated at migrate time against the host platform: the
   generated lock file is host-specific anyway, since the switch's
   solution already fixed os and arch. Three-valued logic — a filter we
   cannot resolve (e.g. a version constraint on the enclosing package,
   which shares the {...} syntax) evaluates to FUnknown and the caller
   picks the conservative side. *)
type filter_result = FTrue | FFalse | FUnknown

let lookup_filter_var s =
  match s with
  | "with-test" | "with-doc" | "with-dev-setup" | "dev" | "pinned" ->
    Some "false"
  | "build" -> Some "true"
  | s when String.length s > 10
           && String.sub s (String.length s - 10) 10 = ":installed" ->
    Some (resolve_installed_var s)
  | s -> List.assoc_opt s !host_vars

(* Compare version-ish strings, approximately as opam does: alternating
   numeric and non-numeric chunks, numeric chunks compared as integers.
   Falls back to plain string comparison of chunks, which also covers
   equality tests on os names. *)
let version_compare a b =
  let is_digit c = c >= '0' && c <= '9' in
  let chunks s =
    let n = String.length s in
    let rec go i acc =
      if i >= n then List.rev acc
      else begin
        let d = is_digit s.[i] in
        let j = ref i in
        while !j < n && is_digit s.[!j] = d do incr j done;
        go !j ((d, String.sub s i (!j - i)) :: acc)
      end
    in
    go 0 []
  in
  let cmp_chunk (da, ca) (db, cb) =
    match da, db with
    | true, true ->
      (* Numeric: longer (zero-stripped) wins, then lexicographic. *)
      let strip s =
        let i = ref 0 in
        while !i < String.length s - 1 && s.[!i] = '0' do incr i done;
        String.sub s !i (String.length s - !i)
      in
      let ca = strip ca and cb = strip cb in
      let c = compare (String.length ca) (String.length cb) in
      if c <> 0 then c else compare ca cb
    | false, false -> compare ca cb
    | true, false -> 1
    | false, true -> -1
  in
  let rec cmp la lb =
    match la, lb with
    | [], [] -> 0
    | [], _ -> -1
    | _, [] -> 1
    | a :: ra, b :: rb ->
      let c = cmp_chunk a b in
      if c <> 0 then c else cmp ra rb
  in
  cmp (chunks a) (chunks b)

let rec eval_filter (f : OpamParserTypes.FullPos.value) =
  let open OpamParserTypes.FullPos in
  match f.pelem with
  | Bool true -> FTrue
  | Bool false -> FFalse
  | Ident s ->
    (match lookup_filter_var s with
     | Some "true" -> FTrue
     | Some "false" -> FFalse
     | Some _ | None -> FUnknown)
  | Logop ({ pelem = `And; _ }, a, b) ->
    (match eval_filter a, eval_filter b with
     | FFalse, _ | _, FFalse -> FFalse
     | FTrue, FTrue -> FTrue
     | _ -> FUnknown)
  | Logop ({ pelem = `Or; _ }, a, b) ->
    (match eval_filter a, eval_filter b with
     | FTrue, _ | _, FTrue -> FTrue
     | FFalse, FFalse -> FFalse
     | _ -> FUnknown)
  | Pfxop ({ pelem = `Not; _ }, v) ->
    (match eval_filter v with
     | FTrue -> FFalse
     | FFalse -> FTrue
     | FUnknown -> FUnknown)
  | Pfxop ({ pelem = `Defined; _ }, { pelem = Ident s; _ }) ->
    if lookup_filter_var s = None then FFalse else FTrue
  | Group { pelem = vs; _ } -> eval_filters vs
  | Relop ({ pelem = op; _ }, a, b) ->
    (match filter_str a, filter_str b with
     | Some x, Some y ->
       let c = version_compare x y in
       let holds =
         match op with
         | `Eq -> c = 0
         | `Neq -> c <> 0
         | `Geq -> c >= 0
         | `Gt -> c > 0
         | `Leq -> c <= 0
         | `Lt -> c < 0
       in
       if holds then FTrue else FFalse
     | _ -> FUnknown)
  | _ -> FUnknown

and filter_str (v : OpamParserTypes.FullPos.value) =
  match v.pelem with
  | OpamParserTypes.FullPos.String s -> Some s
  | OpamParserTypes.FullPos.Ident s -> lookup_filter_var s
  | _ -> None

(* A filter list {f1 f2} is a conjunction. *)
and eval_filters fs =
  List.fold_left
    (fun acc f ->
      match acc with
      | FFalse -> FFalse
      | _ -> (
        match acc, eval_filter f with
        | FFalse, _ | _, FFalse -> FFalse
        | FTrue, FTrue -> FTrue
        | _ -> FUnknown))
    FTrue fs

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
    (* Variables that don't exist in dune pkg — use constants *)
    | "dev" -> "false"
    | "pinned" -> "false"
    | s when String.length s > 10
             && String.sub s (String.length s - 10) 10 = ":installed" ->
      resolve_installed_var s
    | _ -> (
      (* Host platform variables (os, arch, ...) inline as constants *)
      match List.assoc_opt s !host_vars with
      | Some v -> v
      | None -> "%{" ^ s ^ "}")

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
        (* Some opam variables have no dune equivalent — inline constants *)
        let is_const, const_val =
          if var = "dev" || var = "pinned" then (true, "false")
          else if String.length var > 10
                  && String.sub var (String.length var - 10) 10 = ":installed"
          then (true, resolve_installed_var var)
          else
            match List.assoc_opt var !host_vars with
            | Some v -> (true, v)
            | None -> (false, "")
        in
        if is_const then begin
          Buffer.add_string buf const_val;
          i := j + 2
        end
        else
        let dune_var =
          if String.length var > 2 && String.sub var 0 2 = "_:" then
            "pkg-self:" ^ String.sub var 2 (String.length var - 2)
          else if String.contains var ':' then
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

let rec extract_value (v : OpamParserTypes.FullPos.value) =
  match v.pelem with
  | OpamParserTypes.FullPos.String s -> Some (translate_opam_string_vars s)
  | OpamParserTypes.FullPos.Ident s -> Some (opam_ident_to_dune s)
  | OpamParserTypes.FullPos.Option (inner, { pelem = filters; _ }) ->
    (* Filtered atom inside a command, e.g.
       "pkg-config" {os != "win32"}: keep only when the filter definitely
       holds. Unknown filters drop the atom, matching opam's evaluation
       with test/doc disabled. *)
    if eval_filters filters = FTrue then extract_value inner else None
  | _ -> None

let extract_string_list items = List.filter_map extract_value items

(* A dependency entry may be a disjunction of alternatives
   (e.g. ocaml-base-compiler | ocaml-variants | ocaml-system).
   Collect every alternative; migrate later filters to the packages
   actually installed in the switch. Dependencies marked {post} are
   excluded from install ordering by opam precisely to break cycles
   (ocaml-base-compiler <-> ocaml), so drop them here too. *)
let rec contains_post (f : OpamParserTypes.FullPos.value) =
  match f.pelem with
  | OpamParserTypes.FullPos.Ident "post" -> true
  | OpamParserTypes.FullPos.Logop (_, a, b) ->
    contains_post a || contains_post b
  | OpamParserTypes.FullPos.Pfxop (_, v) -> contains_post v
  | OpamParserTypes.FullPos.Group { pelem = vs; _ } ->
    List.exists contains_post vs
  | _ -> false

let rec dep_names (d : OpamParserTypes.FullPos.value) =
  match d.pelem with
  | OpamParserTypes.FullPos.String s -> [ s ]
  | OpamParserTypes.FullPos.Ident s -> [ s ]
  | OpamParserTypes.FullPos.Option (v, { pelem = filters; _ }) ->
    if List.exists contains_post filters then []
    else if eval_filters filters = FFalse then
      (* Definitely-false platform filter, e.g. the "ocaml" {os = "win32"}
         alternative of conf-libev's disjunction. Version constraints
         evaluate to FUnknown and keep the dep. *)
      []
    else dep_names v
  | OpamParserTypes.FullPos.Logop (_, a, b) ->
    dep_names a @ dep_names b
  | OpamParserTypes.FullPos.Group { pelem = vs; _ } ->
    List.concat_map dep_names vs
  | _ -> []

let is_single_command items =
  (* If no item is a sublist, it's a single command written as a flat list
     of atoms. Atoms may carry filters, e.g. "@runtest" {with-test} in
     ocplib-endian; extract_string_list drops those filtered atoms, which
     matches opam's evaluation with test/doc disabled. *)
  List.for_all
    (fun (item : OpamParserTypes.FullPos.value) ->
      match item.pelem with
      | OpamParserTypes.FullPos.String _ | OpamParserTypes.FullPos.Ident _ -> true
      | OpamParserTypes.FullPos.Option
          ({ pelem = String _ | Ident _; _ }, _) -> true
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
            ({ pelem = List { pelem = args; _ }; _ }, { pelem = filters; _ })
          ->
          (* Command with filter, e.g. ["cmd" "arg"] {condition}: drop
             only when the filter definitely fails (os mismatch,
             with-test, ...); unknown filters keep the command. *)
          if eval_filters filters = FFalse then None
          else
            let cmd = extract_string_list args in
            if cmd = [] then None else Some cmd
        | _ -> None)
      items

let read_package_opam ~host_vars ~switch_dir ~installed_names ~name
    ~version =
  is_installed := (fun p -> List.mem p installed_names);
  set_host_vars host_vars;
  let pkg_dir =
    List.fold_left Filename.concat switch_dir
      [ ".opam-switch"; "packages"; name ^ "." ^ version ]
  in
  let opam_path = Filename.concat pkg_dir "opam" in
  if not (Sys.file_exists opam_path) then
    { name; version; depends = []; build = []; install = [];
      url = None; checksum = None; exported_env = [];
      extra_sources = []; build_env = []; substs = [] }
  else
    let file = read_opam_file opam_path in
    let depends = ref [] in
    let depopts = ref [] in
    let build = ref [] in
    let install = ref [] in
    let url = ref None in
    let checksum = ref None in
    let exported_env = ref [] in
    let extra_sources = ref [] in
    let build_env = ref [] in
    let substs = ref [] in
    let extract_one_env_binding (item : OpamParserTypes.FullPos.value) =
      match item.pelem with
      | OpamParserTypes.FullPos.Env_binding (var, op, value) ->
        let var_s =
          match var.pelem with
          | String s | Ident s -> s
          | _ -> ""
        in
        let op_s =
          match op.pelem with
          | OpamParserTypes.Eq -> "="
          | OpamParserTypes.PlusEq -> "+="
          | OpamParserTypes.EqPlus -> "=+"
          | OpamParserTypes.ColonEq -> ":="
          | OpamParserTypes.EqColon -> "=:"
          | OpamParserTypes.EqPlusEq -> "=+="
        in
        let val_s =
          match value.pelem with
          | String s -> translate_opam_string_vars s
          | Ident s -> opam_ident_to_dune s
          | _ -> ""
        in
        if var_s <> "" then Some (op_s, var_s, val_s) else None
      | _ -> None
    in
    let extract_env_bindings items =
      (* opam env bindings can be: [ [VAR = "val"] [VAR2 += "val2"] ]
         (list of inner lists each containing one Env_binding)
         or: [ VAR = "val"  VAR2 += "val2" ]
         (flat list of Env_bindings) *)
      List.filter_map
        (fun (item : OpamParserTypes.FullPos.value) ->
          match item.pelem with
          | OpamParserTypes.FullPos.Env_binding _ ->
            extract_one_env_binding item
          | OpamParserTypes.FullPos.List { pelem = inner; _ } ->
            (* Inner list: [ VAR = "val" ] *)
            List.find_map extract_one_env_binding inner
          | _ -> None)
        items
    in
    let extract_section_src_checksum items =
      let src = ref None in
      let cksum = ref None in
      List.iter
        (fun (item : OpamParserTypes.FullPos.opamfile_item) ->
          match item.pelem with
          | OpamParserTypes.FullPos.Variable (n, v) ->
            (match n.pelem, v.pelem with
             | "src", OpamParserTypes.FullPos.String s -> src := Some s
             | "checksum", OpamParserTypes.FullPos.String s ->
               cksum := Some s
             | "checksum",
               OpamParserTypes.FullPos.List { pelem = cs; _ } ->
               (match cs with
                | { pelem = OpamParserTypes.FullPos.String s; _ } :: _ ->
                  cksum := Some s
                | _ -> ())
             | _ -> ())
          | _ -> ())
        items;
      (!src, !cksum)
    in
    List.iter
      (fun (item : OpamParserTypes.FullPos.opamfile_item) ->
        match item.pelem with
        | OpamParserTypes.FullPos.Variable (name_node, value) ->
          (match name_node.pelem, value.pelem with
           | "depends", OpamParserTypes.FullPos.List { pelem = deps; _ } ->
             depends := List.concat_map dep_names deps
           | "depopts", OpamParserTypes.FullPos.List { pelem = deps; _ } ->
             (* Optional dependencies. Active ones (i.e. installed in the
                switch) must appear in the lock file's depends so dune
                builds them first and exposes them to this package's
                build; migrate's installed filter drops the inactive
                ones. *)
             depopts := List.concat_map dep_names deps
           | "build", OpamParserTypes.FullPos.List { pelem = cmds; _ } ->
             build := extract_command_lists cmds
           | "install", OpamParserTypes.FullPos.List { pelem = cmds; _ } ->
             install := extract_command_lists cmds
           | "setenv", OpamParserTypes.FullPos.List { pelem = items; _ } ->
             exported_env := extract_env_bindings items
           | "setenv", OpamParserTypes.FullPos.Env_binding (var, op, value) ->
             (* Single env binding, not in a list *)
             let var_s =
               match var.pelem with String s | Ident s -> s | _ -> ""
             in
             let op_s =
               match op.pelem with
               | OpamParserTypes.Eq -> "=" | PlusEq -> "+="
               | EqPlus -> "=+" | ColonEq -> ":=" | EqColon -> "=:"
               | EqPlusEq -> "=+="
             in
             let val_s =
               match value.pelem with
               | String s -> translate_opam_string_vars s
               | Ident s -> opam_ident_to_dune s | _ -> ""
             in
             if var_s <> "" then exported_env := [ (op_s, var_s, val_s) ]
           | "build-env", OpamParserTypes.FullPos.List { pelem = items; _ } ->
             build_env := extract_env_bindings items
           | "substs", OpamParserTypes.FullPos.String s ->
             substs := [ s ]
           | "substs", OpamParserTypes.FullPos.List { pelem = items; _ } ->
             substs := List.filter_map
               (fun (v : OpamParserTypes.FullPos.value) ->
                 match v.pelem with
                 | OpamParserTypes.FullPos.String s -> Some s
                 | _ -> None)
               items
           | _ -> ())
        | OpamParserTypes.FullPos.Section
            { section_kind = { pelem = "url"; _ };
              section_items = { pelem = items; _ }; _ } ->
          let src, cksum = extract_section_src_checksum items in
          (match src with Some s -> url := Some s | None -> ());
          (match cksum with Some s -> checksum := Some s | None -> ())
        | OpamParserTypes.FullPos.Section
            { section_kind = { pelem = "extra-source"; _ };
              section_name = Some { pelem = filename; _ };
              section_items = { pelem = items; _ }; _ } ->
          let src, cksum = extract_section_src_checksum items in
          (match src with
           | Some source_url ->
             extra_sources :=
               (filename, source_url, cksum) :: !extra_sources
           | None -> ())
        | _ -> ())
      file.file_contents;
    { name; version; depends = !depends @ !depopts;
      build = !build; install = !install;
      url = !url; checksum = !checksum;
      exported_env = !exported_env;
      extra_sources = List.rev !extra_sources;
      build_env = !build_env;
      substs = !substs }
