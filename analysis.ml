open Instr

let successors prog_at program pc =
  let pc' = pc + 1 in
  let next = if pc' = Array.length program then [] else [pc'] in
  let resolve = Instr.generic_resolve prog_at program in
  match prog_at program pc with
  | Decl_const _
  | Decl_mut _
  | Assign _
  | Label _
  | Comment _
  | Print _ -> next
  | Goto l | Invalidate (_, l, _) -> [resolve l]
  | Branch (_e, l1, l2) -> [resolve l1; resolve l2]
  | Stop -> []

module VarSet = Set.Make(Variable)

(* Perform forward analysis on some code
 *
 * init_state : Initial input state to instruction 0
 * merge      : current state -> input state -> merge state if changed
 * update     : abstract instruction -> input state -> output state
 * program    : array of abstract instructions
 * prog_at    : program -> index -> instruction at index
 *
 * Returns an array of states for every instruction of the program.
 * Bottom is represented as None *)

let forward_analysis (init_state : 'a)
                     (merge : 'a -> 'a -> 'a option)
                     (update : 'p -> 'a -> 'a)
                     (program : 'p array)
                     (prog_at : 'p array -> int -> Instr.instruction)
                     : 'a option array =
  let program_state = Array.map (fun _ -> ref None) program in
  let rec work = function
    | (in_state, pc) :: rest ->
        let instr = program.(pc) in
        let cell = program_state.(pc) in
        let merged =
          match !cell with
          | None -> Some in_state
          | Some cur_state -> merge cur_state in_state
        in begin match merged with
        | None -> work rest
        | Some merged ->
            cell := Some merged;
            let updated = update instr merged in
            let succs = successors prog_at program pc in
            let new_work = List.map (fun pc -> (updated, pc)) succs in
            work (new_work @ rest)
        end
    | [] -> ()
  in
  work [(init_state, 0)];
  Array.map (fun r -> !r) program_state
