module Solver where

import Constraint
import Control.Monad.State
import qualified Data.Map as Map
import qualified Control.Monad.Trans.UnionFind as UF
import qualified Common


unifyTypes :: ConType -> ConType -> ConstraintM ConType
--unify two variables
unifyTypes (VarType t1) (VarType t2) = do
  r1 <- UF.descriptor $ getUF t1
  r2 <- UF.descriptor $ getUF t2
  --Union the identifiers
  UF.union (getUF t1) (getUF t2)
  case (r1, r2) of
    (BlankSlate, BlankSlate) ->
      return (VarType t2)
    pair -> do
      newRepr <-
        case pair of
          (BlankSlate, TypeRepr t2) ->
            return t2
          (TypeRepr t1, BlankSlate) ->
            return t1
          (TypeRepr t1, TypeRepr t2) ->
            unifyTypes t1 t2
      --Set the descriptor of our variable to be our newly computed unifier
      dummyPoint <- UF.fresh (TypeRepr newRepr)
      UF.union dummyPoint (getUF t1)
      return newRepr


--Unify a variable with something: look at its descriptor
--If it's blank, then set its descriptor to whatever we union with
--Otherwise, unify our descriptor with the whatever type we see
unifyTypes (VarType tvar) t2 = do
  r1 <- UF.descriptor $ getUF tvar
  case r1 of
    BlankSlate -> do
      dummyPoint <- UF.fresh (TypeRepr t2)
      UF.union (getUF tvar) dummyPoint
      return t2

    TypeRepr t1 ->
      unifyTypes t1 t2

--Same as above, but reversed --TODO just recurse?
unifyTypes t2 (VarType tvar) = do
  r1 <- UF.descriptor $ getUF tvar
  case r1 of
    BlankSlate -> do
      dummyPoint <- UF.fresh (TypeRepr t2)
      UF.union (getUF tvar) dummyPoint
      return t2
    TypeRepr t1 ->
      unifyTypes t1 t2

unifyTypes (LitType v1) (LitType v2) =
  error "TODO beta equality"

unifyTypes (PiType t1 f1) (PiType t2 f2) = do
  piArg <- unifyTypes t1 t2
  piBody <- unifyFns f1 f2
  return $ PiType piArg piBody


unifyTypes (AppType f1 t1) (AppType f2 t2) =
  case (toRealType t1, toRealType t2, toRealFn f1, toRealFn f2) of
    (Just v1, Just v2, Just rf1, Just rf2) ->
      betaEqual (rf1 v1) (rf2 v2)
    _ ->
      error "Can't apply function still containing variables"

unifyTypes _ _ = error "Unification failed!"

toRealType :: ConType -> Maybe Common.Type_
toRealType = _

toRealFn :: ConTyFn -> Maybe (Common.Type_ -> Common.Type_)
toRealFn = _

unifyFns = _

betaEqual = _
