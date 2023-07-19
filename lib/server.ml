open Async
open Core
open Websocket_async
module Log = Log.Global

module Connection = struct
  type t = {
    addr : string;
    reader : Frame.t Pipe.Reader.t;
    writer : Frame.t Pipe.Writer.t;
  }

  let create addr reader writer = { addr; reader; writer }
end

module Connections = struct
  type t = { connections : (string, Connection.t) Hashtbl.t }

  let create () = { connections = Hashtbl.create (module String) }

  let add t addr reader writer =
    Log.debug "New connection from %s" addr;
    Hashtbl.add_exn t.connections ~key:addr
      ~data:(Connection.create addr reader writer)

  let remove t addr =
    Log.debug "Connection closed by %s" addr;
    Hashtbl.remove t.connections addr

  let get t addr = Hashtbl.find t.connections addr
  let get_all t = Hashtbl.data t.connections

  let get_all_except t addr =
    Hashtbl.filteri t.connections ~f:(fun ~key ~data:_ ->
        not (String.equal key addr))
    |> Hashtbl.data
end

module Context = struct
  type t = { clients : Connections.t; msg_router : Frame.t Router.t }

  let create () =
    { clients = Connections.create (); msg_router = Router.create () }
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
let client_loop (ctx : Context.t) addr receiver_read _sender_write =
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
              let message = Printf.sprintf "%s: %s" addr content in
              let new_frame = Frame.create ~opcode:Text ~content:message () in
              Router.broadcast ctx.msg_router ~path:"all" ~data:new_frame;
              Deferred.unit
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
  | Error err when Poly.equal (Error.to_exn err) End_of_file -> Deferred.unit
  | Error err -> Error.raise err
  | Ok () -> Deferred.unit

(** Create a websocket server waiting for HTTP requests at "/ws" *)
let create_server app_to_ws ws_to_app reader writer =
  server ~check_request ~app_to_ws ~ws_to_app ~reader ~writer ()
  |> handle_server_error

(** Create the appropriate pipes to talk to the websocket server *)
let create_ws_pipes () =
  let app_to_ws, sender_write = Pipe.create () in
  let receiver_read, ws_to_app = Pipe.create () in
  (app_to_ws, ws_to_app, sender_write, receiver_read)

(** Handle a new connection *)
let handle_client (ctx : Context.t) addr reader writer =
  (* Convert the address into a string *)
  let addr_str = Socket.Address.to_string addr in
  Log.debug "New connection from %s" addr_str;

  (* Make the pipes for ws communication *)
  let app_to_ws, ws_to_app, sender_write, receiver_read = create_ws_pipes () in

  (* Add the client to the map *)
  Connections.add ctx.clients addr_str receiver_read sender_write;

  (* Subscribe to the "all" route *)
  let _ =
    Router.subscribe ctx.msg_router ~path:"all" ~id:addr_str
      ~writer:sender_write
  in

  (* Connect the server and start the client loop *)
  let%bind () =
    Deferred.any
      [
        create_server app_to_ws ws_to_app reader writer;
        client_loop ctx addr_str receiver_read sender_write;
      ]
  in

  (* Unsubscribe *)
  let _ = Router.unsubscribe ctx.msg_router ~path:"all" ~id:addr_str in

  (* Remove the client from the map *)
  Connections.remove ctx.clients addr_str;
  Deferred.unit

(** Start the websocket server *)
let start port =
  Log.info "Starting server on port %d" port;
  let ctx = Context.create () in
  (* Add the "all" route to the router *)
  let _ = Router.add_route ctx.msg_router ~path:"all" ~route_type:`Room in
  let%bind server =
    Tcp.(
      Server.create ~on_handler_error:`Ignore
        (Where_to_listen.of_port port)
        (handle_client ctx))
  in
  Tcp.Server.close_finished server
