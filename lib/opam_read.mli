(** Read an opam switch and extract package information. *)

type pkg_info = {
  name : string;
  version : string;
  depends : string list;
  build : string list list;     (** each inner list is a command *)
  install : string list list;
  url : string option;
  checksum : string option;
  exported_env : (string * string * string) list;  (** (op, var, value) *)
  extra_sources : (string * string * string option) list;  (** (filename, url, checksum) *)
  build_env : (string * string * string) list;  (** (op, var, value) *)
  substs : string list;  (** files to substitute (.in -> output) *)
}

(** Read installed packages from switch-state. Returns (name, version) pairs. *)
val read_installed : switch_dir:string -> (string * string) list

(** Read a package's opam file from .opam-switch/packages/.
    [installed_names] is the switch's installed set, used to resolve
    %{pkg:installed}% variables. [host_vars] gives the host platform
    values (os, os-family, os-distribution, os-version, arch) used to
    statically evaluate filters on commands, atoms and dependencies;
    variables absent from the list leave their filters unevaluated
    (commands and deps kept, atoms dropped). *)
val read_package_opam :
  host_vars:(string * string) list ->
  switch_dir:string -> installed_names:string list ->
  name:string -> version:string -> pkg_info

(** Read the compiler package names from switch-state. *)
val read_compiler_pkgs : switch_dir:string -> (string * string) list
