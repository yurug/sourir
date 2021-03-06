open Instr

(* TODO unify those 3 functions *)
let fresh_var instrs var =
  let cand i = var ^ "_" ^ (string_of_int i) in
  let is_fresh cand_var instr =
    let existing = ModedVarSet.untyped (declared_vars instr) in
    not (VarSet.mem cand_var existing) in
  let rec find i =
    let cand_var = cand i in
    if Array.for_all (is_fresh cand_var) instrs then cand_var else find (i+1) in
  find 1

let fresh_label instrs label =
  let cand i = label ^ "_" ^ (string_of_int i) in
  let is_fresh cand_lab instr = match[@warning "-4"] instr with
    | Label l -> l <> cand_lab
    | _ -> true in
  let rec find i =
    let cand_lab = cand i in
    if Array.for_all (is_fresh cand_lab) instrs
    then cand_lab else find (i+1) in
  find 1

let fresh_version_label (func : afunction) label =
  let cand i = label ^ "_" ^ (string_of_int i) in
  let existing = List.map (fun {label} -> label) func.body in
  let rec find i =
    let cand_lab = cand i in
    if not (List.mem cand_lab existing)
    then cand_lab else find (i+1) in
  find 1

let move instrs from_pc to_pc =
  let (dir, to_pc) = if from_pc > to_pc then (-1, to_pc) else (1, to_pc-1) in
  let from = instrs.(from_pc) in
  let rec move pc =
    if pc != to_pc then begin
      instrs.(pc) <- instrs.(pc+dir);
      move (pc+dir)
    end
  in
  move from_pc;
  instrs.(to_pc) <- from

type pc_map = int -> int

type result = Instr.instructions * pc_map

let subst_pc instrs start_pc len new_instrs pc =
  if pc < start_pc then pc
  else pc - len + Array.length new_instrs

let subst instrs pc len new_instrs =
  Array.concat [
    Array.sub instrs 0 pc;
    new_instrs;
    Array.sub instrs (pc + len) (Array.length instrs - pc - len);
  ], subst_pc instrs pc len new_instrs

let subst_many instrs substs =
  let rec chunks cur_pc substs =
    let chunk_upto pos = Array.sub instrs cur_pc (pos - cur_pc) in
    match substs with
    | (next_pc, len, insert_instrs) :: rest ->
      if next_pc < cur_pc then invalid_arg "subst_many";
      let rest, pc_map = chunks (next_pc + len) rest in
      let pc_map pc =
        subst_pc instrs next_pc len insert_instrs (pc_map pc)
      in
      let instrs = chunk_upto next_pc :: insert_instrs :: rest in
      instrs, pc_map
    | [] -> [chunk_upto (Array.length instrs)], fun pc -> pc
  in
  let compare (pc1, _, _) (pc2, _, _) =
    if pc1 = pc2 then invalid_arg "subst_many";
    Pervasives.compare (pc1 : int) pc2 in
  let instrs, pc_map = chunks 0 (List.sort compare substs) in
  Array.concat instrs, pc_map

