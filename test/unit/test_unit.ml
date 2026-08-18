(* Unit tests for Sexp_parser and Opam_read. Plain assertions, no test
   framework. Each check prints ok/FAIL; the process exits 1 if any
   check failed, so every failing case is reported in one run. *)

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   %s\n" name
  else begin
    incr failures;
    Printf.printf "FAIL %s\n" name
  end

let show_list l = "[" ^ String.concat "; " l ^ "]"

let check_strings name ~expected ~actual =
  if expected = actual then Printf.printf "ok   %s\n" name
  else begin
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
      (show_list expected) (show_list actual)
  end

let check_commands name ~expected ~actual =
  if expected = actual then Printf.printf "ok   %s\n" name
  else begin
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
      (show_list (List.map show_list expected))
      (show_list (List.map show_list actual))
  end

(* ---------- Sexp_parser ---------- *)

let sexp_tests () =
  let open Locswijch.Sexp_parser in
  check "sexp: bare atom" (parse_string "foo" = [ Atom "foo" ]);
  check "sexp: several top-level forms"
    (parse_string "a (b) c" = [ Atom "a"; List [ Atom "b" ]; Atom "c" ]);
  check "sexp: quoted string with escapes"
    (parse_string {|"a b\n\"c\""|} = [ Atom "a b\n\"c\"" ]);
  check "sexp: nested lists"
    (parse_string {|(a (b c) "d e")|}
     = [ List [ Atom "a"; List [ Atom "b"; Atom "c" ]; Atom "d e" ] ]);
  check "sexp: comments skipped"
    (parse_string "; head\n(a) ; trailing\n(b)"
     = [ List [ Atom "a" ]; List [ Atom "b" ] ]);
  check "sexp: empty input" (parse_string "  ; only a comment\n" = []);
  check "sexp: atom_value on atom" (atom_value (Atom "x") = Some "x");
  check "sexp: atom_value on list" (atom_value (List []) = None);
  check "sexp: list_values on list"
    (list_values (List [ Atom "x" ]) = Some [ Atom "x" ]);
  check "sexp: list_values on atom" (list_values (Atom "x") = None);
  let fields = parse_string "(version 1.0)\n(build (run make))" in
  check "sexp: find_field hit"
    (find_field "version" fields = Some [ Atom "1.0" ]);
  check "sexp: find_field miss" (find_field "install" fields = None)

(* ---------- Opam_read ---------- *)

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

(* Fixed host platform for deterministic filter evaluation in tests. *)
let host_vars =
  [ ("os", "linux"); ("os-family", "debian");
    ("os-distribution", "ubuntu"); ("os-version", "26.04");
    ("arch", "x86_64") ]

(* Write a fixture opam file into a minimal switch layout and read it
   back through the public API. *)
let read_fixture ?(host_vars = host_vars) ~switch_dir ~installed_names
    ~name ~version content =
  let pkg_dir =
    List.fold_left Filename.concat switch_dir
      [ ".opam-switch"; "packages"; name ^ "." ^ version ]
  in
  Locswijch.Hardlink.mkdir_p pkg_dir;
  write_file (Filename.concat pkg_dir "opam") content;
  Locswijch.Opam_read.read_package_opam ~host_vars ~switch_dir
    ~installed_names ~name ~version

