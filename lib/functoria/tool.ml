(*
 * Copyright (c) 2013-2020 Thomas Gazagnaire <thomas@gazagnaire.org>
 * Copyright (c) 2013-2020 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2015-2020 Gabriel Radanne <drupyog@zoho.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Astring
open Action.Infix
open DSL

let src = Logs.Src.create "functoria.tool" ~doc:"functoria library"

module Log = (val Logs.src_log src : Logs.LOG)

module type S = sig
  val name : string

  val version : string

  val packages : package list

  val create : job impl list -> job impl
end

module Make (P : S) = struct
  module Filegen = Filegen.Make (P)

  let build_dir t = Fpath.parent t.Cli.config_file

  (* Generate a `dune.config` file in the build directory. *)
  let generate_dune_config t =
    let file = Fpath.v "dune.config" in
    let pkgs =
      match P.packages with
      | [] -> ""
      | pkgs ->
          let pkgs =
            List.fold_left
              (fun acc pkg ->
                let pkgs = String.Set.of_list (Package.libraries pkg) in
                String.Set.union pkgs acc)
              String.Set.empty pkgs
            |> String.Set.elements
          in
          String.concat ~sep:" " pkgs
    in
    let config_file = Fpath.(basename (rem_ext t.Cli.config_file)) in
    let contents =
      Fmt.strf
        {|(executable
  (name config)
  (flags (:standard -warn-error -A))
  (modules %s)
  (libraries %s))
|}
        config_file pkgs
    in
    Filegen.write file contents

  (* Generate a `dune.config` file in the build directory. *)
  let generate_empty_dune_build () = Filegen.write (Fpath.v "dune.build") "\n"

  (* Generate a `dune` file in the build directory. *)
  let generate_dune () =
    let file = Fpath.v "dune" in
    let contents = "(include dune.config)\n\n(include dune.build)\n" in
    Filegen.write file contents

  (* Generate a `dune-project` file at the project root. *)
  let generate_dune_project () =
    let file = Fpath.(v "dune-project") in
    let contents = "(lang dune 1.1)\n" in
    Filegen.write file contents

  (* Generate the configuration files in the the build directory *)
  let generate_configuration_files t =
    Log.info (fun m -> m "Compiling: %a" Fpath.pp t.Cli.config_file);
    generate_dune_project () >>= fun () ->
    Action.with_dir (build_dir t) (fun () ->
        generate_dune_config t >>= fun () ->
        generate_empty_dune_build () >>= fun () -> generate_dune ())

  let run_cmd ?ppf ?err_ppf command =
    match ppf with
    | None -> Action.run_cmd ?err:err_ppf command
    | Some help_ppf ->
        Action.run_cmd_out ?err:err_ppf command >|= fun output ->
        Fmt.pf help_ppf "%s%!" output

  (* Generated a project skeleton and try to compile config.exe. *)
  let check_project t ?ppf ?err_ppf () =
    generate_configuration_files t >>= fun () ->
    let command =
      Bos.Cmd.(v "dune" % "build" % p Fpath.(build_dir t / "config.exe"))
    in
    run_cmd ?ppf ?err_ppf command

  (* re-exec the command by calling config.exe with the same argv as
     the current command. *)
  let re_exec t ?ppf ?err_ppf argv =
    let args = Bos.Cmd.of_list (List.tl (Array.to_list argv)) in
    let command =
      Bos.Cmd.(
        v "dune"
        % "exec"
        % "--root"
        % "."
        % "--"
        % p Fpath.(build_dir t / "config.exe")
        %% args)
    in
    run_cmd ?ppf ?err_ppf command

  let exit_err t = function
    | Ok v -> v
    | Error (`Msg m) ->
        flush_all ();
        if m <> "" then Fmt.epr "%a\n%!" Fmt.(styled (`Fg `Red) string) m;
        if not t.Cli.dry_run then exit 1 else Fmt.epr "(exit 1)\n%!"

  let handle_parse_args_no_config ?help_ppf ?err_ppf (`Msg error) argv =
    let base_context =
      (* Extract all the keys directly. Useful to pre-resolve the keys
         provided by the specialized DSL. *)
      let base_keys = Engine.all_keys @@ Device_graph.create (P.create []) in
      Cmdliner.Term.(
        pure (fun _ -> Action.ok ())
        $ Key.context base_keys ~with_required:false ~stage:`Configure)
    in
    let niet = Cmdliner.Term.pure (Action.ok ()) in
    let result =
      Cli.eval ?help_ppf ?err_ppf ~name:P.name ~version:P.version
        ~configure:niet ~query:niet ~describe:niet ~build:niet ~clean:niet
        ~help:base_context argv
    in
    let ok = Action.ok () in
    let error = Action.error error in
    match result with `Version | `Help | `Ok (Cli.Help _) -> ok | _ -> error

  let handle_parse_args t ?ppf ?err_ppf argv =
    let file = t.Cli.config_file in
    Action.is_file file >>= function
    | true ->
        check_project t ?ppf ?err_ppf () >>= fun () ->
        re_exec t ?ppf ?err_ppf argv
    | false ->
        let msg = Fmt.str "configuration file %a missing" Fpath.pp file in
        handle_parse_args_no_config ?help_ppf:ppf ?err_ppf (`Msg msg) argv

  let action_run t a =
    if not t.Cli.dry_run then Action.run a
    else
      let env =
        let commands cmd =
          match Bos.Cmd.line_exec cmd with
          | Some "dune" -> Some ("[...]", "")
          | _ -> None
        in
        Action.env ~commands ~files:(`Passtrough (Fpath.v ".")) ()
      in
      let r, _, lines = Action.dry_run ~env a in
      List.iter
        (fun line ->
          Fmt.epr "%a %s\n%!" Fmt.(styled (`Fg `Cyan) string) "*" line)
        lines;
      r

  let parse args ?help_ppf ?err_ppf argv =
    handle_parse_args args ?ppf:help_ppf ?err_ppf argv
    |> action_run args
    |> exit_err args

  let run_with_argv ?help_ppf ?err_ppf argv =
    match Cli.peek ~with_setup:true argv with
    | `Version -> Fmt.pr "%s\n%!" P.version
    | `Error (args, _) -> parse args ?help_ppf ?err_ppf argv
    | `Ok t -> parse (Cli.args t) ?help_ppf ?err_ppf argv

  let run () = run_with_argv Sys.argv
end
