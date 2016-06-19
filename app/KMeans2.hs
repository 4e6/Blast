{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}


module Main where

import Debug.Trace
import            Control.Concurrent
import            Control.DeepSeq
import qualified  Data.List as L

import qualified  Data.Map.Strict as M
import            Data.Proxy
import            Control.Monad.IO.Class
import            Control.Monad.Operational
import            Control.Monad.Logger
import            Control.Monad.Trans.State
import            Data.Traversable
--import qualified  Data.Vault.Strict as V

import qualified  Data.Vector as V

import            Control.Distributed.Process (RemoteTable)
import            Control.Distributed.Process.Node (initRemoteTable)
import            Control.Distributed.Process.Closure (mkClosure, remotable)

import            System.Environment (getArgs)

import            Blast
import qualified  Blast.Runner.Simple as S
import            Blast.Runner.Local as Loc
import            Blast.Runner.CloudHaskell as CH



type Point = (Double, Double)

dist (x1, y1) (x2, y2) = let
  dx = x2-x1
  dy = y2 -y1
  in dx * dx + dy * dy

p0 :: Point
p0 = (0, 0)

chooseCenter :: M.Map Point (Point, Int) -> Point -> M.Map Point (Point, Int)
chooseCenter centerAndSums p =
  r
  where
--  !r = centerAndSums
  !r = force $ M.insertWith (\((x0, y0), _) ((x, y), n) -> ((x0+x, y0+y), n+1)) bestCenter (p, 1) centerAndSums

  bestCenter = findCenter c d t
  (c:t) = M.keys centerAndSums
  d = dist c p
  findCenter currentCenter currentDist [] = currentCenter
  findCenter currentCenter currentDist (center:t) = let
    d = dist center p
    in  if d < currentDist
        then findCenter center d t
        else findCenter currentCenter currentDist t


computeNewCenters :: [M.Map Point (Point, Int)] -> M.Map Point Point
computeNewCenters l =
  y
  where
  l' = do
    m <- l
    M.toList m
  x::M.Map Point [(Point, Int)]
  x = L.foldl' (\m (c, (p,n)) -> M.insertWith (++) c [(p, n)] m) M.empty l'
  y::M.Map Point Point
  y = M.map (\l -> let (ps, ns) = L.unzip l
                       (xs, ys) = L.unzip ps
                       sumX = sum xs
                       sumY = sum ys
                       n = sum ns
                       r = (sumX / (fromIntegral n), sumY / (fromIntegral n))
                       in r)
            x

deltaCenter :: M.Map Point Point -> Double
deltaCenter centers =
  r
  where
  r = maximum l
  l = L.map (\(p1, p2) -> sqrt $  dist p1 p2) $ M.toList centers

expGenerator :: Int -> Computation ([Point], Double) [Point]
expGenerator nbPoints (centers, var) = do
      range <- rconst $ Range 0 nbPoints
      centers0 <- lconst $ M.fromList $ L.map (\c -> (c, (p0, 0::Int))) centers
      points <- rapply' (fun(\r -> L.map (\i -> ((fromIntegral i) / fromIntegral nbPoints , (fromIntegral i) / fromIntegral nbPoints)) $ rangeToList r)) range

      centerMap <- rfold' (foldFun chooseCenter) computeNewCenters centers0 points
      var' <- deltaCenter <$$> centerMap
      centers' <- M.elems <$$> centerMap
      lpoints <- collect points
      r <- (,) <$$> centers' <**> var'
      (,) <$$> r <**> centers'


criterion tol (_, x) (_, y::Double) _ = abs (x - y) < tol

--jobDesc :: JobDesc ([Point], Double) [Point]
jobDesc = MkJobDesc ([(0.0, 0.0), (1.0, 1.0)], 1000.0) (expGenerator 10000000) reporting (criterion 0.1)


rloc:: IO ()
rloc = do
  let cf = MkConfig 1.0
  s <- logger $ Loc.createController cf 1 jobDesc
  (a,b) <- logger $ Loc.runRec cf s jobDesc
  print a
  print b
  return ()
  where
  logger a = runLoggingT a (\_ _ _ _ -> return ())



reporting a b = do
  putStrLn "Reporting"
  putStrLn "End Reporting"
  return a





rpcConfigAction = return $
  MkRpcConfig
    (MkConfig 1.0)
    (MkMasterConfig runStdoutLoggingT)
    (MkSlaveConfig runStdoutLoggingT)


slaveClosure = CH.slaveProcess rpcConfigAction jobDesc

remotable ['slaveClosure]

rtable :: RemoteTable
rtable = __remoteTable initRemoteTable


ch = do
  args <- getArgs
  rpcConfig <- rpcConfigAction
  CH.runRec rtable rpcConfig args jobDesc $(mkClosure 'slaveClosure) k
  where
  k a b = do
--    print a
 --   print b
    print "=========="

main = ch

simple :: IO ()
simple = do
  (a,b) <- logger $ S.runRec jobDesc
  print a
  print b
  return ()
  where
  logger a = runLoggingT a (\_ _ _ _ -> return ())