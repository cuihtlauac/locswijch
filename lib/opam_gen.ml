let write_file path content =
  Hardlink.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc content)

let pkg_ident pkg = pkg.Pkg_file.name ^ "." ^ pkg.Pkg_file.version

let write_switch_config config _pkgs =
  let path =
    List.fold_left Filename.concat config.Config.switch_dir
      [ ".opam-switch"; "switch-config" ]
  in
  let content =
    Printf.sprintf
      {|opam-version: "2.0"
synopsis: "locswijch: %s"
repositories: "default"
opam-root: "%s"
invariant: []
paths {

}
variables {
  user: "%s"
  group: "%s"
}
|}
      config.switch_name config.opam_root
      (Sys.getenv "USER")
      (try
         let gr = Unix.getgrgid (Unix.getgid ()) in
         gr.gr_name
       with Not_found -> Sys.getenv "USER")
  in
  write_file path content

let write_switch_state config pkgs ~ocaml_pkg =
  let path =
    List.fold_left Filename.concat config.Config.switch_dir
      [ ".opam-switch"; "switch-state" ]
  in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "opam-version: \"2.0\"\n";
  (* compiler section *)
  let compiler_pkgs =
    match ocaml_pkg with
    | None -> []
    | Some ocaml_name ->
      List.filter
        (fun pkg ->
          let n = pkg.Pkg_file.name in
          n = ocaml_name || n = "ocaml" || n = "ocaml-config"
          || String.length n > 5 && String.sub n 0 5 = "base-")
        pkgs
  in
  Buffer.add_string buf "compiler: [\n";
  List.iter
    (fun pkg -> Printf.bprintf buf "  \"%s\"\n" (pkg_ident pkg))
    compiler_pkgs;
  Buffer.add_string buf "]\n";
  (* roots = all packages *)
  Buffer.add_string buf "roots: [\n";
  List.iter
    (fun pkg -> Printf.bprintf buf "  \"%s\"\n" (pkg_ident pkg))
    pkgs;
  Buffer.add_string buf "]\n";
  (* installed = all packages *)
  Buffer.add_string buf "installed: [\n";
  List.iter
    (fun pkg -> Printf.bprintf buf "  \"%s\"\n" (pkg_ident pkg))
    pkgs;
  Buffer.add_string buf "]\n";
  write_file path (Buffer.contents buf)

let translate_build_action sexp =
  (* Translate dune .pkg build S-expr to opam build string.
     For now, produce a simplified representation. *)
  let rec sexp_to_opam_list = function
    | Sexp_parser.List (Atom "run" :: args) ->
      let args_str =
        List.map
          (function Sexp_parser.Atom s -> Printf.sprintf "\"%s\"" s | _ -> "\"\"")
          args
      in
      "[" ^ String.concat " " args_str ^ "]"
    | Sexp_parser.List (Atom "progn" :: steps) ->
      String.concat "\n  " (List.map sexp_to_opam_list steps)
    | Sexp_parser.List (Atom "when" :: _cond :: actions) ->
      String.concat "\n  " (List.map sexp_to_opam_list actions)
    | Sexp_parser.List (Atom "withenv" :: _env :: actions) ->
      String.concat "\n  " (List.map sexp_to_opam_list actions)
    | Sexp_parser.List [ Atom "action"; action ] -> sexp_to_opam_list action
    | _ -> ""
  in
  sexp_to_opam_list sexp

let write_package_opam config pkg =
  let pkg_dir =
    List.fold_left Filename.concat config.Config.switch_dir
      [ ".opam-switch"; "packages"; pkg_ident pkg ]
  in
  let path = Filename.concat pkg_dir "opam" in
  let buf = Buffer.create 512 in
  Printf.bprintf buf "opam-version: \"2.0\"\n";
  Printf.bprintf buf "name: \"%s\"\n" pkg.name;
  Printf.bprintf buf "version: \"%s\"\n" pkg.version;
  (* depends *)
  if pkg.depends <> [] then begin
    Buffer.add_string buf "depends: [\n";
    List.iter (fun d -> Printf.bprintf buf "  \"%s\"\n" d) pkg.depends;
    Buffer.add_string buf "]\n"
  end;
  (* build *)
  (match pkg.build with
   | Some build_sexps ->
     let build_content =
       match build_sexps with
       | [ Sexp_parser.List (Atom "all_platforms" :: actions) ] ->
         List.filter_map
           (fun action ->
             let s = translate_build_action action in
             if s = "" then None else Some ("  " ^ s))
           actions
       | [ Sexp_parser.List (Atom "choice" :: _) ] ->
         (* Platform-specific: just note it *)
         [ "  [\"echo\" \"platform-specific-build\"]" ]
       | _ -> []
     in
     if build_content <> [] then begin
       Buffer.add_string buf "build: [\n";
       List.iter (fun s -> Printf.bprintf buf "%s\n" s) build_content;
       Buffer.add_string buf "]\n"
     end
   | None -> ());
  (* url *)
  (match pkg.source with
   | Some src ->
     Printf.bprintf buf "url {\n";
     Printf.bprintf buf "  src: \"%s\"\n" src.url;
     (match src.checksum with
      | Some c -> Printf.bprintf buf "  checksum: \"%s\"\n" c
      | None -> ());
     Printf.bprintf buf "}\n"
   | None -> ());
  write_file path (Buffer.contents buf)

