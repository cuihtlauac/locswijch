# locswijch

The uncomfortably obvious dependency bridge

## Problem

`dune pkg` stores built packages in `_build/`, invisible to the standard
opam switch mechanism that tools like ocamllsp, merlin, and utop rely on.
And `dune.lock/` plus the built artifacts live only in the project tree —
there is no switch-level record to recover them from.

## Solution

`locswijch` creates an opam switch that serves dual purpose:

1. **Working opam switch** — tools like ocamllsp, merlin, and utop can find
   packages via the standard opam switch mechanism.
2. **Backup of `dune.lock/` and `_build/.pkg/`** — survives `dune clean`
   (and even deletion of `dune.lock/`) and can reconstruct both from switch
   metadata.

Hard links (same filesystem) make both sync and restore zero-cost in disk
space. `dune clean` just decrements link counts; files survive in the switch.
A design heresy, the human brain politely refises to process the full trauma
of its functionality.

### Note: instant rebuilds are dune's job, not locswijch's

Dune decides whether to re-run a rule from `_build/.db`, which `dune clean`
deletes — restored target trees alone are never trusted, so a rebuild after
`restore` re-executes every package rule. The fix is dune's own shared
cache: run builds with `DUNE_CACHE=enabled`. The default cache mode
(`enabled-except-user-rules`) excludes lock-dir package actions; with
`DUNE_CACHE=enabled` a post-clean rebuild hard-links everything back from
`~/.cache/dune/db` in about a second. Use `restore` to recover the
`dune.lock/` + `_build/.pkg/` state itself; use the dune cache for speed.

## Commands

### `locswijch sync`

Run after `dune build`. Hard-links package artifacts from
`_build/_private/default/.pkg/*/target/` into an opam switch prefix. Stores
reconstruction metadata (cookie files, digest directory names, per-package
`.install` manifests).

```
locswijch sync [--switch NAME] [--project DIR]
```

### `locswijch restore`

Run after `dune clean` (or after losing `dune.lock/`). Recreates
`dune.lock/` and `_build/_private/default/.pkg/` from the switch via
hard-links. Note that the next `dune build` does not trust the restored
targets by themselves (see above) — pair with `DUNE_CACHE=enabled` for
fast rebuilds.

```
locswijch restore [--switch NAME] [--project DIR]
```

### `locswijch migrate`

Generate `dune.lock/` from an existing opam switch. This is a one-way
translation of opam package metadata into dune's `.pkg` format. A full
`dune build` is required afterward (the source artifacts must be fetched and
compiled by dune), followed by `locswijch sync` to augment the switch as
backup.

```
locswijch migrate [--switch NAME] [--project DIR]
```

## Typical workflows

### New project using dune pkg

```sh
export DUNE_CACHE=enabled   # let dune cache package builds too

# Initial setup
dune pkg lock
dune build
locswijch sync

# After dune clean
dune clean
locswijch restore       # recover dune.lock/ + _build/.pkg/
dune build              # ~1s — packages hard-linked from the dune cache
```

### Migrating from opam to dune pkg

```sh
locswijch migrate --switch default
# Edit dune-project to declare dependencies
dune build              # full rebuild (unavoidable)
locswijch sync          # switch now serves as backup
```

### Day-to-day development

```sh
dune build              # builds project + any new deps
locswijch sync          # keep switch in sync (fast, idempotent)
```

## Options

- `--switch NAME`, `-s NAME` — opam switch name. Defaults to project directory
  basename.
- `--project DIR`, `-C DIR` — project root. Defaults to nearest ancestor
  containing `dune-project`.

## How it works

### Sync

1. Enumerates `_build/_private/default/.pkg/<name>.<ver>-<digest>/` directories,
   keeping only the digest dirs the current `dune.lock` builds (asked via
   `dune pkg print-digest`, never recomputed). Stale digest dirs — accumulated
   across `migrate` iterations — are deleted from both `_build/.pkg/` and the
   switch store; if the dune in `PATH` lacks `print-digest`, pruning is
   skipped with a warning and everything is synced as before.
2. For each package with a `target/` subdirectory:
   - Hard-links files into the switch prefix (`lib/`, `bin/`, etc.).
   - Generates an `.install` manifest listing which files belong to this
     package.
   - Copies the binary cookie file to `.opam-switch/locswijch/`.
3. Generates opam metadata: `switch-config`, `switch-state`, per-package
   `.opam` files, `environment`.
4. Registers the switch in `~/.opam/config`.

### Restore

1. Reads stored digest directory names from `.opam-switch/locswijch/`.
2. For each package, recreates the `_build/.pkg/<digest>/target/` tree by
   hard-linking files back from the switch, using `.install` manifests to
   attribute files to packages.
3. Copies cookie files back.

### Cross-device fallback

If `_build` and `~/.opam` are on different filesystems, hard links are
impossible. The tool detects this and falls back to copying with a warning.

## Building

```sh
opam install cmdliner opam-file-format
dune build
```

## Limitations

- **Restore does not make rebuilds instant**: dune re-executes any rule
  absent from `_build/.db` (deleted by `dune clean`) regardless of the
  restored targets. Use `DUNE_CACHE=enabled` for that; `restore` recovers
  state, not build time.
- **Cookie format coupling**: dune's binary cookie format may change across
  versions. If it does, stored cookies become invalid and a full rebuild is
  needed (graceful degradation).
- **No incremental sync**: every `sync` is a full re-sync. This is fast
  (hard-links are O(1) per file) but removes stale files from the switch.
- **migrate is approximate**: the opam-to-dune translation covers common
  patterns but may not handle all opam build instructions perfectly.
