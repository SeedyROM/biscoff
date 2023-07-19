open Core
open Async

type route_type = [ `Room ]

module Subscriber = struct
  type 'a t = { id : string; writer : 'a Pipe.Writer.t }

  let create ~id ~writer = { id; writer }
  let send t ~data = Pipe.write_without_pushback t.writer data
end

module Route = struct
  type 'a t = {
    path : string;
    route_type : route_type;
    subscribers : (string, 'a Subscriber.t) Hashtbl.t;
  }

  let create ~path ~route_type =
    { path; route_type; subscribers = Hashtbl.create (module String) }

  let subscribe t ~id ~writer =
    let subscriber = Subscriber.create ~id in
    Hashtbl.add_exn t.subscribers ~key:id ~data:(Subscriber.create ~id ~writer);
    subscriber

  let unsubscribe t ~id = Hashtbl.remove t.subscribers id

  let broadcast t ~data =
    Hashtbl.iter t.subscribers ~f:(fun subscriber ->
        Subscriber.send subscriber ~data)

  let subscribers t = Hashtbl.data t.subscribers
end

type 'a t = { routes : (string, 'a Route.t) Hashtbl.t }

let create () = { routes = Hashtbl.create (module String) }

let add_route t ~path ~route_type =
  let route = Route.create ~path ~route_type in
  Hashtbl.add_exn t.routes ~key:path ~data:route;
  route

let remove_route t ~path = Hashtbl.remove t.routes path
let get_route t ~path = Hashtbl.find t.routes path

let broadcast t ~path ~data =
  match get_route t ~path with
  | None -> ()
  | Some route -> Route.broadcast route ~data

let subscribe t ~path ~id ~writer =
  match get_route t ~path with
  | None -> None
  | Some route -> Some (Route.subscribe route ~id ~writer)

let unsubscribe t ~path ~id =
  match get_route t ~path with
  | None -> ()
  | Some route -> Route.unsubscribe route ~id
