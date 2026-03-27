type source = {
  url : string;
  checksum : string option;
}

type t = {
  name : string;
  version : string;
  depends : string list;
  source : source option;
  build : Sexp_parser.t list option;
  install : Sexp_parser.t list option;
  exported_env : (string * string * string) list; (** (op, var, value) *)
}

(** Load a single .pkg file. [name] and [version] are parsed from the filename. *)
val load : string -> t

(** Load all .pkg files from a dune.lock/ directory. *)
val load_all : lock_dir:string -> t list

(** Parse a digest directory name like "base.v0.17.3-abc123" into
    (name, version, digest). *)
val parse_digest_dir : string -> (string * string * string) option

(** Read the ocaml compiler package name from lock.dune. *)
val read_ocaml_pkg : lock_dir:string -> string option
