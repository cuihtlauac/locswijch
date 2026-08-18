# locswijch

OCaml CLI tool bridging dune pkg and opam switches via hard links.

## Build

```sh
opam exec -- dune build @all
```

## Test

No test suite yet. Manual testing:

```sh
# Requires a project with dune.lock/ and built packages in _build/.pkg/
opam exec -- dune exec ./bin/main.exe -- sync --project /path/to/project
opam exec -- dune exec ./bin/main.exe -- restore --project /path/to/project
opam exec -- dune exec ./bin/main.exe -- migrate --switch default --project /path/to/project

# End-to-end round trip: migrate, build, sync, clean+rm dune.lock, restore,
# rebuild. Destroys the target project's _build/ and dune.lock/ and overwrites
# the switch. Reference setup: --switch lts --project ~/caml/ocaml-re
opam exec -- dune exec ./bin/main.exe -- trip --switch lts --project /path/to/project
```

## Architecture

```
bin/main.ml          CLI entry point, delegates to Locswijch.Main.run
lib/cmd.ml           Cmdliner subcommand definitions (sync, restore, migrate, trip)
lib/main.ml          Top-level dispatch
lib/config.ml        Path resolution: project root, _build/.pkg/, dune.lock/,
                     switch dir, same-device detection
lib/sexp_parser.ml   Lightweight S-expression parser for dune .pkg files
lib/pkg_file.ml      Parse dune.lock/*.pkg into structured records
lib/install_file.ml  Generate and parse .install manifests (file-to-package mapping)
lib/opam_gen.ml      Generate opam switch metadata (switch-config, switch-state,
                     per-package opam files, environment)
lib/opam_read.ml     Parse opam switch metadata (for migrate command)
lib/hardlink.ml      Hard-link with cross-device copy fallback, recursive tree ops
lib/sync.ml          Sync command: _build/.pkg/ -> opam switch
lib/restore.ml       Restore command: opam switch -> _build/.pkg/
lib/migrate.ml       Migrate command: opam switch -> dune.lock/
lib/trip.ml          Trip command: end-to-end round-trip test
```

## Key design decisions

- **Pkg_digest directory names are stored verbatim**, never recomputed. Avoids
  coupling to dune's internal digest algorithm. Liveness (which digest dir the
  current dune.lock builds) is asked from `dune pkg print-digest`; sync prunes
  the rest from `_build/.pkg/` and the switch store, or skips pruning with a
  warning if the command is unavailable.
- **Cookie files are opaque binary blobs**, copied as-is. No dependency on
  dune's Persistent serialization module.
- **Full re-sync every time** (idempotent). Hard links make this cheap.
- **opam-file-format** is used for parsing opam files (migrate) but opam
  metadata is generated as plain text (simpler, fewer API surface concerns).

## Dependencies

- `cmdliner` — CLI argument parsing
- `opam-file-format` — parse opam files in migrate command
- `unix` — hard links, stat, symlinks
