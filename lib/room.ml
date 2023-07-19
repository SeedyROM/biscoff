open Core

type t = { id : Uuid.t; name : string }

let create ~name =
  let rng_state = Random.State.make_self_init () in
  { id = Uuid.create_random rng_state; name }

let id { id; _ } = id
let name { name; _ } = name
