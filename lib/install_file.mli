type entry = {
  src : string;  (** path relative to switch prefix *)
  dst : string option; (** optional destination within section *)
}

type section = {
  name : string;
  entries : entry list;
}

type t = {
  package : string;
  sections : section list;
}

(** Generate an install file by walking a package's [target/] directory.
    Categorizes files by section subdirectory. *)
val generate_from_target : pkg_name:string -> target_dir:string -> t

(** Write an .install file to [switch_dir/.opam-switch/install/<pkg>.install]. *)
val write : switch_dir:string -> t -> unit

(** Parse an .install file. *)
val load : string -> t
