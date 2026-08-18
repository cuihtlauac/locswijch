# Backlog

Pending work items, one per heading, roughly in priority order. The first
item is the current task. See changelog.md for completed items.

## Prune stale package digest dirs in sync

`_build/_private/default/.pkg/` accumulates digest directories across
migrate iterations (observed: 87 dirs for 32 live packages after a few
trip runs). Sync faithfully mirrors all of them into the switch, so the
switch store grows too, and restore brings them all back. Sync should
prune digests absent from the current `dune.lock/` — from both the switch
store and (optionally) `_build/.pkg/`.

## Scripted smoke test

CLAUDE.md says "no test suite yet"; the only end-to-end check is the
manual `trip` against `--switch lts --project ~/caml/ocaml-re`, which
needs a prepared switch and project. Add a self-contained smoke test that
builds a tiny fixture closure (one or two trivial packages), runs the
trip cycle, and asserts the post-restore build stays under a threshold.
Unit tests for `sexp_parser` and `opam_read` (disjunctions, {post},
depopts, flat commands, %{pkg:installed}%) would pin the parser fixes.

## Broaden migrate coverage to a second closure

All migrate validation so far is one closure (ocaml-re + lts, 32
packages, OCaml 4.14.2). Run trip against a larger or differently-shaped
switch — dune-heavy packages, `conf-*` system packages, packages with
patches/substs — to flush out the next tier of opam-to-dune translation
gaps.

## Generalize package overrides via opam-overlays

`Migrate.apply_overrides` hardcodes the ocamlfind fix. Dune's own lock
flow uses patched `+dune` packages from ocaml-dune/opam-overlays. When an
overlay exists for a package/version, migrate could use the overlay's
build/install instructions instead of the vanilla ones — replacing
per-package special cases with the community-maintained set.

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

## Thread installed set through opam_read without global state

`Opam_read.is_installed` is a mutable global ref set by
`read_package_opam` because the string translators have "no room to
thread it through" (its own comment). Refactor the translators to take a
context parameter.
