# Changes

## 0.1.1 (2026-08-25)

- Ship a package documentation landing page (`doc/index.mld` via a
  `documentation` stanza) so `ocaml.org/p/locswijch` renders an overview
  instead of "No Docs". No API is published — locswijch installs only an
  executable.

## 0.1.0 (2026-08-21)

Initial release.

- `sync`: mirror `dune pkg` build artifacts (`_build/.pkg/`) into a real
  opam switch via hard links, so ocamllsp, merlin, and utop find packages
  through the standard switch mechanism.
- `restore`: reconstruct `dune.lock/` and `_build/.pkg/` from the switch,
  surviving `dune clean` and even deletion of the lock directory.
- `migrate`: generate `dune.lock/` from an existing opam switch, including
  static evaluation of opam filters against the host.
- `trip`: end-to-end round-trip test (migrate, build, sync, clean, restore,
  rebuild) with a rebuild-time threshold.
- Stale package digest directories are pruned using `dune pkg print-digest`.
- Parses both the classic and the portable (`all_platforms`/`choice`)
  `dune pkg lock` formats; validated against 32- and 144-package closures
  and a 182-package ocaml.org lock.
