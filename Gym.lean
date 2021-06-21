/-
Copyright (c) 2021 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Daniel Selsam

An extremely bare-bones REPL for proving in Lean4.

Usage: `lean-gym <declName>` will load `Init` and start a proving environment for `declName`
which expects commands in the form of `<branchId> <tactic-string>`

It is straightforward to extend this to also take:
- module imports
- open declarations
- the current namespace

However, there is currently no way to import *until* a given declaration.
We also currently do no checking that the proof avoids circularity.

Note: unlike most RL environments, we use persistent datastructures and
so we store all active tactic states rather than relying on the user
to recompute each path on every action.

Example (circular) run of `lean-gym Nat.add_comm`:

{"state": "⊢ ∀ (n m : Nat), n + m = m + n",
 "proved": false,
 "error": null,
 "branchId": 0}

> 0 intros

{"state": "n✝ m✝ : Nat\n⊢ n✝ + m✝ = m✝ + n✝",
 "proved": false,
 "error": null,
 "branchId": 1}

> 1 rewrite [Nat.add_comm]

{"state": "n✝ m✝ : Nat\n⊢ m✝ + n✝ = m✝ + n✝",
 "proved": false,
 "error": null,
 "branchId": 2}

> 2 rfl

{"state": null, "proved": true, "error": null, "branchId": null}
-/
import Lean
import Std.Data.HashMap

open Lean Lean.Meta Lean.Elab Lean.Elab.Tactic
open Std (HashMap)

def Lean.MessageLog.getErrorMessages (log : MessageLog) : MessageLog :=
  { msgs := log.msgs.filter fun m => match m.severity with | MessageSeverity.error => true | _ => false }

namespace Gym

abbrev BranchId : Type := Nat

structure Context where

structure State where
  branches : HashMap BranchId Tactic.SavedState := {}
  nextId   : BranchId := 0

abbrev GymM := ReaderT Context (StateRefT State TermElabM)

structure Problem where
  decl          : Name
  -- TODO: parse these from command-line
  imports       : List Import   := [{ module := `Init : Import }]
  openDecls     : List OpenDecl := []
  currNamespace : Name          := Name.anonymous

structure Response : Type where
  branchId : Option Nat   := none
  goals    : Array String := #[]
  errors   : Array String := #[]
  deriving ToJson

partial def replFor (problem : Problem) : IO Unit := do
  let termElabM : TermElabM Unit := do
    match (← getEnv).find? problem.decl with
    | none       => throwError "decl {problem.decl} not found"
    | some cInfo =>
      if ¬ (← isProp cInfo.type) then throwError "decl {problem.decl} not a theorem"
      let mvar ← mkFreshExprMVar (some cInfo.type) (kind := MetavarKind.synthetic)
      let termState : Term.SavedState ← Term.saveState
      let tacticState : Tactic.SavedState := { term := termState, tactic := ⟨[mvar.mvarId!]⟩ }
      let context := {}
      let state := { branches := HashMap.empty.insert 0 tacticState, nextId := 1 }
      (welcome *> repl).run context |>.run' state

  let termElabCtx : Term.Context := {
    fileName := "<Gym>",
    fileMap := { source := "", positions := #[0], lines := #[1] },
    declName? := some (problem.decl ++ "_gym_"),
    errToSorry := false
  }

  let metaM : MetaM Unit := termElabM.run' (ctx := termElabCtx)
  let coreM : CoreM Unit := metaM.run'

  let env ← importModules problem.imports {} 0
  let coreCtx   : Core.Context := { currNamespace := problem.currNamespace, openDecls := problem.openDecls }
  let coreState : Core.State := { env := env }

  let ((), _) ← coreM.toIO coreCtx coreState
  pure ()

where
  welcome : GymM Unit := do
    println! "{toJson (← responseForBranch 0)}"

  ppTacticState (s : Tactic.SavedState) : GymM Format := do
    let mut result : Format := Format.nil
    for goal in s.tactic.goals do
      result := result ++ "\n-----\n" ++ (← Meta.ppGoal goal)
    return result

  responseForBranch (id : BranchId) : GymM Response := do
    let some savedState ← pure ((← get).branches.find? id) | throwError "invalid branch id: {id}"
    let goals ← savedState.tactic.goals.mapM fun g => do toString (← Meta.ppGoal g)
    pure { branchId := id, goals := goals.toArray }

  repl : GymM Unit := do
    IO.print "> "
    let cmd : String ← (← IO.getStdin).getLine
    let response ← processCmd cmd
    println! "{toJson response}"
    repl

  processCmd (cmd : String) : GymM Response := do
    let pos := cmd.find (· == ' ')
    let id : Nat ← parseNat (cmd.toSubstring.take pos).toString
    let some savedState ←  pure ((← get).branches.find? id) | throwError "unknown 'id': {id}"
    let tacticString : String := cmd.toSubstring.drop (pos + 1) |>.toString
    match Parser.runParserCategory (← getEnv) `tactic tacticString "<stdin>" with
    | Except.error err => pure { errors := #[err] }
    | Except.ok stx    => do
      savedState.term.restore
      let tac : TacticM Unit := set savedState.tactic *> evalTactic stx
      let mvarId : MVarId := savedState.tactic.goals.head!
      try
        let unsolvedGoals ← Tactic.run mvarId tac
        if (← getThe Term.State).messages.hasErrors then
          let messages ← (← getThe Term.State).messages.getErrorMessages.toList.toArray
          pure { errors := ← (messages.map Message.data).mapM fun md => md.toString }
        else
          let nextId := (← get).nextId
          let savedState : Tactic.SavedState := { term := (← Term.saveState), tactic := ⟨unsolvedGoals⟩ }
          modify fun s => { s with branches := s.branches.insert nextId savedState, nextId := nextId + 1 }
          responseForBranch nextId
      catch ex =>
        pure { errors := #[← ex.toMessageData.toString] }

  parseNat (s : String) : GymM Nat :=
    match s.toNat? with
    | some k => pure k
    | none   => throwError "String '{s}' cannot be converted to Nat"

end Gym

def parseName (n : String) : Lean.Name :=
  (n.splitOn ".").foldl Lean.Name.mkStr Lean.Name.anonymous

def main (args : List String) : IO Unit := do
  let some LEAN_PATH ← IO.getEnv "LEAN_PATH" | throw (IO.userError "LEAN_PATH not set")
  initSearchPath LEAN_PATH
  let [decl] ← pure args | throw (IO.userError "usage: lean-gym <decl>")
  let problem : Gym.Problem := { decl := parseName decl }
  Gym.replFor problem
