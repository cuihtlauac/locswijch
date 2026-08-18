# Changelog

Completed backlog items, most recent first. See backlog.md for pending
work.

## Broaden migrate coverage to a second closure (2026-08-18)

New reference: dream + dream53 (144 packages, OCaml 5.3.0 — conf-*
system packages, C stubs, ppxlib, topkg/ocamlbuild packages, mirage
stack, caqti pinned <3 to match dream's source). Two consecutive trips
pass (post-restore 3.1s) and ocaml-re + lts still passes. Fixes, in
failure order: (1) opam filters are now statically evaluated against the
host (os/arch/os-* from `opam var`, with-test/with-doc false,
three-valued logic; unknown filters keep commands and deps, drop atoms)
— fixes conf-* build commands running their macos/win32 branches and
filtered atoms vanishing from flat commands; (2) lock-file command atoms
are quoted when needed (conf-gmp's `sh -c "a || b"` was emitted
unquoted); (3) trip and sync invoke plain `dune`, not `opam exec --
dune`, which resolved the switch from the target project's cwd — dream's
local _opam supplied dune 3.22, too old for lang 3.24 satellite packages
and missing the #9873 S_DIR fix; (4) the ocamlfind override now escapes
$PREFIX in Makefile.config (vanilla configure writes it unescaped, make
eats "$P" → "REFIX/lib" search path) and bakes the post-sandbox conf
path into the binary while still installing into the sandbox; (5) new
ocamlbuild override, same shape (bake final -where libdir at compile,
override paths back to the sandbox at install) — without it topkg
packages (mtime, ptime) can't compile myocamlbuild plugins. Findings
backlogged: `patches:` still unhandled (no closure exercises it), and a
dune cache coherence bug — package digests don't include the toolchain
identity, so changing the compiler's lock entry poisons cache hits of
unchanged packages ("inconsistent assumptions over interface Unix");
recovery is wiping ~/.cache/dune/db.

## Scripted smoke test and parser unit tests (2026-08-18)

`dune runtest` now covers the tool. test/unit/ pins the five parser
fixes through the public read_package_opam API (disjunctions, {post},
depopts, flat filtered commands, %{pkg:installed}%) plus sexp_parser.
test/smoke/ generates a two-package fixture closure (file:// directory
sources, no compiler — dune falls back to the ambient toolchain) and
runs the full trip cycle in a temp dir; trip gained `--threshold` and
the fixture's sleep-5 build makes it discriminating: post-restore must
skip package rebuilds (0.1s) to pass. Two findings: locked packages only
build when rules consume them unless the toolchain itself comes from the
lock (fixture packages install tools that project rules run), and the
dune cache's default hardlink storage fails silently across devices
(smoke is hermetic via XDG_CACHE_HOME; warning idea backlogged).

## Prune stale package digest dirs in sync (2026-08-18)

Digest dirs accumulated across migrate iterations (81 for 32 live
packages on ocaml-re + lts) because sync mirrored everything and restore
brought it all back. The lock dir carries no digests and duplicates share
name and version, so liveness is asked from `dune pkg print-digest`
(~70ms/package), never recomputed. Sync now syncs only live digest dirs —
also fixing a nondeterministic last-wins overwrite of prefix files and
.install manifests among same-name duplicates — and deletes stale dirs
from both `_build/.pkg/` and the switch store (81 → 32); if dune lacks the
subcommand it warns and skips pruning. Stale `.install` files are left
alone: on a real opam switch they belong to opam-installed packages. Two
consecutive trips pass with counts stable at 32.

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
