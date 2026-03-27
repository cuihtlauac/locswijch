type t = {
  project_root : string;
  build_pkg_dir : string;  (** _build/_private/default/.pkg *)
  lock_dir : string;       (** dune.lock *)
  switch_name : string;
  switch_dir : string;     (** ~/.opam/<switch-name> *)
  same_device : bool;      (** can use hard links between _build and switch *)
  opam_root : string;      (** ~/.opam *)
}

(** Resolve configuration from project root and switch name.
    [switch_name] defaults to the project directory basename. *)
val resolve : project_root:string -> switch_name:string option -> t

(** Find project root by looking for dune-project in ancestors. *)
val find_project_root : string -> string option

(** Cmdliner arguments *)
val switch_arg : string option Cmdliner.Term.t
val project_arg : string Cmdliner.Term.t
