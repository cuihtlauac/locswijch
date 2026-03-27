(** Link or copy a single file. Uses hard-link if [same_device] is true,
    otherwise copies. Creates parent directories as needed. *)
val link_file : src:string -> dst:string -> same_device:bool -> unit

(** Recursively link all files from [src] tree into [dst] tree.
    Preserves directory structure. Symlinks are recreated as symlinks. *)
val link_tree : src:string -> dst:string -> same_device:bool -> unit

(** [rm -rf] equivalent. *)
val remove_tree : string -> unit

(** Create directory and all parents. *)
val mkdir_p : string -> unit
