type t =
  | Atom of string
  | List of t list

type input = {
  buf : string;
  mutable pos : int;
}

let make_input s = { buf = s; pos = 0 }
let at_end inp = inp.pos >= String.length inp.buf
let _peek inp = if at_end inp then None else Some inp.buf.[inp.pos]

let advance inp = inp.pos <- inp.pos + 1

let skip_whitespace_and_comments inp =
  let rec loop () =
    if at_end inp then ()
    else
      match inp.buf.[inp.pos] with
      | ' ' | '\t' | '\n' | '\r' ->
        advance inp;
        loop ()
      | ';' ->
        (* line comment: skip to end of line *)
        while not (at_end inp) && inp.buf.[inp.pos] <> '\n' do
          advance inp
        done;
        if not (at_end inp) then advance inp;
        loop ()
      | _ -> ()
  in
  loop ()

let parse_quoted_string inp =
  (* skip opening quote *)
  advance inp;
  let buf = Buffer.create 64 in
  let rec loop () =
    if at_end inp then failwith "Unterminated quoted string"
    else
      match inp.buf.[inp.pos] with
      | '"' ->
        advance inp;
        Buffer.contents buf
      | '\\' ->
        advance inp;
        if at_end inp then failwith "Unterminated escape in quoted string";
        let c =
          match inp.buf.[inp.pos] with
          | 'n' -> '\n'
          | 't' -> '\t'
          | 'r' -> '\r'
          | c -> c
        in
        Buffer.add_char buf c;
        advance inp;
        loop ()
      | c ->
        Buffer.add_char buf c;
        advance inp;
        loop ()
  in
  loop ()

let is_atom_char = function
  | ' ' | '\t' | '\n' | '\r' | '(' | ')' | '"' | ';' -> false
  | _ -> true

let parse_atom inp =
  let start = inp.pos in
  while not (at_end inp) && is_atom_char inp.buf.[inp.pos] do
    advance inp
  done;
  if inp.pos = start then failwith "Expected atom"
  else String.sub inp.buf start (inp.pos - start)

let rec parse_one inp =
  skip_whitespace_and_comments inp;
  if at_end inp then None
  else
    match inp.buf.[inp.pos] with
    | '(' ->
      advance inp;
      let items = parse_list inp in
      Some (List items)
    | '"' ->
      let s = parse_quoted_string inp in
      Some (Atom s)
    | ')' -> None
    | _ ->
      let s = parse_atom inp in
      Some (Atom s)

and parse_list inp =
  let rec loop acc =
    skip_whitespace_and_comments inp;
    if at_end inp then failwith "Unterminated list"
    else if inp.buf.[inp.pos] = ')' then (
      advance inp;
      List.rev acc)
    else
      match parse_one inp with
      | Some sexp -> loop (sexp :: acc)
      | None -> List.rev acc
  in
  loop []

let parse_string s =
  let inp = make_input s in
  let rec loop acc =
    skip_whitespace_and_comments inp;
    if at_end inp then List.rev acc
    else
      match parse_one inp with
      | Some sexp -> loop (sexp :: acc)
      | None -> List.rev acc
  in
  loop []

let parse_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  parse_string s

let atom_value = function Atom s -> Some s | List _ -> None
let list_values = function List l -> Some l | Atom _ -> None

let find_field name sexps =
  List.find_map
    (fun sexp ->
      match sexp with
      | List (Atom field :: rest) when field = name -> Some rest
      | _ -> None)
    sexps
