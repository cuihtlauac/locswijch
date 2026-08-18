# Changelog

Completed backlog items, most recent first. See backlog.md for pending
work.

## Publish to GitHub with MIT license (2026-08-18)

Created cuihtlauac/locswijch (public), pushed full history after checking
it for machine-identifying content. Added LICENSE (MIT) and aligned the
opam file's license field, which previously said ISC.

## Make the round trip idempotent and instant (2026-08-17)

Post-restore rebuild was 259s; root cause is that dune re-executes any
rule absent from `_build/.db` (deleted by `dune clean`) regardless of
restored targets, and the default cache mode excludes lock-dir package
actions from the shared cache. trip now sets `DUNE_CACHE=enabled`
(step 6: 0.8s); README reframes restore as state recovery. Validation
exposed that sync's `write_package_opam` overwrote the switch's
authoritative opam metadata with stubs, breaking every migrate after the
first — it now never overwrites an existing opam file. Two consecutive
trips pass.

## Make trip pass end-to-end on ocaml-re + lts (2026-08-17)

Five migrate fixes found by running the round trip against a real 32-
package closure: dependency disjunctions were dropped; {post} deps caused
lock cycles; flat build commands with filtered atoms parsed as empty;
depopts were ignored; %{pkg:installed}% always resolved to true. Plus a
relocatable-ocamlfind override (configure -with-relative-paths-at) to
survive dune's copy sandbox, and trip builds @install instead of @all.

## Resolve the dune directory-symlink impediment (2026-08-17)

dune #9873 (Unexpected file kind "S_DIR" on ocamlbuild's tarball) was
fixed upstream by PR #13792, released in dune 3.24.0. Verified with the
minimal repro and the real ocamlbuild-0.16.1 tarball; upgraded the
default switch to OCaml 5.5.0 + dune 3.24.2 and updated the report
(dune-directory-symlinks.md).
