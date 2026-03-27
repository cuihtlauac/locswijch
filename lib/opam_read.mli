(** Read an opam switch and extract package information. *)

type pkg_info = {
  name : string;
  version : string;
  depends : string list;
  build : string list list;     (** each inner list is a command *)
  install : string list list;
  url : string option;
  checksum : string option;
  exported_env : (string * string * string) list;
}

(** Read installed packages from switch-state. Returns (name, version) pairs. *)
val read_installed : switch_dir:string -> (string * string) list

(** Read a package's opam file from .opam-switch/packages/. *)
val read_package_opam : switch_dir:string -> name:string -> version:string -> pkg_info

(** Read the compiler package names from switch-state. *)
val read_compiler_pkgs : switch_dir:string -> (string * string) list
