(** Generate opam switch metadata files. *)

(** Write .opam-switch/switch-config *)
val write_switch_config : Config.t -> Pkg_file.t list -> unit

(** Write .opam-switch/switch-state *)
val write_switch_state :
  Config.t -> Pkg_file.t list -> ocaml_pkg:string option -> unit

(** Write .opam-switch/packages/<name>.<version>/opam for a single package. *)
val write_package_opam : Config.t -> Pkg_file.t -> unit

(** Write .opam-switch/environment *)
val write_environment : Config.t -> Pkg_file.t list -> unit

(** Register switch in ~/.opam/config if not already present. *)
val register_switch : Config.t -> unit
