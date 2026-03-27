type t = {
  project_root : string;
  build_pkg_dir : string;
  lock_dir : string;
  switch_name : string;
  switch_dir : string;
  same_device : bool;
  opam_root : string;
}

let find_project_root start =
  let rec loop dir =
    let candidate = Filename.concat dir "dune-project" in
    if Sys.file_exists candidate then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else loop parent
  in
  loop start

let opam_root () =
  match Sys.getenv_opt "OPAMROOT" with
  | Some r -> r
  | None -> Filename.concat (Sys.getenv "HOME") ".opam"

let same_device path1 path2 =
  try
    let s1 = Unix.stat path1 in
    let s2 = Unix.stat path2 in
    s1.st_dev = s2.st_dev
  with Unix.Unix_error _ -> false

let resolve ~project_root ~switch_name =
  let opam_root = opam_root () in
  let switch_name, switch_dir =
    match switch_name with
    | Some n when Filename.is_relative n ->
      (* Could be a named switch or relative path *)
      let as_path = Filename.concat project_root n in
      if Sys.file_exists (List.fold_left Filename.concat as_path
                            [ ".opam-switch"; "switch-config" ])
      then (n, as_path)
      else (n, Filename.concat opam_root n)
    | Some n ->
      (* Absolute path to switch *)
      (Filename.basename n, n)
    | None ->
      (* Default: check for local switch (_opam) first *)
      let local_switch = Filename.concat project_root "_opam" in
      if Sys.file_exists (List.fold_left Filename.concat local_switch
                            [ ".opam-switch"; "switch-config" ])
      then (Filename.basename project_root, local_switch)
      else
        let name = Filename.basename project_root in
        (name, Filename.concat opam_root name)
  in
  let build_pkg_dir =
    List.fold_left Filename.concat project_root
      [ "_build"; "_private"; "default"; ".pkg" ]
  in
  let lock_dir = Filename.concat project_root "dune.lock" in
  let same_device =
    if Sys.file_exists build_pkg_dir then same_device build_pkg_dir switch_dir
    else same_device project_root switch_dir
  in
  { project_root; build_pkg_dir; lock_dir; switch_name; switch_dir;
    same_device; opam_root }

open Cmdliner

let switch_arg =
  let doc = "Opam switch name. Defaults to project directory basename." in
  Arg.(value & opt (some string) None & info [ "switch"; "s" ] ~docv:"NAME" ~doc)

let project_arg =
  let doc = "Project root directory. Defaults to auto-detected." in
  let default =
    match find_project_root (Sys.getcwd ()) with
    | Some r -> r
    | None -> Sys.getcwd ()
  in
  Arg.(value & opt dir default & info [ "project"; "C" ] ~docv:"DIR" ~doc)
