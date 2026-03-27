let run () =
  let _result = Cmdliner.Cmd.eval (Cmd.cmd ()) in
  ()
