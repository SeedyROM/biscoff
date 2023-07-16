open Async
open Core
open Websocket_async
module Log = Log.Global

let parse_frame frame content opcode addr =
  let open Frame in
  let frame', closed =
    match opcode with
    | Opcode.Ping -> ({ frame with opcode = Opcode.Pong }, false)
    | Opcode.Close ->
        Log.debug "Connection closed by %s" addr;
        ({ frame with opcode = Opcode.Close }, true)
    | Opcode.Text ->
        Log.debug "Received %s from %s" content addr;
        (frame, false)
    | Opcode.Pong ->
        Log.debug "Received %s from %s" (Opcode.to_string opcode) addr;
        (frame, false)
    | _ -> (frame, true)
  in
  (frame', closed)

(** Client connection loop, parse incoming frames *)
let client_loop addr receiver_read sender_write _text_write =
  let rec loop () =
    match%bind Pipe.read receiver_read with
    | `Eof ->
        Log.debug "Connection closed by %s" addr;
        return ()
    | `Ok ({ Frame.opcode; content; _ } as frame) ->
        let frame', closed = parse_frame frame content opcode addr in
        let%bind () = Pipe.write sender_write frame' in
        if closed then return () else loop ()
  in
  loop ()

(** Check if the URI of the request is /ws *)
let check_request req =
  let uri = Cohttp.Request.uri req in
  Deferred.return (String.equal (Uri.path uri) "/ws")

(** Handle server creation errors *)
let handle_server_error server =
  match%bind server with
  | Error err when Poly.equal (Error.to_exn err) Exit -> Deferred.unit
  | Error err -> Error.raise err
  | Ok () -> Deferred.unit

(** Create a websocket server waiting for HTTP requests at "/ws" *)
let create_server app_to_ws ws_to_app reader writer =
  server ~check_request ~app_to_ws ~ws_to_app ~reader ~writer ()
  |> handle_server_error

(** Create the appropriate pipes to talk to the websocket server *)
let create_ws_pipes =
  let app_to_ws, sender_write = Pipe.create () in
  let receiver_read, ws_to_app = Pipe.create () in
  (app_to_ws, ws_to_app, sender_write, receiver_read)

(** Handle a new connection *)
let handle_client addr reader writer =
  let addr_str = Socket.Address.to_string addr in
  Log.debug "New connection from %s" addr_str;
  let app_to_ws, ws_to_app, sender_write, receiver_read = create_ws_pipes in
  let _text_read, text_write = Pipe.create () in
  Deferred.any
    [
      create_server app_to_ws ws_to_app reader writer;
      client_loop addr_str receiver_read sender_write text_write;
    ]

(** Start the websocket server *)
let start port =
  Log.info "Starting server on port %d" port;
  let%bind _server =
    Tcp.(
      Server.create ~on_handler_error:`Ignore
        (Where_to_listen.of_port port)
        handle_client)
  in
  Deferred.never ()