(** [split_edge instrs pc label pc']
    splits the edge from a branch instruction in [pc]
    to a [Label label] instruction in [pc'],
    assuming there is no fallthrough to [pc'] -- all
    other predecessors are gotos or branches.

    Before applying it to arbitrary program, we use
    [Transform.remove_fallthroughs_to_label] to make the
    assumption hold.
*)
let split_edge instrs pc label pc' =
  assert (instrs.(pc') = Label label);
  let split_label = fresh_label instrs label in
  let split_edge = [|
    Label split_label;
    Goto label;
  |] in
  (* insert the split edge *)
  let new_instrs, pc_map = subst instrs pc' 0 split_edge in
  let new_branch = match[@warning "-4"] instrs.(pc) with
    | Branch (v, l1, l2) ->
      if l1 = label
      then Branch (v, split_label, l2)
      else if l2 = label
      then Branch (v, l1, split_label)
      else invalid_arg "split_edge"
    | _ -> invalid_arg "split_edge" in
  new_instrs.(pc_map pc) <- new_branch;
  new_instrs, pc_map

let replace_uses_in_instruction old_name new_name instr : instruction =
  let in_simple_expression (exp:simple_expression) : simple_expression =
    match exp with
    | Constant _ -> exp
    | Var x -> if x = old_name then Var new_name else exp in
  let in_expression exp : expression =
    match exp with
    | Simple se -> Simple (in_simple_expression se)
    | Op (op, exps) ->
      Op (op, List.map in_simple_expression exps) in
  let in_arg exp : argument =
    match exp with
    | Arg_by_val e -> Arg_by_val (in_expression e)
    | Arg_by_ref x -> if x = old_name then Arg_by_ref new_name else Arg_by_ref x in
  let in_osr osr : osr_def =
    match osr with
    | Osr_const (x, exp) -> Osr_const (x, in_expression exp)
    | Osr_mut (x, exp) -> Osr_mut (x, in_expression exp)
    | Osr_mut_ref (x, y) ->
      if y = old_name then Osr_mut_ref (x, new_name) else osr
    | Osr_mut_undef _ -> osr in

  match instr with
  | Call (x, f, exs) ->
    assert(x != old_name);   (* -> invalid scope *)
    Call (x, in_expression f, List.map in_arg exs)
  | Stop e ->
    Stop (in_expression e)
  | Return e ->
    Return (in_expression e)
  | Decl_const (x, exp) ->
    assert(x != old_name);   (* -> invalid scope *)
    Decl_const (x, in_expression exp)
  | Decl_mut (x, Some exp) ->
    assert (x != old_name);
    Decl_mut (x, Some (in_expression exp))
  | Assign (x, exp) ->
    Assign (x, in_expression exp)
  | Array_assign (x, index, exp) ->
    let x' = if x = old_name then new_name else x in
    Array_assign (x', in_expression index, in_expression exp)
  | Drop x ->
    if x = old_name then Drop new_name else instr
  | Clear x ->
    if x = old_name then Clear new_name else instr
  | Print exp ->
    Print (in_expression exp)
  | Branch (exp, l1, l2) ->
    Branch (in_expression exp, l1, l2)
  | Osr (exp, f, v, l, osrs) ->
    Osr (in_expression exp, f, v, l,
         List.map in_osr osrs)

  | Decl_mut (x, None)
  | Read x ->
    assert (x != old_name);
    instr

  | Label _ | Goto _ | Comment _ ->
    assert (VarSet.is_empty (used_vars instr));
    instr

let freshen_assign ({instrs} as inp : analysis_input) (def : pc) =
  let uses = Analysis.PcSet.elements (Analysis.uses inp def) in
  let instr = instrs.(def) in
  match[@warning "-4"] instr with
  | Assign (x, exp) ->
    let fresh = fresh_var instrs x in
    instrs.(def) <- Decl_mut (fresh, Some exp);
    List.iter (fun pc ->
      instrs.(pc) <- replace_uses_in_instruction x fresh instrs.(pc)) uses
  | _ ->
    assert(false)
open Instr

let replace_var_in_exp var (exp : simple_expression) (in_exp : expression) : expression =
  let in_simple_exp in_exp =
    match in_exp with
    | Constant _ -> in_exp
    | Var x -> if x = var then exp else in_exp in

  match in_exp with
  | Simple se -> Simple (in_simple_exp se)
  | Op (op, exps) ->
    Op (op, List.map in_simple_exp exps)

let replace_var_in_arg var (exp : simple_expression) (in_arg : argument) : argument =
  let replace = replace_var_in_exp var exp in
  match in_arg with
    | Arg_by_val e -> Arg_by_val (replace e)
    | Arg_by_ref x as a -> assert (var <> x); a

