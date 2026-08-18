# locswijch

OCaml CLI tool bridging dune pkg and opam switches via hard links.

## Build

```sh
opam exec -- dune build @all
```

## Test

```sh
opam exec -- dune runtest
```

Two suites: `test/unit/` (sexp_parser + opam_read parsing, incl. the
disjunction/{post}/depopts/flat-command/%{pkg:installed}% fixes and
host-side os/arch filter evaluation) and
`test/smoke/` (full trip cycle against a generated two-package fixture
closure in a temp dir — no compiler in the lock, so it uses the ambient
toolchain; hermetic dune cache via XDG_CACHE_HOME; the post-restore
rebuild must beat a threshold a real package rebuild cannot meet). The
smoke test needs `opam` and `dune` on PATH.

Manual testing against a real switch:

```sh
# Requires a project with dune.lock/ and built packages in _build/.pkg/
opam exec -- dune exec ./bin/main.exe -- sync --project /path/to/project
opam exec -- dune exec ./bin/main.exe -- restore --project /path/to/project
opam exec -- dune exec ./bin/main.exe -- migrate --switch default --project /path/to/project

# End-to-end round trip: migrate, build, sync, clean+rm dune.lock, restore,
# rebuild. Destroys the target project's _build/ and dune.lock/ and overwrites
# the switch. Reference setups: --switch lts --project ~/caml/ocaml-re
# (32 pkgs, OCaml 4.14) and --switch dream53 --project ~/caml/dream
# (144 pkgs, OCaml 5.3, conf-*/topkg/mirage). The dune on PATH orchestrates
# the locked builds (trip deliberately avoids `opam exec` on the target
# project, which would pick up its local _opam); it must support the locked
# dune's lang version.
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
test/unit/           Parser unit tests (sexp_parser, opam_read)
test/smoke/          End-to-end trip against a generated fixture closure
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
