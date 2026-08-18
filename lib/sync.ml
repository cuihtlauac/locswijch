let ensure_switch_skeleton switch_dir =
  let dirs =
    [ "bin"; "lib"; "lib/stublibs"; "lib/toplevel"; "share"; "doc"; "etc";
      "man"; "sbin";
      ".opam-switch"; ".opam-switch/packages"; ".opam-switch/install";
      ".opam-switch/locswijch"; ".opam-switch/config";
      ".opam-switch/backup" ]
  in
  List.iter
    (fun d -> Hardlink.mkdir_p (Filename.concat switch_dir d))
    dirs;
  (* Create empty files opam expects *)
  List.iter
    (fun f ->
      let path = Filename.concat switch_dir f in
      if not (Sys.file_exists path) then close_out (open_out path))
    [ ".opam-switch/lock"; ".opam-switch/reinstall" ]

(* The lock dir names packages but carries no digests, and several digest
   dirs can share a name and version, so only dune can say which one the
   current dune.lock builds. Ask it rather than recompute its digest. *)
let live_digest_dir ~project_root name =
  let cmd =
    Printf.sprintf
      "cd %s && opam exec -- dune pkg print-digest %s 2>/dev/null"
      (Filename.quote project_root) (Filename.quote name)
  in
  let ic = Unix.open_process_in cmd in
  let line = try Some (String.trim (input_line ic)) with End_of_file -> None in
  match (Unix.close_process_in ic, line) with
  | Unix.WEXITED 0, Some l when l <> "" -> Some l
  | _ -> None

(* Digest dirnames the current dune.lock builds, or None (no pruning) when
   dune cannot tell us, e.g. a dune without `dune pkg print-digest`. *)
let live_digest_set ~project_root pkgs =
  let rec loop acc = function
    | [] -> Some acc
    | pkg :: rest -> (
      match live_digest_dir ~project_root pkg.Pkg_file.name with
      | Some dir -> loop (dir :: acc) rest
      | None ->
        Printf.eprintf
          "Warning: `dune pkg print-digest %s` failed; \
           not pruning stale digest dirs.\n"
          pkg.Pkg_file.name;
        None)
  in
  loop [] pkgs

let sync_package config digest_dir =
  let target_dir = Filename.concat digest_dir "target" in
  if not (Sys.file_exists target_dir) then None
  else
    let dirname = Filename.basename digest_dir in
    match Pkg_file.parse_digest_dir dirname with
    | None ->
      Printf.eprintf "Warning: cannot parse directory name: %s\n" dirname;
      None
    | Some (name, _version, _digest) ->
      (* Hard-link target/ contents into switch prefix *)
      Hardlink.link_tree ~src:target_dir ~dst:config.Config.switch_dir
        ~same_device:config.same_device;
      (* Generate .install manifest *)
      let install =
        Install_file.generate_from_target ~pkg_name:name ~target_dir
      in
      Install_file.write ~switch_dir:config.switch_dir install;
      (* Copy cookie to locswijch metadata *)
      let cookie_src = Filename.concat target_dir "cookie" in
      if Sys.file_exists cookie_src then begin
        let cookie_dst_dir =
          List.fold_left Filename.concat config.switch_dir
            [ ".opam-switch"; "locswijch"; dirname ]
        in
        Hardlink.mkdir_p cookie_dst_dir;
        Hardlink.link_file ~src:cookie_src
          ~dst:(Filename.concat cookie_dst_dir "cookie")
          ~same_device:config.same_device
      end;
      Some name

let run switch_name project_root =
  let config = Config.resolve ~project_root ~switch_name in
  (* Validate *)
  if not (Sys.file_exists config.lock_dir) then begin
    Printf.eprintf "Error: No dune.lock/ directory found at %s\n" config.lock_dir;
    exit 1
  end;
  if not (Sys.file_exists config.build_pkg_dir) then begin
    Printf.eprintf
      "Error: No _build/.pkg/ directory found. Run dune build first.\n";
    exit 1
  end;
  (* Load package metadata from dune.lock *)
  let pkgs = Pkg_file.load_all ~lock_dir:config.lock_dir in
  let ocaml_pkg = Pkg_file.read_ocaml_pkg ~lock_dir:config.lock_dir in
  let live_set = live_digest_set ~project_root:config.project_root pkgs in
  let is_live entry =
    match live_set with None -> true | Some dirs -> List.mem entry dirs
  in
  (* Create switch skeleton *)
  ensure_switch_skeleton config.switch_dir;
  (* Sync each live package; prune digest dirs the current lock does not
     build (accumulated across migrate iterations, or restored from a
     switch synced before pruning existed) *)
  let entries = Sys.readdir config.build_pkg_dir in
  let synced_names = ref [] in
  let pruned_build = ref 0 in
  Array.iter
    (fun entry ->
      let full_path = Filename.concat config.build_pkg_dir entry in
      if Sys.is_directory full_path then
        if is_live entry then
          match sync_package config full_path with
          | Some name -> synced_names := name :: !synced_names
          | None -> ()
        else begin
          Hardlink.remove_tree full_path;
          incr pruned_build
        end)
    entries;
  (* Generate opam metadata *)
  let synced_pkgs =
    List.filter
      (fun pkg -> List.mem pkg.Pkg_file.name !synced_names)
      pkgs
  in
  Opam_gen.write_switch_config config synced_pkgs;
  Opam_gen.write_switch_state config synced_pkgs ~ocaml_pkg;
  List.iter (Opam_gen.write_package_opam config) synced_pkgs;
  Opam_gen.write_environment config synced_pkgs;
  Opam_gen.register_switch config;
  (* Back up dune.lock/ contents into switch metadata *)
  let locswijch_dir =
    List.fold_left Filename.concat config.switch_dir
      [ ".opam-switch"; "locswijch" ]
  in
  let lock_entries = Sys.readdir config.lock_dir in
  Array.iter
    (fun name ->
      let src = Filename.concat config.lock_dir name in
      if not (Sys.is_directory src) then
        Hardlink.link_file ~src
          ~dst:(Filename.concat locswijch_dir name)
          ~same_device:config.same_device)
    lock_entries;
  (* Prune stale digest dirs from the switch store so restore only brings
     back the live set. Top-level files are the dune.lock backup: keep. *)
  let pruned_switch = ref 0 in
  if live_set <> None then
    Array.iter
      (fun entry ->
        let full = Filename.concat locswijch_dir entry in
        if Sys.is_directory full && not (is_live entry) then begin
          Hardlink.remove_tree full;
          incr pruned_switch
        end)
      (Sys.readdir locswijch_dir);
  if !pruned_build > 0 || !pruned_switch > 0 then
    Printf.printf
      "Pruned stale digest dirs: %d from _build/.pkg/, %d from switch store\n"
      !pruned_build !pruned_switch;
  if not config.same_device then
    Printf.eprintf
      "Warning: _build and switch are on different devices. \
       Files were copied, not hard-linked.\n";
  Printf.printf "Synced %d packages to switch %s\n"
    (List.length !synced_names) config.switch_name
