(** Full round-trip test: migrate, build, sync, clean, restore, build.
    When [threshold] is set, fail (exit 1) if the post-restore rebuild
    takes longer than that many seconds. *)
val run : ?threshold:float -> string option -> string -> unit
