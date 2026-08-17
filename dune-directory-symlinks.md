# Directory Symlinks in Dune: Bug Report

## Summary

Dune rejects directory symlinks in three contexts: directory targets produced
by rules, package source archives, and package installation targets. The error
is `Unexpected file kind "S_DIR" (directory)`. This affects real-world packages
such as `ocamlbuild` (whose source tarball contains a symlink to a directory)
and the relocatable compiler (whose installation layout includes symlinks).

**Tracked as:** [ocaml/dune#9873](https://github.com/ocaml/dune/issues/9873)
(**closed 2026-05**, was assigned to Ambre Austen Suhamy)

**Resolution (update 2026-08-17):** the package-source cases (2, 3, 4) were
fixed upstream by PR [#13792](https://github.com/ocaml/dune/pull/13792)
("[pkg] Resolve directory symlinks in fetched targets", merged 2026-05-06),
released in **dune 3.24.0** (2026-06-21). It implements Option A below:
after fetching package sources, directory symlinks are resolved into real
directories (file symlinks are left as-is, broken symlinks silently removed).
Verified locally on 2026-08-17 with both the minimal Case-3 repro and the
real `ocamlbuild-0.16.1` tarball: fail on dune 3.23.1, succeed on 3.24.2.
The rule-produced directory-target case (Case 1) remains unfixed and is now
tracked as [#9874](https://github.com/ocaml/dune/issues/9874); it does not
affect locswijch. See "Current State" below.

## How to Reproduce

### Case 1: Directory target containing a directory symlink

A rule produces a directory target that includes a symlink pointing to a
subdirectory.

```
$ cat > dune-project << EOF
(lang dune 3.0)
(using directory-targets 0.1)
EOF

$ cat > dune << EOF
(rule
 (target (dir d))
 (action
  (progn
   (run mkdir -p d)
   (chdir d
    (progn
     (run mkdir a)
     (run touch a/x.txt)
     (run ln -s a b))))))
EOF

$ dune build d
Error: Error trying to read targets after a rule was run:
- d/b: Unexpected file kind "S_DIR" (directory)
```

Test file: `test/blackbox-tests/test-cases/directory-targets/symlink-dir.t`

### Case 2: Local directory source containing a directory symlink

A package source is a local directory that contains a symlink to a
subdirectory. The copy phase fails.

```
$ mkdir _src && mkdir _src/real_dir
$ echo "content" > _src/real_dir/file.txt
$ ln -s real_dir _src/link_to_dir

# In dune.lock/foo.pkg:
# (source (fetch (url file://$PWD/_src)))
# (build (run cat real_dir/file.txt))

$ dune build
Error: Is a directory
-> required by .../source/link_to_dir
```

Only the real directory is partially copied; the symlink is dropped entirely.

### Case 3: Tarball source containing a directory symlink

A package source is a tarball containing a symlink to a directory. Tar
extraction preserves the symlink, but the subsequent digest computation
rejects it.

This is the `ocamlbuild` case. The tarball `ocamlbuild-0.16.1.tar.gz`
contains:

```
lrwxrwxrwx  examples/07-dependent-projects/libdemo -> ../04-library/libdemo
```

```
$ dune build
Error: Error trying to read targets after a rule was run:
- .../source/link_to_dir: Unexpected file kind "S_DIR" (directory)
```

The tarball is fully extracted (symlink preserved), but validation fails.

### Case 4: Downloaded tarball with checksum

Same as Case 3 but with a checksum. The error occurs during checksum
validation, before the source is made available to the build.

```
Error: Error trying to read targets after a rule was run:
- checksum/md5=HASH/dir/link_to_dir: Unexpected file kind "S_DIR" (directory)
```

### Case 5: Package install target containing a directory symlink

A package's build/install action creates a directory symlink inside the target
prefix (e.g., in `%{lib}/%{pkg-self:name}/`). The engine rejects it when
computing the target digest.

Test file: `test/blackbox-tests/test-cases/pkg/install-symlinks/dir-symlink.t`

All five cases are documented in dune's test suite with `CR-someday alizter`
comments indicating known failures.

## Root Cause

The digest computation in `src/dune_digest/digest.ml` (function
`path_with_stats_internal`) has two layers:

**Outer entry point** (line 289):
```ocaml
match stats.st_kind with
| S_DIR when not allow_dirs -> Error Unexpected_kind
| S_BLK | S_CHR | S_LNK | S_FIFO | S_SOCK -> Error Unexpected_kind
| _ -> loop path stats
```

`S_LNK` is rejected before entering the recursive loop. This means
**all symlinks are rejected at the top level**, regardless of what they
point to.

**Recursive loop** (lines 247-253):
```ocaml
| S_LNK ->
  let contents = Path.to_string path |> Unix.readlink |> string_digest in
  path_with_executable_bit ~executable:stats.executable ~content_digest:contents
```

Inside the loop (reached only when traversing a directory's contents),
symlinks are handled by digesting the `readlink` target string. But when
the symlink points to a directory, `lstat` returns `S_LNK` and the loop
digests the target path string — which works. The problem is that the outer
entry point prevents reaching this code path.

**The mismatch:** `lstat` reports the symlink itself (`S_LNK`), but the error
message says `"S_DIR" (directory)` because some code paths use `stat` (which
follows the symlink) for the error message while using `lstat` for the
rejection decision. This makes the error confusing.

**Call chain for Case 3 (tarball):**

1. `archive_driver.ml:extract()` — extracts tar, symlinks preserved
2. `path_digest.ml:digest_with_lstat()` — called on extracted source
3. `digest.ml:path_with_stats_internal()` — line 289 rejects `S_LNK`
4. `cached_digest.ml` — propagates error
5. `shared.ml:compute_target_digests_or_raise_error()` — formats user error

## History

**2022-07-03** — Issue [#5945](https://github.com/ocaml/dune/issues/5945):
first report of symlinks in directory targets. Fixed by PR #6077 (dune 3.5),
which allowed `S_LNK` in directory target contents. This fix handles
**file** symlinks inside directories but not directory symlinks.

**2024-01-31** — Issue [#9873](https://github.com/ocaml/dune/issues/9873)
opened by Etienne Millon. Regression traced to commit `b1c339b` in PR #9407.
Specifically about directory symlinks (symlinks whose target is a directory).

**2024-02-01** — Commit `e06a128a5`: test case `symlink-dir.t` added to
reproduce #9873.

**2024-12-09** — PR [#9937](https://github.com/ocaml/dune/pull/9937) merged
(Etienne Millon). Fixes `Cached_digest.refresh` to allow symlink dirs. Partial
fix — addresses caching but not the source extraction path.

**2024-12-10** — PR [#10426](https://github.com/ocaml/dune/pull/10426)
(Leonidas-from-XIV) closed. Proposed removing the `S_LNK` restriction
entirely. Closed because "supporting directory symlinks inside directory
targets might need more thinking and design than we can spare at the moment."
Design concerns raised: absolute symlink portability, broken symlinks, symlinks
pointing outside the workspace.

**2025-03-10** — Issue [#11523](https://github.com/ocaml/dune/issues/11523)
opened (Etienne Millon). Related: symlinks in directory targets prevent shared
cache hits. Rules with symlinks are re-executed every time instead of cached.
Affects real packages (e.g., `ocp-indent.1.8.1`).

**2026-01-02** — Commit `3ff06172a`: `resolve_symlinks_in` function added in
`pkg_rules.ml` (Ali Caglayan). Resolves **file** symlinks in package
installations by replacing them with hardlinks. Directory symlinks are silently
ignored:
```ocaml
| Ok resolved ->
  match Unix.lstat resolved with
  | { st_kind = S_REG; _ } ->
    Fpath.unlink_exn path;
    Io.portable_hardlink ~src ~dst
  | _ -> ()   (* directory symlinks: ignored *)
```

**2026-01-20** — PR [#13239](https://github.com/ocaml/dune/pull/13239)
merged (Ali Caglayan). The `resolve_symlinks_in` fix for install actions.
Reviewed by Rudi Grinberg. Noted concern: converting external symlinks to
hardlinks creates implicit dependencies on external content.

**2026-01-20** — Commit `3aa0734db`: test `source-with-directory-symlink.t`
added (Ali Caglayan), documenting all three source-related failure modes
with `CR-someday` comments.

**2026-05-06** — PR [#13792](https://github.com/ocaml/dune/pull/13792)
merged: "[pkg] Resolve directory symlinks in fetched targets". After fetching
package sources, a pass resolves directory symlinks into real directories.
File symlinks are left as-is; broken symlinks are removed silently. This is
Option A below.

**2026-05-07** — Issue #9873 **closed**. The remaining unfixed part —
directory symlinks in rule-produced directory targets (Case 1) — is tracked
in [#9874](https://github.com/ocaml/dune/issues/9874). Maintainers note that
practical occurrences can also be patched in dune's pkg overlays, as was done
for ocamlbuild.

**2026-06-21** — dune **3.24.0** released, carrying the fix.

## Current State

*(updated 2026-08-17)*

- The package-source cases (2, 3, 4) are **fixed** in dune >= 3.24.0
  (PR #13792). Verified locally against dune 3.24.2 with the minimal repro
  and the real `ocamlbuild-0.16.1` tarball; both still fail on 3.23.1.
- Case 1 (rule-produced directory targets) remains **open** as #9874.
- Case 5 (install targets): file symlinks are converted to hardlinks during
  install (PR #13239); directory symlinks in install targets are silently
  ignored.
- The shared-cache interaction (#11523) is unaffected by #13792 (status not
  re-checked).

## Fix Design Options

### Option A: Resolve directory symlinks after extraction

**Where:** After `archive_driver.ml:extract()` returns, walk the extracted
tree and replace directory symlinks with copies of their targets.

**Pros:** Fixes Cases 2, 3, 4. Minimal change — one function added after
extraction. No changes to the digest system.

**Cons:** Doubles disk usage for symlinked directories. Changes the source
tree semantics (the extracted tree no longer matches the tarball exactly).
May break packages that depend on symlink behavior (unlikely but possible).

**Implementation:** Extend `resolve_symlinks_in` in `pkg_rules.ml` to
handle `S_DIR` targets — when the resolved symlink points to a directory,
recursively copy it:

```ocaml
| Ok resolved ->
  match Unix.lstat resolved with
  | { st_kind = S_REG; _ } ->
    Fpath.unlink_exn path;
    Io.portable_hardlink ~src ~dst
  | { st_kind = S_DIR; _ } ->
    Fpath.unlink_exn path;
    Io.copytree ~src:resolved ~dst:path
  | _ -> ()
```

Then call `resolve_symlinks_in` on the extracted source directory before
proceeding with the build.

### Option B: Teach the digest system to handle directory symlinks

**Where:** `src/dune_digest/digest.ml`, the outer match at line 289.

**Change:** Remove `S_LNK` from the rejection list and let all symlinks
reach the `loop` function:

```ocaml
match stats.st_kind with
| S_DIR when not allow_dirs -> Error Unexpected_kind
| S_BLK | S_CHR | S_FIFO | S_SOCK -> Error Unexpected_kind
| _ -> loop path stats
```

Inside `loop`, the `S_LNK` case already digests the readlink target. For a
directory symlink, this produces a digest of the target path string — which
is deterministic and sufficient.

**Pros:** Fixes all five cases. Smallest code change. Doesn't modify
extracted files.

**Cons:** A symlink to a directory and the directory itself would have
different digests (one is a string digest of the path, the other is a
recursive content digest). This means changing a directory to a symlink
or vice versa would invalidate caches — which is arguably correct behavior.
However, it means the shared cache cannot substitute one for the other,
which is the concern raised in #11523.

**Design concern from PR #10426:** symlinks with absolute paths are not
portable across machines, which matters for the shared cache. A symlink
`/home/user/project/src/foo` won't resolve on another machine.

### Option C: Resolve during copy, digest the resolved content

Combine A and B: resolve directory symlinks to real directories during
source copy/extraction, then digest the resolved content normally.

**Pros:** Deterministic digests. No special symlink handling in digest code.
Shared cache works correctly.

**Cons:** Most complex. Requires changes in both the extraction pipeline
and the copy/install pipeline.

### Option D: Reject only at the shared cache boundary

Allow directory symlinks in local builds (fix the digest to handle them)
but strip/resolve them before storing in the shared cache.

**Pros:** Addresses #11523 too. Local builds work with symlinks as-is.

**Cons:** Two different behaviors depending on cache mode. Complexity.

## Recommendation

*(This is what upstream ended up doing: PR #13792 implements Option A for
fetched sources.)*

**Option A** for immediate pragmatic fix — resolve directory symlinks after
tarball extraction. This unblocks `ocamlbuild` and similar packages with
minimal risk. The `resolve_symlinks_in` function already exists and handles
file symlinks; extending it to directories is straightforward.

**Option B** as a longer-term design improvement — teach the digest system
to handle all symlinks uniformly. The `S_LNK` rejection at the outer entry
point appears to be an oversight from the original #9407 change, not a
deliberate design decision. Removing it restores the behavior where symlinks
inside directories are handled by the loop, regardless of what they point
to.

Both options can be combined: Option A for source extraction (so the build
sees a clean tree without symlinks) and Option B as a safety net for
directory targets produced by rules.
