open Async
module Log = Log.Global

let handle_client addr reader writer =
  let addr_str = Socket.Address.to_string addr in
  Log.info "New connection from %s" addr_str;
  let rec loop () =
    match%bind Reader.read_line reader with
    | `Eof ->
        Log.info "Connection from %s closed" addr_str;
        return ()
    | `Ok line ->
        Log.info "Received from %s: %s" addr_str line;
        Writer.write_line writer line;
        let%bind () = Writer.flushed writer in
        loop ()
  in
  loop ()

let start port =
  Log.info "Starting server on port %d" port;
  let%bind _server =
    Tcp.(
      Server.create ~on_handler_error:`Ignore
        (Where_to_listen.of_port port)
        handle_client)
  in
  Deferred.never ()
