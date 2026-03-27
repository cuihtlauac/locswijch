let restore_package config digest_dirname =
  let locswijch_dir =
    List.fold_left Filename.concat config.Config.switch_dir
      [ ".opam-switch"; "locswijch"; digest_dirname ]
  in
  match Pkg_file.parse_digest_dir digest_dirname with
  | None ->
    Printf.eprintf "Warning: cannot parse digest dir: %s\n" digest_dirname;
    false
  | Some (name, _version, _digest) ->
    let target_dir =
      Filename.concat
        (Filename.concat config.build_pkg_dir digest_dirname)
        "target"
    in
    Hardlink.mkdir_p target_dir;
    (* Read .install manifest to know which switch files belong to this pkg *)
    let install_path =
      List.fold_left Filename.concat config.switch_dir
        [ ".opam-switch"; "install"; name ^ ".install" ]
    in
    if not (Sys.file_exists install_path) then begin
      Printf.eprintf "Warning: no .install file for %s, skipping\n" name;
      false
    end
    else begin
      let install = Install_file.load install_path in
      (* For each entry in the manifest, hard-link from switch into target/ *)
      List.iter
        (fun (section : Install_file.section) ->
          List.iter
            (fun (entry : Install_file.entry) ->
              let src = Filename.concat config.switch_dir entry.src in
              let dst = Filename.concat target_dir entry.src in
              if Sys.file_exists src then
                Hardlink.link_file ~src ~dst ~same_device:config.same_device)
            section.entries)
        install.sections;
      (* Restore cookie *)
      let cookie_src = Filename.concat locswijch_dir "cookie" in
      let cookie_dst = Filename.concat target_dir "cookie" in
      if Sys.file_exists cookie_src then
        Hardlink.link_file ~src:cookie_src ~dst:cookie_dst
          ~same_device:config.same_device;
      true
    end

let run switch_name project_root =
  let config = Config.resolve ~project_root ~switch_name in
  (* Validate *)
  let locswijch_dir =
    List.fold_left Filename.concat config.switch_dir
      [ ".opam-switch"; "locswijch" ]
  in
  if not (Sys.file_exists locswijch_dir) then begin
    Printf.eprintf
      "Error: No locswijch metadata found in switch %s.\n\
       Run locswijch sync first.\n"
      config.switch_name;
    exit 1
  end;
  (* Restore dune.lock/ if missing *)
  if not (Sys.file_exists config.lock_dir) then begin
    Printf.printf "Restoring dune.lock/ from switch metadata...\n";
    Hardlink.mkdir_p config.lock_dir;
    let entries = Sys.readdir locswijch_dir in
    let lock_files = ref 0 in
    Array.iter
      (fun name ->
        let src = Filename.concat locswijch_dir name in
        if not (Sys.is_directory src) then begin
          Hardlink.link_file ~src
            ~dst:(Filename.concat config.lock_dir name)
            ~same_device:config.same_device;
          incr lock_files
        end)
      entries;
    Printf.printf "Restored dune.lock/ (%d files)\n" !lock_files
  end;
  (* Ensure _build structure exists *)
  Hardlink.mkdir_p config.build_pkg_dir;
  (* Read stored digest directory names *)
  let digest_dirs = Sys.readdir locswijch_dir in
  let restored = ref 0 in
  Array.iter
    (fun dirname ->
      let full = Filename.concat locswijch_dir dirname in
      if Sys.is_directory full then
        if restore_package config dirname then incr restored)
    digest_dirs;
  if not config.same_device then
    Printf.eprintf
      "Warning: different devices — files were copied, not hard-linked.\n";
  Printf.printf "Restored %d packages from switch %s\n" !restored
    config.switch_name
