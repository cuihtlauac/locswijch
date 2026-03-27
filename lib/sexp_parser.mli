type t =
  | Atom of string
  | List of t list

val parse_string : string -> t list
val parse_file : string -> t list

(** Convenience accessors *)

val atom_value : t -> string option
val list_values : t -> t list option

(** Find a field in a list of S-expressions.
    E.g. [find_field "version" sexps] looks for [(version ...)] *)
val find_field : string -> t list -> t list option
