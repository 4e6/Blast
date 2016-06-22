{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Blast.Types
where


import qualified  Control.Lens as Lens (set, view, makeLenses)
import            Control.Monad.Operational
import qualified  Data.List as L
import qualified  Data.Map as M
import qualified  Data.Set as S
import qualified  Data.Serialize as S
import qualified  Data.Vector as Vc


data GenericInfo i = GenericInfo {
  _refs :: S.Set Int -- set of parents, that is, nodes that reference this node
  , _info :: i
  }

$(Lens.makeLenses ''GenericInfo)

type GenericInfoMap i = M.Map Int (GenericInfo i)

type Computation a b = forall e m. (Monad m, Builder m e) =>
  a -> Control.Monad.Operational.ProgramT (Syntax m) m (e 'Local (a, b))


data Kind = Remote | Local

type Partition a = Vc.Vector a


class Chunkable a where
  chunk :: Int -> a -> Partition a

class UnChunkable a where
  unChunk :: [a] -> a

class ChunkableFreeVar a where
  chunk' :: Int -> a -> Partition a
  chunk' n a = Vc.generate n (const a)


data Fun e a b =
  Pure (a -> IO b)
  |forall c . (S.Serialize c, ChunkableFreeVar c) => Closure (e 'Local c) (c -> a -> IO b)

data FoldFun e a r =
  FoldPure (r -> a -> IO r)
  |forall c . (S.Serialize c,ChunkableFreeVar c) => FoldClosure (e 'Local c) (c -> r -> a -> IO r)

data ExpClosure e a b =
  forall c . (S.Serialize c, ChunkableFreeVar c) => ExpClosure (e 'Local c) (c -> a -> IO b)


class Indexable e where
  getIndex :: e (k::Kind) a -> Int

class (Indexable e) => Builder m e where
  makeRApply :: Int -> ExpClosure e a b -> e 'Remote a -> m (e 'Remote b)
  makeRConst :: (Chunkable a, S.Serialize a) => Int -> a -> m (e 'Remote a)
  makeLConst :: Int -> a -> m (e 'Local a)
  makeCollect :: (UnChunkable a, S.Serialize a) => Int -> e 'Remote a -> m (e 'Local a)
  makeLApply :: Int -> e 'Local (a -> b) -> e 'Local a -> m (e 'Local b)
  fuse :: GenericInfoMap () -> Int -> e 'Remote a -> m (e 'Remote a, GenericInfoMap (), Int)

data Syntax m e where
  StxRApply :: (Builder m e) => ExpClosure e a b -> e 'Remote a -> Syntax m (e 'Remote b)
  StxRConst :: (Builder m e, Chunkable a, S.Serialize a) => a -> Syntax m (e 'Remote a)
  StxLConst :: (Builder m e) => a -> Syntax m (e 'Local a)
  StxCollect :: (Builder m e, UnChunkable a, S.Serialize a) => e 'Remote a -> Syntax m (e 'Local a)
  StxLApply :: (Builder m e) => e 'Local (a -> b) -> e 'Local a -> Syntax m (e 'Local b)


rapply :: (Builder m e) =>
  ExpClosure e a b -> e 'Remote a -> ProgramT (Syntax m) m (e 'Remote b)
rapply f a = singleton (StxRApply f a)

rconst :: (S.Serialize a, Builder m e, Chunkable a) =>
  a -> ProgramT (Syntax m) m (e 'Remote a)
rconst a = singleton (StxRConst a)

lconst :: (Builder m e) =>
  a -> ProgramT (Syntax m) m (e 'Local a)
lconst a = singleton (StxLConst a)

collect :: (S.Serialize a, Builder m e, UnChunkable a) =>
  e 'Remote a -> ProgramT (Syntax m) m (e 'Local a)
collect a = singleton (StxCollect a)

lapply :: (Builder m e) =>
  e 'Local (a -> b) -> e 'Local a -> ProgramT (Syntax m) m (e 'Local b)
lapply f a = singleton (StxLApply f a)




refCount :: Int -> GenericInfoMap i -> Int
refCount n m =
  case M.lookup n m of
    Just inf -> S.size $ Lens.view refs inf
    Nothing -> error ("Ref count not found for node: " ++ show n)



reference :: Int -> Int -> GenericInfoMap i -> GenericInfoMap i
reference parent child map = do
  case M.lookup child map of
    Just inf@(GenericInfo old _) -> M.insert child (Lens.set refs (S.insert parent old) inf) map
    Nothing -> error $  ("Node " ++ show child ++ " is referenced before being visited")

{-
data RefExp (k::Kind) a where
  RefRApply :: Int -> ExpClosure Exp a b -> RefExp 'Remote a -> RefExp 'Remote b
  RefRConst :: Int -> a -> RefExp 'Remote a
  RefLConst :: Int -> a -> RefExp 'Local a
  RefCollect :: Int -> RefExp 'Remote a -> RefExp 'Local a
  RefLApply :: Int -> RefExp 'Local (a -> b) -> RefExp 'Local a -> RefExp 'Local b


instance (Monad m) => Builder m RefExp where
  makeRApply n f a = do
    return $ RefRApply n f a
  makeRConst n a = do
    return $ RefRConst n a
  makeLConst n a = do
    return $ RefLConst n a
  makeCollect n a = do
    return $ RefCollect n a
  makeLApply n f a = do
    return $ RefLApply n f a
  getIndex (RefRApply n _ _) = n
  getIndex (RefRConst n _) = n
  getIndex (RefLConst n _) = n
  getIndex (RefCollect n _) = n
  getIndex (RefLApply n _ _) = n
  fuse refMap n e = return (e, refMap, n)
-}

generateReferenceMap ::forall a m e. (Builder m e, Monad m) =>  Int -> GenericInfoMap () -> ProgramT (Syntax m) m (e 'Local a) -> m (GenericInfoMap (), Int)
generateReferenceMap counter map p = do
    pv <- viewT p
    eval pv
    where
    eval :: (Builder m e, Monad m) => ProgramViewT (Syntax m) m (e 'Local a) -> m (GenericInfoMap(), Int)
    eval (StxRApply cs@(ExpClosure ce _) a :>>=  is) = do
      e <- makeRApply counter cs a
      let map' = reference counter (getIndex ce) map
      let map'' = reference counter (getIndex a) map'
      generateReferenceMap (counter+1) map'' (is e)
    eval (StxRConst a :>>=  is) = do
      e <- makeRConst counter a
      generateReferenceMap (counter+1) map (is e)
    eval (StxLConst a :>>=  is) = do
      e <- makeLConst counter a
      generateReferenceMap (counter+1) map (is e)
    eval (StxCollect a :>>=  is) = do
      e <- makeCollect counter a
      let map' = reference counter (getIndex a) map
      generateReferenceMap (counter+1) map' (is e)
    eval (StxLApply f a :>>=  is) = do
      e <- makeLApply counter f a
      let map' = reference counter (getIndex f) map
      let map'' = reference counter (getIndex a) map'
      generateReferenceMap (counter+1) map'' (is e)
    eval (Return a) = return (map, counter)



build ::forall a m e. (Builder m e, Monad m) => Bool -> GenericInfoMap () -> Int -> Int -> ProgramT (Syntax m) m (e 'Local a)  -> m (e 'Local a)
build shouldOptimize refMap counter fuseCounter p = do
    pv <- viewT p
    eval pv
    where
    eval :: (Builder m e, Monad m) => ProgramViewT (Syntax m) m (e 'Local a) -> m (e 'Local a)
    eval (StxRApply cs@(ExpClosure ce _) a :>>=  is) = do
      e <- makeRApply counter cs a
      (e', refMap', fuseCounter') <- if shouldOptimize
                                      then fuse refMap fuseCounter e
                                      else return (e, refMap, fuseCounter)
      build shouldOptimize refMap' (counter+1) fuseCounter' (is e')
    eval (StxRConst a :>>=  is) = do
      e <- makeRConst counter a
      build shouldOptimize refMap (counter+1) fuseCounter (is e)
    eval (StxLConst a :>>=  is) = do
      e <- makeLConst counter a
      build shouldOptimize refMap (counter+1) fuseCounter (is e)
    eval (StxCollect a :>>=  is) = do
      e <- makeCollect counter a
      build shouldOptimize refMap (counter+1) fuseCounter (is e)
    eval (StxLApply f a :>>=  is) = do
      e <- makeLApply counter f a
      build shouldOptimize refMap (counter+1) fuseCounter (is e)
    eval (Return a) = return a


data MasterSlave = M | S

data JobDesc a b = MkJobDesc {
  seed :: a
  , expGen :: forall e m. (Monad m, Builder m e) => a -> ProgramT (Syntax m) m (e 'Local (a, b))
  , reportingAction :: a -> b -> IO a
  , recPredicate :: a -> a -> b -> Bool
  }


data Config = MkConfig
  {
    slaveAvailability :: Float
  }


-- instances

instance ChunkableFreeVar a
instance ChunkableFreeVar ()


instance Chunkable [a] where
  chunk nbBuckets l =
    Vc.reverse $ Vc.fromList $ go [] nbBuckets l
    where
    go acc 1 ls = ls:acc
    go acc n ls = go (L.take nbPerBucket ls : acc) (n-1) (L.drop nbPerBucket ls)
    len = L.length l
    nbPerBucket = len `div` nbBuckets

instance UnChunkable [a] where
  unChunk l = L.concat l
