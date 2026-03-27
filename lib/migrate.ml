let sexp_of_command cmd =
  let args = String.concat " " cmd in
  Printf.sprintf "(run %s)" args

let sexp_of_action cmds =
  match cmds with
  | [ cmd ] -> sexp_of_command cmd
  | cmds ->
    let steps = List.map sexp_of_command cmds in
    Printf.sprintf "(progn\n   %s)" (String.concat "\n   " steps)

let write_pkg_file ~lock_dir ~installed_names (info : Opam_read.pkg_info) =
  let info = { info with
    depends = List.filter
      (fun d -> List.mem d installed_names) info.depends }
  in
  (* Non-portable format: <name>.pkg, no all_platforms wrappers *)
  let filename = info.name ^ ".pkg" in
  let path = Filename.concat lock_dir filename in
  let buf = Buffer.create 512 in
  Printf.bprintf buf "(version %s)\n" info.version;
  (* build: (build <action>) — direct action, no wrapper *)
  (match info.build with
   | [] -> ()
   | cmds ->
     let action = sexp_of_action cmds in
     Printf.bprintf buf "\n(build\n %s)\n" action);
  (* install: (install <action>) *)
  (match info.install with
   | [] -> ()
   | cmds ->
     let action = sexp_of_action cmds in
     Printf.bprintf buf "\n(install\n %s)\n" action);
  (* depends: (depends dep1 dep2 ...) — flat list *)
  (match info.depends with
   | [] -> ()
   | deps ->
     Printf.bprintf buf "\n(depends %s)\n" (String.concat " " deps));
  (* source *)
  (match info.url with
   | None -> ()
   | Some url ->
     Buffer.add_string buf "\n(source\n (fetch\n";
     Printf.bprintf buf "  (url %s)\n" url;
     (match info.checksum with
      | Some c -> Printf.bprintf buf "  (checksum %s)\n" c
      | None -> ());
     Buffer.add_string buf " ))\n");
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc (Buffer.contents buf))

let write_lock_dune ~lock_dir ~ocaml_pkg =
  let path = Filename.concat lock_dir "lock.dune" in
  let buf = Buffer.create 256 in
  Buffer.add_string buf "(lang package 0.1)\n";
  (match ocaml_pkg with
   | Some name -> Printf.bprintf buf "\n(ocaml %s)\n" name
   | None -> ());
  Buffer.add_string buf
    "\n(repositories\n (complete false)\n (used\n  ((source \
     https://github.com/ocaml/opam-repository.git))))\n";
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc (Buffer.contents buf))

let run switch_name project_root =
  let config = Config.resolve ~project_root ~switch_name in
  if not (Sys.file_exists
            (List.fold_left Filename.concat config.switch_dir
               [ ".opam-switch"; "switch-state" ]))
  then begin
    Printf.eprintf "Error: Switch %s does not exist or has no state.\n"
      config.switch_name;
    exit 1
  end;
  (* Read installed packages *)
  let installed = Opam_read.read_installed ~switch_dir:config.switch_dir in
  let compiler_pkgs =
    Opam_read.read_compiler_pkgs ~switch_dir:config.switch_dir
  in
  (* Determine ocaml compiler package *)
  let ocaml_pkg =
    List.find_map
      (fun (name, _version) ->
        if name = "ocaml-base-compiler" || name = "ocaml-system" then
          Some name
        else None)
      compiler_pkgs
  in
  (* Create lock dir *)
  Hardlink.mkdir_p config.lock_dir;
  (* Read and translate each package *)
  let installed_names = List.map fst installed in
  let count = ref 0 in
  List.iter
    (fun (name, version) ->
      let info =
        Opam_read.read_package_opam ~switch_dir:config.switch_dir ~name ~version
      in
      write_pkg_file ~lock_dir:config.lock_dir ~installed_names info;
      incr count)
    installed;
  write_lock_dune ~lock_dir:config.lock_dir ~ocaml_pkg;
  Printf.printf "Generated dune.lock/ with %d packages from switch %s\n"
    !count config.switch_name;
  Printf.printf
    "Next steps:\n\
    \  1. Run: dune build\n\
    \  2. Run: locswijch sync\n"
