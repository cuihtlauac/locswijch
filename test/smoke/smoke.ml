(* Self-contained end-to-end smoke test.

   Generates, in a fresh temp dir, a tiny fixture: two file-install
   packages with local file:// sources, a minimal opam switch layout
   listing them as installed, and a trivial dune project. Then runs the
   full trip cycle (migrate, build, sync, clean, restore, rebuild)
   through the library.

   The closure has no compiler package, so migrate omits the (ocaml ...)
   line from lock.dune and dune falls back to the ambient toolchain —
   the whole run takes seconds, not minutes.

   fixa's build is a plain "sleep": a fresh build necessarily takes
   longer than the trip threshold, so the post-restore rebuild can only
   pass the threshold by *skipping* package rebuilds (via restored state
   and the shared dune cache). That is the property this test pins.

   On failure trip exits 1 and the fixture dir is left behind for
   inspection (its path is printed first). On success it is removed. *)

let build_sleep = 5 (* seconds; fresh package build takes at least this *)
let threshold = 4.0 (* post-restore rebuild must beat this *)

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc content)

let make_temp_dir prefix =
  let base = Filename.get_temp_dir_name () in
  let rec go n =
    let d =
      Filename.concat base
        (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) n)
    in
    if Sys.file_exists d then go (n + 1)
    else begin
      Unix.mkdir d 0o700;
      d
    end
  in
  go 0

let ( / ) = Filename.concat

let fixa_opam ~src_url =
  Printf.sprintf
    {|opam-version: "2.0"
build: [ "sleep" "%d" ]
install: [
  [ "mkdir" "-p" "%%{prefix}%%/share" ]
  [ "cp" "data.txt" "%%{prefix}%%/share/fixa-data.txt" ]
  [ "mkdir" "-p" "%%{prefix}%%/bin" ]
  [ "cp" "tool.sh" "%%{prefix}%%/bin/fixa-tool" ]
]
url {
  src: "%s"
}
|}
    build_sleep src_url

let fixb_opam ~src_url =
  Printf.sprintf
    {|opam-version: "2.0"
depends: [ "fixa" ]
install: [
  [ "mkdir" "-p" "%%{prefix}%%/share" ]
  [ "cp" "data.txt" "%%{prefix}%%/share/fixb-data.txt" ]
  [ "mkdir" "-p" "%%{prefix}%%/bin" ]
  [ "cp" "tool.sh" "%%{prefix}%%/bin/fixb-tool" ]
]
url {
  src: "%s"
}
|}
    src_url

let switch_state =
  {|opam-version: "2.0"
installed: [
  "fixa.1.0"
  "fixb.1.0"
]
|}

let () =
  let root = make_temp_dir "locswijch-smoke" in
  Printf.printf "smoke fixture: %s\n%!" root;
  let mkdir_p = Locswijch.Hardlink.mkdir_p in

  (* Package sources, referenced by absolute file:// URLs. *)
  let src_a = root / "src" / "fixa" in
  let src_b = root / "src" / "fixb" in
  mkdir_p src_a;
  mkdir_p src_b;
  write_file (src_a / "data.txt") "fixture package fixa\n";
  write_file (src_b / "data.txt") "fixture package fixb\n";
  (* Each package installs a tiny executable; the project runs both, so
     dune must build both packages (cp preserves the exec bit). *)
  write_file (src_a / "tool.sh") "#!/bin/sh\necho fixa-tool-output\n";
  write_file (src_b / "tool.sh") "#!/bin/sh\necho fixb-tool-output\n";
  Unix.chmod (src_a / "tool.sh") 0o755;
  Unix.chmod (src_b / "tool.sh") 0o755;

  (* Minimal opam switch layout: switch-state + per-package opam files.
     No compiler package, so the generated lock uses the ambient
     toolchain. *)
  let switch = root / "switch" in
  let pkgs = switch / ".opam-switch" / "packages" in
  mkdir_p (pkgs / "fixa.1.0");
  mkdir_p (pkgs / "fixb.1.0");
  write_file
    (pkgs / "fixa.1.0" / "opam")
    (fixa_opam ~src_url:("file://" ^ src_a));
  write_file
    (pkgs / "fixb.1.0" / "opam")
    (fixb_opam ~src_url:("file://" ^ src_b));
  write_file (switch / ".opam-switch" / "switch-state") switch_state;

  (* Trivial dune project. Declaring the fixture packages as
     dependencies is not enough for dune to build them — rules must
     actually consume them, so run each package's tool and install the
     outputs (trip builds @install). *)
  let proj = root / "proj" in
  mkdir_p proj;
  write_file (proj / "dune-project")
    "(lang dune 3.15)\n(name fixproj)\n\
     (package (name fixproj) (depends fixa fixb))\n";
  write_file (proj / "dune")
    "(executable\n (name hello)\n (public_name hello))\n\n\
     (rule\n (with-stdout-to fixa.out\n  (run fixa-tool)))\n\n\
     (rule\n (with-stdout-to fixb.out\n  (run fixb-tool)))\n\n\
     (install\n (files fixa.out fixb.out)\n (section share))\n";
  write_file (proj / "hello.ml") {|let () = print_endline "hello"|};

  (* Hermetic dune cache inside the fixture root. Also required for
     correctness: the default cache storage mode hard-links, which fails
     silently when the fixture (often on tmpfs) and ~/.cache/dune are on
     different devices — the post-restore rebuild would then re-run
     every package build and miss the threshold. *)
  Unix.putenv "XDG_CACHE_HOME" (root / "cache");

  Locswijch.Trip.run ~threshold (Some switch) proj;

  Locswijch.Hardlink.remove_tree root;
  Printf.printf "\nSMOKE PASSED\n"
