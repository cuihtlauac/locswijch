type entry = {
  src : string;
  dst : string option;
}

type section = {
  name : string;
  entries : entry list;
}

type t = {
  package : string;
  sections : section list;
}

(* Classify a file path relative to target/ into an install section *)
let classify_path pkg_name path =
  let parts = String.split_on_char '/' path in
  match parts with
  | "bin" :: _ -> Some ("bin", path)
  | "sbin" :: _ -> Some ("sbin", path)
  | "man" :: _ -> Some ("man", path)
  | "doc" :: _ -> Some ("doc", path)
  | "share" :: _ -> Some ("share", path)
  | "etc" :: _ -> Some ("etc", path)
  | "lib" :: "stublibs" :: _ -> Some ("stublibs", path)
  | "lib" :: "toplevel" :: _ -> Some ("toplevel", path)
  | "lib" :: pkg :: _ when pkg = pkg_name -> Some ("lib", path)
  | "lib" :: _ -> Some ("lib", path)
  | _ -> None

(* Walk a directory tree and collect all file paths relative to root *)
let walk_dir root =
  let files = ref [] in
  let rec loop rel_dir =
    let abs_dir = Filename.concat root rel_dir in
    let entries = Sys.readdir abs_dir in
    Array.iter
      (fun name ->
        let rel_path =
          if rel_dir = "" then name else Filename.concat rel_dir name
        in
        let abs_path = Filename.concat abs_dir name in
        if Sys.is_directory abs_path then loop rel_path
        else files := rel_path :: !files)
      entries
  in
  loop "";
  List.sort String.compare !files

let generate_from_target ~pkg_name ~target_dir =
  let files = walk_dir target_dir in
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun path ->
      (* skip the cookie file *)
      if path <> "cookie" then
        match classify_path pkg_name path with
        | Some (section, rel_path) ->
          let entries =
            match Hashtbl.find_opt tbl section with
            | Some l -> l
            | None -> []
          in
          Hashtbl.replace tbl section
            ({ src = rel_path; dst = None } :: entries)
        | None -> ())
    files;
  let sections =
    Hashtbl.fold
      (fun name entries acc ->
        { name; entries = List.sort (fun a b -> String.compare a.src b.src) entries }
        :: acc)
      tbl []
    |> List.sort (fun a b -> String.compare a.name b.name)
  in
  { package = pkg_name; sections }

let write ~switch_dir install =
  let install_dir =
    List.fold_left Filename.concat switch_dir
      [ ".opam-switch"; "install" ]
  in
  Hardlink.mkdir_p install_dir;
  let path =
    Filename.concat install_dir (install.package ^ ".install")
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      Printf.fprintf oc "opam-version: \"2.0\"\n";
      List.iter
        (fun section ->
          Printf.fprintf oc "%s: [\n" section.name;
          List.iter
            (fun entry ->
              match entry.dst with
              | None -> Printf.fprintf oc "  \"%s\"\n" entry.src
              | Some d -> Printf.fprintf oc "  \"%s\" {\"%s\"}\n" entry.src d)
            section.entries;
          Printf.fprintf oc "]\n")
        install.sections)

let load path =
  let package =
    Filename.basename path |> Filename.chop_extension
  in
  (* Simple parser for .install files *)
  let ic = open_in path in
  let content =
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let n = in_channel_length ic in
        really_input_string ic n)
  in
  let lines = String.split_on_char '\n' content in
  let current_section = ref None in
  let sections = Hashtbl.create 16 in
  List.iter
    (fun line ->
      let line = String.trim line in
      if line = "" || line = "]" then ()
      else if String.length line > 14
              && String.sub line 0 14 = "opam-version: "
      then ()
      else
        (* Check if this is a section header like "lib: [" *)
        match String.index_opt line ':' with
        | Some colon_pos
          when (not (String.contains (String.sub line 0 colon_pos) '"'))
               && String.contains line '[' ->
          let section_name = String.trim (String.sub line 0 colon_pos) in
          current_section := Some section_name;
          if not (Hashtbl.mem sections section_name) then
            Hashtbl.replace sections section_name []
        | _ ->
          (match !current_section with
           | None -> ()
           | Some section_name ->
             (* Parse entry: "path" or "path" {"dest"} *)
             let parse_quoted s start =
               match String.index_from_opt s start '"' with
               | None -> None
               | Some q1 ->
                 (match String.index_from_opt s (q1 + 1) '"' with
                  | None -> None
                  | Some q2 ->
                    Some (String.sub s (q1 + 1) (q2 - q1 - 1), q2 + 1))
             in
             (match parse_quoted line 0 with
              | None -> ()
              | Some (src, rest_pos) ->
                let dst =
                  match String.index_from_opt line rest_pos '{' with
                  | None -> None
                  | Some _ ->
                    (match parse_quoted line rest_pos with
                     | Some (d, _) -> Some d
                     | None -> None)
                in
                let entries = Hashtbl.find sections section_name in
                Hashtbl.replace sections section_name
                  ({ src; dst } :: entries))))
    lines;
  let sections =
    Hashtbl.fold
      (fun name entries acc ->
        { name; entries = List.rev entries } :: acc)
      sections []
    |> List.sort (fun a b -> String.compare a.name b.name)
  in
  { package; sections }
