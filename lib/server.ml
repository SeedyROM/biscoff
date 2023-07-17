open Async
open Core
open Websocket_async
module Log = Log.Global

type client_connection = {
  addr : string;
  reader : Frame.t Pipe.Reader.t;
  writer : Frame.t Pipe.Writer.t;
}

type client_map = (string, client_connection) Hashtbl.t

module ClientMap = struct
  let add clients addr reader writer =
    Log.debug "New connection from %s" addr;
    Hashtbl.add_exn clients ~key:addr ~data:{ addr; reader; writer }

  let remove clients addr =
    Log.debug "Connection closed by %s" addr;
    Hashtbl.remove clients addr

  let get clients addr = Hashtbl.find clients addr
  let get_all clients = Hashtbl.data clients

  let get_all_except clients addr =
    Hashtbl.filteri clients ~f:(fun ~key ~data:_ -> not (String.equal key addr))
    |> Hashtbl.data
end

type server_context = { clients : client_map }

module ServerContext = struct
  type t = server_context

  let create () = { clients = Hashtbl.create (module String) }
end

(** Create a websocket server *)
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
let client_loop server_context addr receiver_read _sender_write =
  let rec loop () =
    match%bind Pipe.read receiver_read with
    | `Eof ->
        Log.debug "Connection closed by %s" addr;
        return ()
    | `Ok ({ Frame.opcode; content; _ } as frame) ->
        let open Frame in
        let frame', closed = parse_frame frame content opcode addr in

        let%bind () =
          match frame'.opcode with
          | Opcode.Text ->
              (* Send the frame to each client in the client_map *)
              let clients =
                ClientMap.get_all_except server_context.clients addr
              in
              Deferred.List.iter clients ~f:(fun client ->
                  Pipe.write client.writer frame')
          | _ -> Deferred.unit
        in

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
let handle_client server_context addr reader writer =
  (* Convert the address into a string *)
  let addr_str = Socket.Address.to_string addr in
  Log.debug "New connection from %s" addr_str;
  (* Make the pipes for ws communication *)
  let app_to_ws, ws_to_app, sender_write, receiver_read = create_ws_pipes in
  (* Add the client to the map *)
  ClientMap.add server_context.clients addr_str receiver_read sender_write;
  (* Connect the server and start the client loop *)
  let%bind () =
    Deferred.any
      [
        create_server app_to_ws ws_to_app reader writer;
        client_loop server_context addr_str receiver_read sender_write;
      ]
  in
  (* Remove the client from the map *)
  ClientMap.remove server_context.clients addr_str;
  Deferred.unit

(** Start the websocket server *)
let start port =
  Log.info "Starting server on port %d" port;
  let server_context = ServerContext.create () in
  let%bind _server =
    Tcp.(
      Server.create ~on_handler_error:`Ignore
        (Where_to_listen.of_port port)
        (handle_client server_context))
  in
  Deferred.never ()
