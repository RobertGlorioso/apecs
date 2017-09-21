{-# LANGUAGE Strict, ScopedTypeVariables, TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Apecs.Util (
  -- * Utility
  initStore, runGC, unEntity,

  -- * EntityCounter
  EntityCounter, initCounter, nextEntity, newEntity,

  -- * Spatial hashing
  -- $hash
  quantize, flatten, region, inbounds,

  -- * Timing
  timeSystem, timeSystem_,

  -- * indexTable

  ) where

import System.Mem (performMajorGC)
import Control.Monad.Reader (liftIO)
import Control.Applicative (liftA2)
import System.CPUTime
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import qualified Data.IntSet as S

import Apecs.Types
import Apecs.Stores
import Apecs.System

-- | Initializes a store with (), useful since most stores have () as their initialization argument
initStore :: (Initializable s, InitArgs s ~ ()) => IO s
initStore = initStoreWith ()

unEntity :: Entity a -> Int
unEntity (Entity e) = e

-- | Secretly just an int in a newtype
newtype EntityCounter = EntityCounter Int deriving (Num, Eq, Show)
instance Component EntityCounter where
  type Storage EntityCounter = Global EntityCounter

-- | Initialize an EntityCounter
initCounter :: IO (Storage EntityCounter)
initCounter = initStoreWith (EntityCounter 0)

-- | Bumps the EntityCounter and yields its value
{-# INLINE nextEntity #-}
nextEntity :: Has w EntityCounter => System w (Entity ())
nextEntity = do EntityCounter n <- readGlobal
                writeGlobal (EntityCounter (n+1))
                return (Entity n)

-- | Writes the given components to a new entity, and yields that entity
{-# INLINE newEntity #-}
newEntity :: (IsRuntime c, Has w c, Has w EntityCounter)
          => c -> System w (Entity c)
newEntity c = do ety <- nextEntity
                 set ety c
                 return (cast ety)

-- | Explicitly invoke the garbage collector
runGC :: System w ()
runGC = liftIO performMajorGC

-- $hash
-- The following functions are for spatial hashing.
-- The idea is that your spatial hash is defined by two vectors;
--   - The cell size vector contains real components and dictates
--     how large each cell in your table is spatially.
--     It is used to translate from world-space to table space
--   - The field size vector contains integral components and dictates how
--     many cells your field consists of in each direction.
--     It is used to translate from table-space to a flat integer

-- | Quantize turns a world-space coordinate into a table-space coordinate by dividing
--   by the given cell size and round components towards negative infinity
{-# INLINE quantize #-}
quantize :: (Fractional (v a), Integral b, RealFrac a, Functor v)
         => v a -- ^ Quantization cell size
         -> v a -- ^ Vector to be quantized
         -> v b
quantize cell vec = floor <$> vec/cell

-- | For two table-space vectors indicating a region's bounds, gives a list of the vectors contained between them.
--   This is useful for querying a spatial hash.
{-# INLINE region #-}
region :: (Enum a, Applicative v, Traversable v)
       => v a -- ^ Lower bound for the region
       -> v a -- ^ Higher bound for the region
       -> [v a]
region a b = sequence $ liftA2 enumFromTo a b

-- | Turns a table-space vector into a linear index, given some table size vector.
{-# INLINE flatten #-}
flatten :: (Applicative v, Integral a, Foldable v)
        => v a -- Field size vector
        -> v a -> a
flatten size vec = foldr (\(n,x) acc -> n*acc + x) 0 (liftA2 (,) size vec)

-- | Tests whether a vector is in the region given by 0 and the size vector
{-# INLINE inbounds #-}
inbounds :: (Num (v a), Ord a, Applicative v, Foldable v)
         => v a -> v a -> Bool
inbounds size vec = and (liftA2 (>=) vec 0) && and (liftA2 (<=) vec size)


-- | Runs a system and gives its execution time in seconds
{-# INLINE timeSystem #-}
timeSystem :: System w a -> System w (Double, a)
timeSystem sys = do
  s <- liftIO getCPUTime
  a <- sys
  t <- liftIO getCPUTime
  return (fromIntegral (t-s)/1e12, a)

{-# INLINE timeSystem_ #-}
-- | Runs a system, discards its output, and gives its execution time in seconds
timeSystem_ :: System w a -> System w Double
timeSystem_ = fmap fst . timeSystem

-- | Class of values that can be hashed for a HashTable
--   Indexing is equivalent to hashing
--   hash must not produce values below zero or above (hash maxHash)
class Hashable c where
  -- | The value for which hash yields the highest value; its upper bound
  maxHash :: c
  -- | Hashes a component to an index in the IndexTable
  hash  :: c -> Int
