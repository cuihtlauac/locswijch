# Changelog

Completed backlog items, most recent first. See backlog.md for pending
work.

## Publish 0.1.0 to opam (2026-08-21)

First opam release. Added the missing opam-repository-required metadata
(description, dev-repo, x-maintenance-intent, maintainer as GitHub
handle — no email by choice) and a conventional CHANGES.md alongside
this session log; lint, build, and both test suites green. Tagged
v0.1.0, published the GitHub release, and verified the tarball. As
predicted by the opam-publish skill, the fine-grained PAT let
opam-publish fork and push `opam-publish-locswijch.0.1.0` but 403'd at
PR creation; the PR was opened with the classic-scoped gh CLI instead:
https://github.com/ocaml/opam-repository/pull/30532. Both token copies
(source file and opam-publish cache) deleted afterwards; PAT revocation
left to the human. opam-repo-ci results pending on the PR.

## Can locswijch back up ocaml.org PR 3281? (2026-08-18)

Answer: yes for the on-machine escape hatch, with one missing piece now
backlogged (toolchain compiler sync); no for ephemeral CI, where a new
export subcommand is the right shape (backlogged, judged feasible).
Investigated against a worktree of the PR branch (`dune_pkg`, head
d2b11f8). The PR does not commit `dune.lock/` — its Makefile and CI
relock every run against repos pinned in `dune-workspace`
(opam-repository 584630e + opam-overlays 2a95432), so any fallback needs
a committed lock or export artifact. Findings by sub-question: (1)
**Lock format**: `dune pkg lock` (dune 3.24.2) produced a 182-package
portable lock — flat `<name>.<version>.pkg` files, `all_platforms`
wrappers in 179 of them, `choice` with platform-set keys in 3 (conf-gmp,
conf-pkg-config, ocaml-base-compiler), `+dune` overlay versions for
ocamlfind/ocamlbuild, `extra_sources`, no package carrying `patches:`.
`Pkg_file.load_all` parses all 182 correctly (names, versions, deps
through `all_platforms`, sources, exported_env); build/install stay raw
sexps, which sync never interprets. New unit tests pin this with
verbatim fixtures from the real lock. (2) **Forward sync**: after
`dune build` of the web server target, sync landed all 182 packages in a
fresh empty switch (178 lib dirs, manifests, stub metadata; `opam
list`/`show` clean). One real bug found and fixed: opam caches
installed-package definitions in `.opam-switch/packages/cache`, and
`opam switch create --empty` writes it before sync populates the switch,
making opam report "No definition found" for a stale subset —
`ensure_switch_skeleton` now deletes that cache. (3) **Escape hatch**:
blocked as-is because the toolchain-built compiler leaves only a husk in
`_build/.pkg/` (binaries and stdlib live in `~/.cache/dune/toolchains/`)
— the synced switch has no `bin/ocaml*`/`lib/ocaml`, and builds pick up
the ambient compiler and fail on cmi version mismatches. Hard-linking
the toolchain target into the switch by hand made the full ocaml.org
build pass without `dune.lock/`, so the fix is mechanical (backlogged as
the new top item). Second constraint: the driving dune must be at least
the version that wrote the artifacts (a stray dune 3.20.1 on PATH
rejected `(lang dune 3.24)` dune-package files). (4) **Revert
scenario**: the switch is opam-visible but not opam-*operable* — any
solver action, even installing one leaf package, wants ~175
recompilations because stubs omit the compiler's virtual companions
(base-bigarray/base-domains/base-nnp, ocaml-options-vanilla), dune is
absent, and the repo swaps the +dune overlay versions for vanilla ones.
Recovery after a revert is therefore a fresh opam switch (or the
faithful-metadata item, now scoped with this probe data); the synced
switch's value is keeping development moving meanwhile. (5) **CI
fallback**: locswijch cannot help an ephemeral runner directly (synced
switches embed absolute paths), but a metadata-only export — lock to
`opam switch export` pin set, overlay versions as URL pins — is feasible
with the parsing already in place; backlogged. Scratch artifacts kept
for follow-ups: worktree `~/caml/ocamlorg-o3281` (PR checkout, lock,
1.7G build) and switch `locswijch-o3281` (synced, toolchain compiler
hand-linked in).

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
