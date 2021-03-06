(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

module F = Format
module L = Logging

type var =
  | ProgramVar of Pvar.t
  | LogicalVar of Ident.t

let var_compare v1 v2 = match v1, v2 with
  | ProgramVar pv1, ProgramVar pv2 -> Pvar.compare pv1 pv2
  | LogicalVar sv1, LogicalVar sv2 -> Ident.compare sv1 sv2
  | ProgramVar _, _ -> 1
  | LogicalVar _, _ -> -1

let var_equal v1 v2 =
  var_compare v1 v2 = 0

let pp_var fmt = function
  | ProgramVar pv ->
      (Pvar.pp pe_text) fmt pv
  | LogicalVar id ->
      (Ident.pp pe_text) fmt id

module Domain = struct
  module VarMap = PrettyPrintable.MakePPMap(struct
      type t = var
      let compare = var_compare
      let pp_key = pp_var
    end)

  type astate = var VarMap.t

  let initial = VarMap.empty

  let is_bottom _ = false

  (* return true if the key-value bindings in [rhs] are a subset of the key-value bindings in
     [lhs] *)
  let (<=) ~lhs ~rhs =
    VarMap.for_all
      (fun k v ->
         try var_equal v (VarMap.find k lhs)
         with Not_found -> false)
      rhs

  let join astate1 astate2 =
    let keep_if_same _ v1_opt v2_opt = match v1_opt, v2_opt with
      | Some v1, Some v2 ->
          if var_equal v1 v2 then Some v1 else None
      | _ -> None in
    VarMap.merge keep_if_same astate1 astate2

  let widen ~prev ~next ~num_iters:_=
    join prev next

  let pp fmt astate =
    let pp_value = pp_var in
    VarMap.pp ~pp_value fmt astate

  let gen var1 var2 astate =
    (* don't add tautological copies *)
    if var_equal var1 var2
    then astate
    else VarMap.add var1 var2 astate

  let kill_copies_with_var var astate =
    let do_kill lhs_var rhs_var astate_acc =
      if var_equal var lhs_var
      then astate_acc (* kill copies vith [var] on lhs *)
      else
      if var_equal var rhs_var
      then (* delete [var] = [rhs_var] copy, but add [lhs_var] = M(rhs_var) copy*)
        try VarMap.add lhs_var (VarMap.find rhs_var astate) astate_acc
        with Not_found -> astate_acc
      else (* copy is unaffected by killing [var]; keep it *)
        VarMap.add lhs_var rhs_var astate_acc in
    VarMap.fold do_kill astate VarMap.empty

  (* kill the previous binding for [lhs_var], and add a new [lhs_var] -> [rhs_var] binding *)
  let kill_then_gen lhs_var rhs_var astate =
    let already_has_binding lhs_var rhs_var astate =
      try var_equal rhs_var (VarMap.find lhs_var astate)
      with Not_found -> false in
    if var_equal lhs_var rhs_var || already_has_binding lhs_var rhs_var astate
    then astate (* already have this binding; no need to kill or gen *)
    else
      kill_copies_with_var lhs_var astate
      |> gen lhs_var rhs_var
end

module TransferFunctions = struct

  type astate = Domain.astate

  let exec_instr astate = function
    | Sil.Letderef (lhs_id, Sil.Var rhs_id, _, _) ->
        (* note: logical vars are SSA, don't need to worry about overwriting existing bindings *)
        Domain.gen (LogicalVar lhs_id) (LogicalVar rhs_id) astate
    | Sil.Letderef (lhs_id, Sil.Lvar rhs_pvar, _, _) when not (Pvar.is_global rhs_pvar) ->
        Domain.gen (LogicalVar lhs_id) (ProgramVar rhs_pvar) astate
    | Sil.Set (Sil.Lvar lhs_pvar, _, Sil.Var rhs_id, _) when not (Pvar.is_global lhs_pvar) ->
        Domain.kill_then_gen (ProgramVar lhs_pvar) (LogicalVar rhs_id) astate
    | Sil.Set (Sil.Lvar lhs_pvar, _, Sil.Lvar rhs_pvar, _)
      when not (Pvar.is_global lhs_pvar || Pvar.is_global rhs_pvar)  ->
        Domain.kill_then_gen (ProgramVar lhs_pvar) (ProgramVar rhs_pvar) astate
    | Sil.Letderef (lhs_id, _, _, _) ->
        (* non-copy assignment (or assignment to global); can only kill *)
        Domain.kill_copies_with_var (LogicalVar lhs_id) astate
    | Sil.Set (Sil.Lvar lhs_pvar, _, _, _) ->
        (* non-copy assignment (or assignment to global); can only kill *)
        Domain.kill_copies_with_var (ProgramVar lhs_pvar) astate
    | Sil.Call (ret_ids, _, actuals, _, _) ->
        let kill_ret_ids astate_acc id =
          Domain.kill_copies_with_var (LogicalVar id) astate_acc in
        let kill_actuals_by_ref astate_acc = function
          | (Sil.Lvar pvar, Sil.Tptr _) -> Domain.kill_copies_with_var (ProgramVar pvar) astate_acc
          | _ -> astate_acc in
        let astate' = IList.fold_left kill_ret_ids astate ret_ids in
        if !Config.curr_language = Config.Java
        then astate' (* Java doesn't have pass-by-reference *)
        else IList.fold_left kill_actuals_by_ref astate' actuals
    | Sil.Set (Sil.Var _, _, _, _) ->
        (* this should never happen *)
        assert false
    | Sil.Set _ | Sil.Prune _ | Sil.Nullify _ | Sil.Abstract _ | Sil.Remove_temps _
    | Sil.Declare_locals _ | Sil.Goto_node _ | Sil.Stackop _ ->
        (* none of these can assign to program vars or logical vars *)
        astate
end

module Analyzer =
  AbstractInterpreter.Make
    (ProcCfg.Forward)
    (Scheduler.ReversePostorder)
    (Domain)
    (TransferFunctions)

let checker { Callbacks.proc_desc; } = ignore(Analyzer.exec_pdesc proc_desc)
