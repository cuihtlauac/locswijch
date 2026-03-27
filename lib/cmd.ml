open Cmdliner

let sync_term =
  let doc = "Sync dune pkg artifacts into an opam switch (hard-links)." in
  let info = Cmd.info "sync" ~doc in
  Cmd.v info
    Term.(const Sync.run $ Config.switch_arg $ Config.project_arg)

let restore_term =
  let doc = "Restore dune pkg artifacts from an opam switch after dune clean." in
  let info = Cmd.info "restore" ~doc in
  Cmd.v info
    Term.(const Restore.run $ Config.switch_arg $ Config.project_arg)

let migrate_term =
  let doc =
    "Generate dune.lock/ from an existing opam switch. \
     Requires dune build + locswijch sync afterward."
  in
  let info = Cmd.info "migrate" ~doc in
  Cmd.v info
    Term.(const Migrate.run $ Config.switch_arg $ Config.project_arg)

let trip_term =
  let doc =
    "Full round-trip test: migrate, build, sync, clean+rm dune.lock, \
     restore, build. Verifies the entire workflow end-to-end."
  in
  let info = Cmd.info "trip" ~doc in
  Cmd.v info
    Term.(const Trip.run $ Config.switch_arg $ Config.project_arg)

let cmd () =
  let doc = "Bidirectional bridge between dune pkg and opam switches." in
  let info = Cmd.info "locswijch" ~version:"0.1.0" ~doc in
  Cmd.group info [ sync_term; restore_term; migrate_term; trip_term ]
