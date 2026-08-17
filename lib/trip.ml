let step name f =
  Printf.printf "\n=== %s ===\n%!" name;
  f ()

let shell cmd =
  Printf.printf "$ %s\n%!" cmd;
  let code = Sys.command cmd in
  if code <> 0 then begin
    Printf.eprintf "FAIL: command exited with %d: %s\n" code cmd;
    exit 1
  end

let count_entries dir =
  if not (Sys.file_exists dir) then 0
  else Array.length (Sys.readdir dir)

let time_command cmd =
  let t0 = Unix.gettimeofday () in
  shell cmd;
  Unix.gettimeofday () -. t0

let run switch_name project_root =
  let config = Config.resolve ~project_root ~switch_name in
  Printf.printf "locswijch trip: round-trip test\n";
  Printf.printf "  project: %s\n" config.project_root;
  Printf.printf "  switch:  %s (%s)\n" config.switch_name config.switch_dir;
  Printf.printf "  device:  %s\n"
    (if config.same_device then "same (hard-links)" else "DIFFERENT (copies)");

  (* Step 1: migrate *)
  step "migrate: opam switch -> dune.lock/" (fun () ->
      Migrate.run switch_name project_root);

  let lock_file_count = count_entries config.lock_dir in
  Printf.printf "  lock files: %d\n" lock_file_count;

  (* Step 2: dune build. @install rather than @all: the host project's
     test/benchmark directories may need libraries outside the migrated
     closure, while the lock-dir base environment forces every locked
     package to build either way. DUNE_CACHE=enabled: lock-dir package
     actions count as user rules, which the default cache mode
     (enabled-except-user-rules) excludes; without this, step 6 cannot
     skip package rebuilds (dune re-executes any rule absent from
     _build/.db, which dune clean deletes, regardless of restored
     targets). *)
  step "dune build (full, from dune pkg)" (fun () ->
      let t = time_command
          (Printf.sprintf
             "cd %s && DUNE_CACHE=enabled opam exec -- dune build @install"
             (Filename.quote config.project_root))
      in
      Printf.printf "  build time: %.1fs\n" t);

  let pkg_count_before =
    if Sys.file_exists config.build_pkg_dir then
      count_entries config.build_pkg_dir
    else 0
  in
  Printf.printf "  packages in _build/.pkg/: %d\n" pkg_count_before;

  (* Step 3: sync *)
  step "sync: _build/.pkg/ -> switch" (fun () ->
      Sync.run switch_name project_root);

  let switch_lib_count = count_entries (Filename.concat config.switch_dir "lib") in
  Printf.printf "  lib dirs in switch: %d\n" switch_lib_count;

  (* Step 4: dune clean + rm dune.lock *)
  step "dune clean + rm -rf dune.lock/" (fun () ->
      shell
        (Printf.sprintf "cd %s && opam exec -- dune clean"
           (Filename.quote config.project_root));
      Hardlink.remove_tree config.lock_dir;
      assert (not (Sys.file_exists config.lock_dir));
      assert (not (Sys.file_exists config.build_pkg_dir));
      Printf.printf "  _build and dune.lock/ destroyed\n");

  (* Step 5: restore *)
  step "restore: switch -> dune.lock/ + _build/.pkg/" (fun () ->
      Restore.run switch_name project_root);

  (* Verify restoration *)
  let lock_file_count_after = count_entries config.lock_dir in
  let pkg_count_after =
    if Sys.file_exists config.build_pkg_dir then
      count_entries config.build_pkg_dir
    else 0
  in
  Printf.printf "  lock files restored: %d (was %d)\n"
    lock_file_count_after lock_file_count;
  Printf.printf "  packages restored: %d (was %d)\n"
    pkg_count_after pkg_count_before;
  if lock_file_count_after <> lock_file_count then begin
    Printf.eprintf "FAIL: lock file count mismatch\n";
    exit 1
  end;

  (* Step 6: dune build (should be near-instant via the shared cache) *)
  step "dune build (after restore, should skip package rebuilds)" (fun () ->
      let t = time_command
          (Printf.sprintf
             "cd %s && DUNE_CACHE=enabled opam exec -- dune build @install"
             (Filename.quote config.project_root))
      in
      Printf.printf "  build time: %.1fs\n" t);

  Printf.printf "\n=== TRIP COMPLETE ===\n";
  Printf.printf "All steps succeeded.\n"
