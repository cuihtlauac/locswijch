# Backlog

Pending work items, one per heading, roughly in priority order. The first
item is the current task. See changelog.md for completed items.

## Generalize package overrides via opam-overlays

`Migrate.apply_overrides` hardcodes fixes for ocamlfind (relocation,
$PREFIX make-escape, baked conf path) and ocamlbuild (baked -where
libdir) — both grown during the dream closure validation. Dune's own
lock flow uses patched `+dune` packages from ocaml-dune/opam-overlays.
When an overlay exists for a package/version, migrate could use the
overlay's build/install instructions instead of the vanilla ones —
replacing per-package special cases with the community-maintained set.

## Handle opam `patches:` in migrate

`patches:` appears nowhere in opam_read.ml. Neither validated closure
(ocaml-re + lts, dream + dream53) contains a patched package, so this
has not bitten yet; a closure with one would silently build unpatched.
Parse the field and emit the corresponding dune lock action (or at least
fail loudly).

## Report dune cache/toolchain digest coherence bug upstream

Found during dream validation: a locked package's digest does not
incorporate the toolchain identity. When the compiler's lock entry
changes (new toolchain digest) but a package's own .pkg text does not,
dune restores the stale cached artifact built against the old toolchain
and dependents fail with "inconsistent assumptions over interface"
(seen with dune-configurator/unix). Only recovery is wiping
~/.cache/dune/db. Minimal repro: migrate twice with a whitespace change
to the compiler's build command between runs.

## Faithful opam metadata for locswijch-created packages

`Opam_gen.translate_build_action` produces "a simplified representation"
(its own comment) and `write_package_opam` writes stubs without install
sections. A switch created by locswijch from scratch (pure dune-pkg
project, no prior opam metadata) therefore cannot be migrated back.
Translate the lock file's build/install/depends fully so the round trip
also works for switches locswijch itself created.

## Derive lock.dune repositories from the switch

`Migrate.write_lock_dune` hardcodes
`https://github.com/ocaml/opam-repository.git`. Read the switch's actual
repository selections (e.g. pins, custom repos) and emit those instead.

## Cookie format version guard

README limitation: dune's binary cookie format may change across dune
versions; stored cookies would then be invalid. Detect the dune version
(or catch cookie rejection) at restore time and degrade gracefully with a
clear message instead of a confusing build failure.

## Warn when the dune cache cannot hard-link across devices

Found while building the smoke test: with `DUNE_CACHE=enabled`, the
default storage mode hard-links cache entries, which fails silently when
the project and `~/.cache/dune` are on different filesystems (e.g.
project on tmpfs) — the post-restore rebuild then re-runs every package
build with no error. `DUNE_CACHE_STORAGE_MODE=copy` fixes it. trip (and
the README's instant-rebuild story) could detect the device mismatch and
warn or set the storage mode.

## Thread installed set through opam_read without global state

`Opam_read.is_installed` is a mutable global ref set by
`read_package_opam` because the string translators have "no room to
thread it through" (its own comment). Refactor the translators to take a
context parameter.
