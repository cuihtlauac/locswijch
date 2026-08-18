(* Quote an atom for the generated sexp when it needs it (embedded shell
   snippets like sh -c "a || b"). Dune expands %{...} pforms inside quoted
   strings, so quoting is always safe. *)
let quote_atom s =
  let needs_quote =
    s = ""
    || String.exists
         (fun c ->
           c = ' ' || c = '\t' || c = '\n' || c = '"' || c = '\\'
           || c = '(' || c = ')' || c = ';')
         s
  in
  if not needs_quote then s
  else begin
    let buf = Buffer.create (String.length s + 2) in
    Buffer.add_char buf '"';
    String.iter
      (fun c ->
        match c with
        | '"' -> Buffer.add_string buf "\\\""
        | '\\' -> Buffer.add_string buf "\\\\"
        | '\n' -> Buffer.add_string buf "\\n"
        | c -> Buffer.add_char buf c)
      s;
    Buffer.add_char buf '"';
    Buffer.contents buf
  end

let sexp_of_command cmd =
  let args = String.concat " " (List.map quote_atom cmd) in
  Printf.sprintf "(run %s)" args

let sexp_of_action cmds =
  match cmds with
  | [ cmd ] -> sexp_of_command cmd
  | cmds ->
    let steps = List.map sexp_of_command cmds in
    Printf.sprintf "(progn\n   %s)" (String.concat "\n   " steps)

(* Vanilla opam builds of some packages bake absolute build-time paths into
   installed files. Under opam this is harmless (the build prefix is the
   final prefix), but dune pkg runs builds in a copy sandbox that is deleted
   afterwards, leaving dead paths behind. Dune's own lock flow avoids this
   via patched packages in opam-overlays; migrate generates from vanilla
   switch metadata, so patch equivalently here. *)
