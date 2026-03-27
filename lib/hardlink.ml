let mkdir_p path =
  let rec loop dir =
    if Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  loop path

let copy_file ~src ~dst =
  let ic = open_in_bin src in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let oc = open_out_bin dst in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
          let buf = Bytes.create 65536 in
          let rec loop () =
            let n = input ic buf 0 (Bytes.length buf) in
            if n > 0 then begin
              output oc buf 0 n;
              loop ()
            end
          in
          loop ()))

let link_file ~src ~dst ~same_device =
  mkdir_p (Filename.dirname dst);
  (try Sys.remove dst with Sys_error _ -> ());
  if same_device then
    try Unix.link src dst
    with Unix.Unix_error _ -> copy_file ~src ~dst
  else copy_file ~src ~dst

let rec link_tree ~src ~dst ~same_device =
  mkdir_p dst;
  let entries = Sys.readdir src in
  Array.iter
    (fun name ->
      let src_path = Filename.concat src name in
      let dst_path = Filename.concat dst name in
      let stats = Unix.lstat src_path in
      match stats.st_kind with
      | Unix.S_REG -> link_file ~src:src_path ~dst:dst_path ~same_device
      | Unix.S_DIR -> link_tree ~src:src_path ~dst:dst_path ~same_device
      | Unix.S_LNK ->
        let target = Unix.readlink src_path in
        (try Sys.remove dst_path with Sys_error _ -> ());
        Unix.symlink target dst_path
      | _ -> ())
    entries

let remove_tree path =
  let rec loop p =
    if Sys.is_directory p then begin
      let entries = Sys.readdir p in
      Array.iter (fun name -> loop (Filename.concat p name)) entries;
      Unix.rmdir p
    end
    else Sys.remove p
  in
  if Sys.file_exists path then loop path
