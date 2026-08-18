# Backlog

Pending work items, one per heading, roughly in priority order. The first
item is the current task. See changelog.md for completed items.

## Sync the dune toolchain compiler into the switch

Found by the PR 3281 investigation (see changelog): when the locked
compiler is built as a dune *toolchain*, its binaries and stdlib live in
`~/.cache/dune/toolchains/<pkg>.<version>-<digest>/target/`, and the
compiler's `_build/.pkg/` digest dir contains only `cookie` and
`share/ocaml/config.cache`. A synced switch therefore has no
`bin/ocaml*` and no `lib/ocaml` — `opam exec --switch <synced> -- dune
build` picks up the ambient compiler and every library fails with "not a
compiled interface for this version of OCaml". Manually hard-linking the
toolchain `target/{bin,lib,man}` into the switch made the full ocaml.org
escape-hatch build pass, so sync should do exactly that when `lock.dune`
names a compiler package and its `.pkg` target is a husk. Open question:
how to identify the live toolchain dir (its digest differs from the
`.pkg` digest; the investigation used mtime). Also decide what the
compiler's `.install` manifest should cover so restore and pruning stay
coherent, and whether restore must guard against a trimmed toolchain
cache.

## Report dune cache/toolchain digest coherence bug upstream

Found during dream validation (2026-08-18): a locked package's digest
does not incorporate the toolchain identity. When the compiler's lock
entry changes (new toolchain digest) but a package's own .pkg text does
not, dune restores the stale cached artifact built against the old
toolchain and dependents fail with "inconsistent assumptions over
interface" (seen with dune-configurator/unix). Only recovery is wiping
~/.cache/dune/db. Minimal repro: migrate twice with a whitespace change
to the compiler's build command between runs. Cheap and self-contained;
do it while the details are fresh (redact local paths per publishing
rules).

## Export subcommand: dune.lock to pure-opam pin set (CI fallback)

Judged feasible by the PR 3281 investigation. A metadata-only
subcommand translating `dune.lock/` into an `opam switch export` file
(or `.opam.locked`-style depends) would give CI a secondary path with no
dune pkg and no build artifacts: `opam install --deps-only` pinned to
exactly the locked versions. Everything needed already parses:
`Pkg_file.load_all` reads name/version/source-url/checksum for the full
182-package ocaml.org closure; the 12 source-less packages are
conf-*/virtual ones that exist in opam-repository anyway. Overlay
versions (`ocamlfind.1.9.8+dune`, `ocamlbuild.0.16.1+dune`) don't exist
in opam-repository but their tarball URLs are in the lock, so emit them
as URL pins. Caveat to document: the export is only as good as the lock
it reads — ocaml.org's PR relocks in CI rather than committing
`dune.lock/`, so the fallback needs either a committed lock or a
committed export artifact refreshed by CI.

## Handle opam `patches:` in migrate

`patches:` appears nowhere in opam_read.ml. Neither validated closure
(ocaml-re + lts, dream + dream53) contains a patched package, so this
has not bitten yet; a closure with one would silently build unpatched.
Parse the field and emit the corresponding dune lock action (or at least
fail loudly). Prerequisite for the opam-overlays item below: overlay
`+dune` packages carry `patches:` plus extra sources, so overrides via
overlays would silently drop their patches without this.

## Thread installed set through opam_read without global state

`Opam_read.is_installed` is a mutable global ref set by
`read_package_opam`; the filter-evaluation work added a second one,
`host_vars`, with the same excuse (the string translators have "no room
to thread it through"). Refactor the translators to take a context
parameter. Doing this before the patches/overlays work keeps that rework
of opam_read from compounding the debt.

## Generalize package overrides via opam-overlays

`Migrate.apply_overrides` hardcodes fixes for ocamlfind (relocation,
$PREFIX make-escape, baked conf path) and ocamlbuild (baked -where
libdir) — both grown during the dream closure validation. Dune's own
lock flow uses patched `+dune` packages from ocaml-dune/opam-overlays.
When an overlay exists for a package/version, migrate could use the
overlay's build/install instructions instead of the vanilla ones —
replacing per-package special cases with the community-maintained set.
Depends on `patches:` support (above). Also shrinks the embedded-paths
problem (below): the overlay ocamlfind is properly relocatable.

## Validate opam operations against a synced switch

The round trip proves a synced switch serves locswijch (restore,
migrate) and day-to-day builds, but no test exercises it *through opam*:
`opam install <pkg>` into it, `opam list`, `opam remove`. With authentic
per-package metadata (opam-born switches) this should plausibly work;
verify against the lts/dream53 references — possibly as a trip
extension. The PR 3281 investigation already probed the *stub-metadata*
(dune-pkg-born) case: `opam list`/`opam show` work, but any solver
operation (even `opam install sexplib0 --dry-run`) cascades into ~175
recompilations because the stubs omit the compiler's virtual companions
(base-bigarray, base-domains, base-nnp, ocaml-options-vanilla), dune
itself is not in the lock, and the repo offers upgrades/downgrades
(ocaml-version, the +dune overlay pair). The opam-born case remains to
be probed.

## Faithful opam metadata for locswijch-created packages

`Opam_gen.translate_build_action` produces "a simplified representation"
(its own comment) and `write_package_opam` writes stubs without install
sections. A switch created by locswijch from scratch (pure dune-pkg
project, no prior opam metadata) therefore cannot be migrated back.
Translate the lock file's build/install/depends fully so the round trip
also works for switches locswijch itself created. The PR 3281 probe
scoped the quick wins: to make the opam solver leave a stub switch
alone, also emit the compiler's virtual companions (base-bigarray,
base-domains, base-nnp, ocaml-options-vanilla) — cheap empty packages —
and a maintainer field (`opam lint` error 23 on every stub today).
Build/install translation from portable locks additionally has to
unpack `all_platforms`/`choice` wrappers, which `opam_gen` currently
reduces to a `platform-specific-build` placeholder.

## Detect embedded _build/cache paths in synced switches

A synced switch is not self-contained: some installed files embed
absolute paths into the project's `_build/` or `~/.cache/dune/`
(ocamlfind's findlib.conf points its stdlib entry at the dune toolchain
dir; the binary's baked conf path points into `_build/.pkg/`). Hard
links keep the switch's *files* alive after `dune clean`, but embedded
paths only stay valid while restore recreates `_build` and the toolchain
cache survives trimming. Sync could scan the payload for references to
`_build`/`~/.cache/dune` and warn (or eventually rewrite), so the
dependency is visible instead of a latent breakage. Revisit after the
overlays item: the overlay ocamlfind removes the worst offender.

## Warn when the dune cache cannot hard-link across devices

Found while building the smoke test: with `DUNE_CACHE=enabled`, the
default storage mode hard-links cache entries, which fails silently when
the project and `~/.cache/dune` are on different filesystems (e.g.
project on tmpfs) — the post-restore rebuild then re-runs every package
build with no error. `DUNE_CACHE_STORAGE_MODE=copy` fixes it. trip (and
the README's instant-rebuild story) could detect the device mismatch and
warn or set the storage mode.

## Derive lock.dune repositories from the switch

`Migrate.write_lock_dune` hardcodes
`https://github.com/ocaml/opam-repository.git`. Read the switch's actual
repository selections (e.g. pins, custom repos) and emit those instead.
Niche until a closure with pins or custom repos is attempted.

## Cookie format version guard

README limitation: dune's binary cookie format may change across dune
versions; stored cookies would then be invalid. Detect the dune version
(or catch cookie rejection) at restore time and degrade gracefully with a
clear message instead of a confusing build failure. Speculative until a
dune release actually changes the format.
