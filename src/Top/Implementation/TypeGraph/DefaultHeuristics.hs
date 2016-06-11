{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS -Wall #-}
-----------------------------------------------------------------------------
-- | License      :  GPL
--
--   Maintainer   :  helium@cs.uu.nl
--   Stability    :  provisional
--   Portability  :  portable
-----------------------------------------------------------------------------

module Top.Implementation.TypeGraph.DefaultHeuristics where

import Data.List
import qualified Data.Map as M
import Top.Implementation.TypeGraph.ApplyHeuristics (expandPath)
import Top.Implementation.TypeGraph.Basics
import Top.Implementation.TypeGraph.Heuristic
import Top.Implementation.TypeGraph.Path
import qualified Top.Implementation.TypeGraph.Class as Class
import Top.Solver

import qualified Data.List as List
import qualified Data.Maybe as Maybe

import Top.Implementation.TypeGraph.ClassMonadic

import PatternUnify.ConstraintInfo as Info
import PatternUnify.Tm as Tm
import PatternUnify.Check as Check

import Control.Monad

import Unbound.Generics.LocallyNameless.Unsafe  (unsafeUnbind)

type Info = Info.ConstraintInfo


--import Debug.Trace (trace)

-----------------------------------------------------------------------------

defaultHeuristics :: Path (EdgeId, Info) -> [Heuristic Info]
defaultHeuristics path =
   [ --avoidDerivedEdges
   listOfVotes
   , highParticipation 1.0 path
   , firstComeFirstBlamed ]

-----------------------------------------------------------------------------

-- |Compute the smallest 'minimal' sets. This computation is very(!) costly
--   (might take a long time for complex inconsistencies)
inMininalSet :: Path (EdgeId, info) -> Heuristic info
inMininalSet path =
   Heuristic (
      let sets       = minimalSets eqInfo2 path
          candidates = nubBy eqInfo2 (concat sets)
          f e        = return (any (eqInfo2 e) candidates)
      in edgeFilter "In a smallest minimal set" f)

-- |Although not as precise as the minimal set analysis, this calculates the participation of
-- each edge in all error paths.
-- Default ratio = 1.0  (100 percent)
--   (the ratio determines which scores compared to the best are accepted)
--Altered from the original to consider edges by their root creator edge
highParticipation :: Show info => Double -> Path (EdgeId, info) -> Heuristic info
highParticipation ratio path =
   Heuristic (Filter ("Participation ratio [ratio="++show ratio++"]") selectTheBest)
 where
   selectTheBest es =
      let (nrOfPaths, fm)   = participationMap (mapPath (\(EdgeId _ _ cnr,_) -> cnr) path)
          participationList = M.filterWithKey p fm
          p cnr _    = cnr `elem` activeCNrs
          activeCNrs = [ cnr | (EdgeId _ _ cnr, _) <- es ]
          maxInList  = maximum (M.elems participationList)
          limit     -- test if one edge can solve it completely
             | maxInList == nrOfPaths = maxInList
             | otherwise              = round (fromIntegral maxInList * ratio) `max` 1
          goodCNrs   = M.keys (M.filter (>= limit) participationList)
          bestEdges  = filter (\(EdgeId _ _ cnr,_) -> cnr `elem` goodCNrs) es

          -- prints a nice report
          mymsg  = unlines ("" : title : replicate 50 '-' : map f es)
          title  = "cnr  edge          ratio   info"
          f (edgeID@(EdgeId _ _ cnr),info) =
             take 5  (show cnr++(if cnr `elem` goodCNrs then "*" else "")++repeat ' ') ++
             take 14 (show edgeID++repeat ' ') ++
             take 8  (show (M.findWithDefault 0 cnr fm * 100 `div` nrOfPaths)++"%"++repeat ' ') ++
             "{"++show info++"}"
      in do logMsg mymsg
            return bestEdges

-- |Select the "latest" constraint
firstComeFirstBlamed :: Heuristic info
firstComeFirstBlamed =
   Heuristic (
      let f (EdgeId _ _ cnr, _) = return cnr
      in maximalEdgeFilter "First come, first blamed" f)

-- |Select only specific constraint numbers
selectConstraintNumbers :: [EdgeNr] -> Heuristic info
selectConstraintNumbers is =
   Heuristic (
      let f (EdgeId _ _ cnr, _) = return (cnr `elem` is)
      in edgeFilter ("select constraint numbers " ++ show is) f)


-- |Select only specific constraint numbers
avoidDerivedEdges :: Heuristic Info
avoidDerivedEdges =
   Heuristic (
      let f (_, info) = return $ (Info.creationInfo . Info.edgeEqnInfo) info == Info.Initial
      in edgeFilter ("avoid derived edges ") f)


listOfVotes =
  Heuristic $ Voting $
    [ preferChoiceEdges
    , ctorPermutation
    ]

preferChoiceEdges :: (HasTypeGraph m Info) => Selector m Info
preferChoiceEdges = Selector ("Choice edges", f)
  where
    f pair@(edge@(EdgeId vc _ _), info) = case Info.edgeType info of
      ChoiceEdge Info.LeftChoice _ _ -> do
        currentConstants <- constantsInGroupOf vc
        newConstants <- doWithoutEdge pair $ constantsInGroupOf vc
        case (length currentConstants > length newConstants) of
          True -> return $ Just (10, "Choice", [edge], info)
          _ -> return Nothing
      _ -> return Nothing



instance HasTwoTypes ConstraintInfo where
   getTwoTypes = Info.edgeEqn

ctorPermutation :: (HasTypeGraph m Info) => Selector m Info
ctorPermutation = Selector ("Constructor isomorphism", f)
  where
    f pair@(edge@(EdgeId vc _ _), info) = do
      let rawT = typeOfValues info
      mT <- substituteTypeSafe rawT
      (mt1, mt2) <- getSubstitutedTypes info
      case (mt1, mt2, mT) of
        (Just t1@(Tm.C can args), Just t2@(Tm.C can2 args2), Just _T) | can == can2 -> do
          maybeMatches <- forM (List.permutations args2) $ \permut -> do
             if Check.unsafeEqual _T (Tm.C can args) (Tm.C can permut) then
                 return $ Just permut
               else
                 return Nothing
          case (Maybe.catMaybes maybeMatches) of
            [] ->
              return Nothing
            (match : _) -> do
              let hint = "Rearrange arguments to match " ++ Tm.prettyString t1 ++ " to " ++ Tm.prettyString t2
              return $ Just (10, "Mismatched arguments", [edge], info {maybeHint = Just hint})

        _ -> return Nothing

--Useful helper method



appHeuristic :: (HasTypeGraph m Info) => Selector m Info
appHeuristic = Selector ("Function Application", f)
  where
    maxArgs :: Tm.Type -> Maybe Int
    maxArgs _T = maxArgsHelper _T 0
      where
        maxArgsHelper (Tm.PI _S (Tm.L body)) accum =
          maxArgsHelper (snd $ unsafeUnbind body) (1+accum)
        maxArgsHelper (Tm.N (Tm.Meta _) _) _ = Nothing
        maxArgsHelper _T accum =  Just accum

    f pair@(edge@(EdgeId vc _ _), info) | (Application reg argNum args retTp frees) <- (programContext $ edgeEqnInfo info) = do
      --let (fnTyEdge:_) = [x | x <- edges]
      edges <- allEdges
      let (fnTy, fnAppEdge) : _ = [(fTy, pr) | pr <- edges, AppFnType subReg fTy <- [programContext $ edgeEqnInfo $ snd pr], subReg == reg]

      mFullFnTp <- doWithoutEdge fnAppEdge $ substituteTypeSafe fnTy
      case mFullFnTp of
        Just fullFnTp -> do
          let fnMax = maxArgs fullFnTp
          case (fnMax) of
            (Just n) | n < length args -> do
              let hint = "Function expected at most " ++ show n ++ " arguments, but you gave " ++ show (length args)
              return $ Just (10, "Too many arguments", [edge], info {maybeHint = Just hint})
            _ -> do
              return Nothing
        _ -> return Nothing

    f _ = return Nothing

-- -- |Select only the constraints for which there is evidence in the predicates
-- -- of the current state that the constraint at hand is incorrect.
-- inPredicatePath :: Heuristic info
-- inPredicatePath =
--    Heuristic (Filter "in a predicate path" f) where
--
--     f xs =
--        do pp  <- predicatePath
--           path <- expandPath (simplifyPath pp)
--           let cnrs = nub [ c | (EdgeId _ _ c, _) <- steps path ]
--               p (EdgeId _ _ cnr, _) = cnr `elem` cnrs
--               ys = filter p xs
--           return (if null ys then xs else ys)