let opam_read_tests () =
  let switch_dir = make_temp_dir "locswijch-unit" in
  Fun.protect
    ~finally:(fun () -> Locswijch.Hardlink.remove_tree switch_dir)
    (fun () ->
      let installed = [ "a"; "b"; "c"; "e"; "f"; "foo" ] in

      (* Disjunctions expand to all alternatives; {post} deps are
         dropped, including a {post}-marked disjunction. *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"disj"
          ~version:"1.0"
          {|opam-version: "2.0"
depends: [
  "a" {>= "1.0"}
  ("b" {>= "2.0"} | "c")
  "d" {post}
  ("x" | "y") {post}
]
|}
      in
      check_strings "opam_read: disjunctions and post deps"
        ~expected:[ "a"; "b"; "c" ] ~actual:info.depends;

      (* depopts are merged after depends. *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"opts"
          ~version:"1.0"
          {|opam-version: "2.0"
depends: [ "a" ]
depopts: [ "e" "f" ]
|}
      in
      check_strings "opam_read: depopts merged into depends"
        ~expected:[ "a"; "e"; "f" ] ~actual:info.depends;

      (* A flat command with a filtered atom is one command, with the
         filtered atom dropped (previously parsed as no command at all). *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"flat"
          ~version:"1.0"
          {|opam-version: "2.0"
build: [ "./configure" "--prefix" prefix "--enable-tests" {with-test} ]
|}
      in
      check_commands "opam_read: flat build command with filtered atom"
        ~expected:[ [ "./configure"; "--prefix"; "%{prefix}" ] ]
        ~actual:info.build;

      (* Multi-command build; idents translate to dune pforms. *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"multi"
          ~version:"1.0"
          {|opam-version: "2.0"
build: [
  [ make "all" ]
  [ make "install" "PREFIX=%{prefix}%" ]
]
|}
      in
      check_commands "opam_read: multi-command build"
        ~expected:
          [ [ "%{make}"; "all" ];
            [ "%{make}"; "install"; "PREFIX=%{prefix}" ] ]
        ~actual:info.build;

      (* %{pkg:installed}% resolves against the installed set: string
         form, conjunction form (a+b), and bare ident form. *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"inst"
          ~version:"1.0"
          {|opam-version: "2.0"
build: [
  "echo" "%{foo:installed}%" "%{bar:installed}%" "%{foo+bar:installed}%"
  foo:installed
]
|}
      in
      check_commands "opam_read: %{pkg:installed}% resolution"
        ~expected:[ [ "echo"; "true"; "false"; "false"; "true" ] ]
        ~actual:info.build;

      (* os filters on whole commands are evaluated against the host:
         definitely-false commands are dropped, matching-os and
         unknown-variable filters are kept (conf-pkg-config pattern). *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"oscmd"
          ~version:"1.0"
          {|opam-version: "2.0"
build: [
  ["pkg-config" "--help"]
    {os != "win32" & !(os = "macos" & os-distribution = "homebrew")}
  ["pkgconf" "--version"]
    {os = "win32" & os-distribution != "msys2" |
     os = "macos" & os-distribution = "homebrew"}
  ["dune" "runtest"] {with-test}
  ["echo" "hi"] {unknown-thing = "yes"}
]
|}
      in
      check_commands "opam_read: os-filtered commands"
        ~expected:[ [ "pkg-config"; "--help" ]; [ "echo"; "hi" ] ]
        ~actual:info.build;

      (* os filters on atoms inside one command: true filters keep the
         atom (previously all filtered atoms were dropped), false and
         unknown filters drop it (conf-libssl pattern). *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"osatom"
          ~version:"1.0"
          {|opam-version: "2.0"
build: [
  [
    "pkgconf" {os = "win32" & os-distribution != "cygwinports"}
    "pkg-config" {os != "win32" | os-distribution = "cygwinports"}
    "--print-errors"
    "--exists"
    "openssl"
  ]
    {os != "freebsd" & os != "openbsd" & os != "netbsd" &
     os-distribution != "homebrew"}
]
|}
      in
      check_commands "opam_read: os-filtered atoms"
        ~expected:
          [ [ "pkg-config"; "--print-errors"; "--exists"; "openssl" ] ]
        ~actual:info.build;

      (* Dependency alternatives with definitely-false platform filters
         are dropped even when the package is installed; version
         constraints are unknown and keep the dep (conf-libev pattern). *)
      let info =
        read_fixture ~switch_dir
          ~installed_names:[ "conf-libev"; "ocaml"; "a" ] ~name:"osdep"
          ~version:"1.0"
          {|opam-version: "2.0"
depends: [
  ("conf-libev" {os != "win32"} | "ocaml" {os = "win32"})
  "a" {>= "1.0"}
]
|}
      in
      check_strings "opam_read: os-filtered dep disjunction"
        ~expected:[ "conf-libev"; "a" ] ~actual:info.depends;

      (* Host variables inline as constants in strings and idents;
         os-version bounds compare numerically. *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"hostvar"
          ~version:"1.0"
          {|opam-version: "2.0"
build: [
  [ "echo" "%{os}%" arch ]
  [ "echo" "new" ] {os-version >= "20.04"}
  [ "echo" "old" ] {os-version <= "7"}
]
|}
      in
      check_commands "opam_read: host variable inlining and os-version"
        ~expected:[ [ "echo"; "linux"; "x86_64" ]; [ "echo"; "new" ] ]
        ~actual:info.build;

      (* url section: src and first checksum. *)
      let info =
        read_fixture ~switch_dir ~installed_names:installed ~name:"src"
          ~version:"1.0"
          {|opam-version: "2.0"
url {
  src: "https://example.org/src-1.0.tbz"
  checksum: [ "sha256=abc" "md5=def" ]
}
|}
      in
      check "opam_read: url src"
        (info.url = Some "https://example.org/src-1.0.tbz");
      check "opam_read: first checksum" (info.checksum = Some "sha256=abc");

      (* Missing opam file yields empty defaults. *)
      let info =
        Locswijch.Opam_read.read_package_opam ~host_vars ~switch_dir
          ~installed_names:installed ~name:"absent" ~version:"1.0"
      in
      check "opam_read: missing opam file"
        (info.depends = [] && info.build = [] && info.url = None))

let () =
  sexp_tests ();
  opam_read_tests ();
  if !failures > 0 then begin
    Printf.printf "%d check(s) failed\n" !failures;
    exit 1
  end;
  Printf.printf "all checks passed\n"
