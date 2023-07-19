open Core
open Async
open Biscoff

(** Get the log level from LOG_LEVEL environment variable regardless of case *)
let log_level =
  let log_level = Sys.getenv "LOG_LEVEL" |> Option.value ~default:"info" in
  match String.lowercase log_level with
  | "debug" -> `Debug
  | "info" -> `Info
  | "error" -> `Error
  | _ -> `Info

(** Set the log level *)
let set_log_level =
  let open Log.Global in
  log_level |> set_level

(** Main command to run *)
let main_command =
  Command.async ~summary:"Run the server"
    (let open Command.Let_syntax in
     let%map_open port =
       flag "-port"
         (optional_with_default 8080 int)
         ~doc:"PORT Port to listen on"
     in
     fun () -> Server.start port)

let () =
  set_log_level;
  Command_unix.run main_command