let write_environment config pkgs =
  let path =
    List.fold_left Filename.concat config.Config.switch_dir
      [ ".opam-switch"; "environment" ]
  in
  let buf = Buffer.create 512 in
  (* Standard entries *)
  Printf.bprintf buf "OPAM_SWITCH_PREFIX\t=\t%s\t:\ttarget\n"
    config.switch_dir;
  Printf.bprintf buf "PATH\t=+=\t%s/bin\t:\ttarget\n" config.switch_dir;
  Printf.bprintf buf "MANPATH\t=:\t%s/man\t:\ttarget\n" config.switch_dir;
  Printf.bprintf buf "OCAML_TOPLEVEL_PATH\t=\t%s/lib/toplevel\t:\ttarget\n"
    config.switch_dir;
  (* From packages' exported_env *)
  List.iter
    (fun pkg ->
      List.iter
        (fun (op, var, value) ->
          let opam_op =
            match op with
            | "=" -> "="
            | "+=" -> "+="
            | "=+" -> "=+"
            | ":=" -> "="
            | _ -> "="
          in
          (* Substitute %{lib}% with the switch lib dir *)
          let value =
            let lib_dir = Filename.concat config.switch_dir "lib" in
            let pattern = "\\%{lib}%" in
            (* simple substring replacement *)
            let replace s =
              match String.split_on_char '%' s with
              | _ ->
                if String.length s >= 7 then
                  let buf2 = Buffer.create (String.length s) in
                  let i = ref 0 in
                  while !i < String.length s do
                    if !i + 7 <= String.length s
                       && String.sub s !i 7 = pattern
                    then begin
                      Buffer.add_string buf2 lib_dir;
                      i := !i + 7
                    end
                    else begin
                      Buffer.add_char buf2 s.[!i];
                      incr i
                    end
                  done;
                  Buffer.contents buf2
                else s
            in
            replace value
          in
          Printf.bprintf buf "%s\t%s\t%s\t:\ttarget\n" var opam_op value)
        pkg.Pkg_file.exported_env)
    pkgs;
  write_file path (Buffer.contents buf)

let register_switch config =
  let opam_config_path = Filename.concat config.Config.opam_root "config" in
  if Sys.file_exists opam_config_path then begin
    let ic = open_in opam_config_path in
    let content =
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          let n = in_channel_length ic in
          really_input_string ic n)
    in
    (* Check if switch is already registered *)
    let switch_entry = Printf.sprintf "\"%s\"" config.switch_name in
    if not (String.length content > 0
            && (let lines = String.split_on_char '\n' content in
                List.exists
                  (fun line ->
                    let line = String.trim line in
                    line = switch_entry)
                  lines))
    then begin
      (* Add to installed-switches list *)
      let lines = String.split_on_char '\n' content in
      let buf = Buffer.create (String.length content + 100) in
      let in_switches = ref false in
      List.iter
        (fun line ->
          if String.trim line = "installed-switches: [" then begin
            in_switches := true;
            Printf.bprintf buf "%s\n" line;
            Printf.bprintf buf "  \"%s\"\n" config.switch_name
          end
          else if !in_switches && String.trim line = "]" then begin
            in_switches := false;
            Printf.bprintf buf "%s\n" line
          end
          else Printf.bprintf buf "%s\n" line)
        lines;
      let new_content = Buffer.contents buf in
      (* Trim trailing extra newline *)
      let new_content =
        if String.length new_content > 0
           && new_content.[String.length new_content - 1] = '\n'
           && String.length new_content > 1
           && new_content.[String.length new_content - 2] = '\n'
        then String.sub new_content 0 (String.length new_content - 1)
        else new_content
      in
      write_file opam_config_path new_content
    end
  end