let apply_overrides (info : Opam_read.pkg_info) =
  match info.name with
  | "ocamlfind" ->
    (* configure bakes the (sandbox) build prefix into findlib.conf,
       topfind, Makefile.config and findlib_config.ml, and into the
       ocamlfind binary's compiled-in conf path. The opam-overlays patch
       solves this with -with-relative-paths-at: paths are stored relative
       to the prefix and resolved at runtime from the binary's location.
       Unlike the overlay we keep topfind (topkg-built packages need it)
       and strip any remaining sandbox component from the installed text
       files as a safety net. *)
    let build =
      List.concat_map
        (fun cmd ->
          match cmd with
          | "./configure" :: _ ->
            (* The -config argument is baked into the ocamlfind binary as
               an absolute string; at build time %{lib} is the sandbox
               path, which is deleted afterwards, so the installed binary
               would find no configuration at all (the runtime is not
               relative for the config file itself, only for $PREFIX
               entries inside it). Rewrite the sandbox path to the final
               one at configure time, same rewrite as the install-time
               sed below. *)
            let atoms =
              List.map
                (fun a ->
                  if a = "%{lib}/findlib.conf" then "$CONF/findlib.conf"
                  else a)
                cmd
            in
            [ [ "sh"; "-c";
                "CONF=$(echo '%{lib}' | sed -e \
                 's#/[.]sandbox/[0-9a-f]*##'); "
                ^ String.concat " " atoms
                ^ " -with-relative-paths-at %{prefix}" ];
              (* Vanilla configure writes FINDLIB_PATH=$PREFIX/... into
                 Makefile.config without doubling the $ for make (unlike
                 RELATIVE_OCAML_SITELIB, which it does escape). Make then
                 expands the undefined $P and the generated findlib.conf
                 gets a mangled "REFIX/lib" search path, so ocamlfind
                 finds no packages at all — first seen as ocamlbuild
                 -use-ocamlfind failing on topkg packages (mtime, ptime).
                 Escape it before make runs. *)
              [ "sh"; "-c";
                "sed -i -e '/^FINDLIB_PATH=/ s/\\$PREFIX/$$PREFIX/g' \
                 Makefile.config" ] ]
          | _ -> [ cmd ])
        info.build
    in
    let sed_fix =
      [ "sh"; "-c";
        "for f in %{lib}/findlib.conf %{lib}/toplevel/topfind \
         %{lib}/findlib/topfind %{lib}/findlib/Makefile.config \
         %{lib}/findlib/findlib_config.ml; do \
         test -f $f && sed -i -e 's#/[.]sandbox/[0-9a-f]*##g' $f; \
         done; true" ]
    in
    (* make install copies findlib.conf to the literal OCAMLFIND_CONF
       path. The configure above set it to the final (post-sandbox)
       location so the binary bakes a path that survives; installing
       there directly would escape the sandbox and pre-create the target
       dir, which dune then refuses to populate. Point the install back
       into the sandbox — dune moves it to the final location, where the
       baked path finds it. *)
    let install =
      List.map
        (fun cmd ->
          match cmd with
          | "%{make}" :: "install" :: rest ->
            ("%{make}" :: "install"
             :: "OCAMLFIND_CONF=%{lib}/findlib.conf" :: rest)
          | _ -> cmd)
        info.install
    in
    { info with build; install = install @ [ sed_fix ] }
  | "ocamlbuild" ->
    (* configure.make bakes OCAMLBUILD_LIBDIR (and friends) into the
       ocamlbuild binary; with the sandbox paths from %{lib} the
       installed binary reports a dead `ocamlbuild -where`, so plugin
       builds (any package with myocamlbuild.ml, e.g. topkg users like
       mtime and ptime) cannot find ocamlbuild.cmo. Same cure as
       ocamlfind above: configure and compile against the final
       (post-sandbox) paths, then override the variables back to the
       sandbox for the install step so dune can move the results. *)
    let build =
      List.concat_map
        (fun cmd ->
          match cmd with
          | "%{make}" :: "-f" :: "configure.make" :: "all" :: args ->
            let args' =
              List.map
                (fun a ->
                  match String.index_opt a '=' with
                  | Some i when String.length a > i + 2
                                && String.sub a 0 10 = "OCAMLBUILD" ->
                    let var = String.sub a 0 i in
                    let v = String.sub a (i + 1) (String.length a - i - 1) in
                    Printf.sprintf "%s=$(echo '%s' | sed -e \
                                    's#/[.]sandbox/[0-9a-f]*##')" var v
                  | _ -> a)
                args
            in
            [ [ "sh"; "-c";
                "%{make} -f configure.make all " ^ String.concat " " args' ]
            ]
          | "%{make}" :: "check-if-preinstalled" :: "all" :: "opam-install"
            :: rest ->
            [ [ "%{make}"; "check-if-preinstalled"; "all" ] @ rest;
              [ "%{make}"; "opam-install";
                "OCAMLBUILD_PREFIX=%{prefix}"; "OCAMLBUILD_BINDIR=%{bin}";
                "OCAMLBUILD_LIBDIR=%{lib}"; "OCAMLBUILD_MANDIR=%{man}" ] ]
          | _ -> [ cmd ])
        info.build
    in
    { info with build }
  | _ -> info

let write_pkg_file ~lock_dir ~installed_names (info : Opam_read.pkg_info) =
  let info = apply_overrides info in
  let info = { info with
    depends = List.filter
      (fun d -> List.mem d installed_names) info.depends }
  in
  (* Non-portable format: <name>.pkg, no all_platforms wrappers *)
  let filename = info.name ^ ".pkg" in
  let path = Filename.concat lock_dir filename in
  let buf = Buffer.create 512 in
  Printf.bprintf buf "(version %s)\n" info.version;
  (* build: (build <action>) — optionally wrapped in (withenv ...) *)
  (* If substs are present and no build command, generate substitute actions *)
  let build_cmds =
    match info.build, info.substs with
    | [], _ :: _ ->
      (* No build but has substs — generate substitute actions as build *)
      None (* handled specially below *)
    | cmds, _ -> Some cmds
  in
  let subst_action =
    match info.substs with
    | [] -> None
    | [ s ] -> Some (Printf.sprintf "(substitute %s.in %s)" s s)
    | substs ->
      let steps = List.map
          (fun s -> Printf.sprintf "(substitute %s.in %s)" s s) substs in
      Some (Printf.sprintf "(progn\n   %s)" (String.concat "\n   " steps))
  in
  (match build_cmds, subst_action with
   | Some [], None -> ()
   | Some [], Some subst ->
     Printf.bprintf buf "\n(build\n %s)\n" subst
   | None, Some subst ->
     Printf.bprintf buf "\n(build\n %s)\n" subst
   | Some cmds, _ when cmds <> [] ->
     let action = sexp_of_action cmds in
     (match info.build_env with
      | [] ->
        Printf.bprintf buf "\n(build\n %s)\n" action
      | envs ->
        Buffer.add_string buf "\n(build\n (withenv\n  (";
        List.iter
          (fun (op, var, value) ->
            Printf.bprintf buf "(%s %s %s)\n   " op var value)
          envs;
        Printf.bprintf buf ")\n  %s))\n" action)
   | _ -> ());
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
  (* exported_env *)
  (match info.exported_env with
   | [] -> ()
   | envs ->
     Buffer.add_string buf "\n(exported_env\n";
     List.iter
       (fun (op, var, value) ->
         Printf.bprintf buf " (%s %s \"%s\")\n" op var value)
       envs;
     Buffer.add_string buf ")\n");
  (* extra_sources *)
  (match info.extra_sources with
   | [] -> ()
   | srcs ->
     Buffer.add_string buf "\n(extra_sources\n";
     List.iter
       (fun (filename, source_url, cksum) ->
         Printf.bprintf buf " (%s\n  (fetch\n" filename;
         Printf.bprintf buf "   (url\n    %s)\n" source_url;
         (match cksum with
          | Some c -> Printf.bprintf buf "   (checksum\n    %s)\n" c
          | None -> ());
         Buffer.add_string buf "  ))\n")
       srcs;
     Buffer.add_string buf ")\n");
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

(* Host platform values for static filter evaluation in Opam_read. The
   generated lock file is host-specific anyway (the switch's solution
   already fixed os and arch), so os-conditional build commands and deps
   are resolved at migrate time. A failing opam leaves them unknown, which
   keeps filtered commands conservatively. *)
let detect_host_vars () =
  List.filter_map
    (fun var ->
      let cmd =
        Printf.sprintf "opam var --global %s 2>/dev/null"
          (Filename.quote var)
      in
      let ic = Unix.open_process_in cmd in
      let line =
        try Some (String.trim (input_line ic)) with End_of_file -> None
      in
      match (Unix.close_process_in ic, line) with
      | Unix.WEXITED 0, Some v when v <> "" -> Some (var, v)
      | _ -> None)
    [ "os"; "os-family"; "os-distribution"; "os-version"; "arch" ]

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
  let host_vars = detect_host_vars () in
  let count = ref 0 in
  List.iter
    (fun (name, version) ->
      let info =
        Opam_read.read_package_opam ~host_vars
          ~switch_dir:config.switch_dir ~installed_names ~name ~version
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
