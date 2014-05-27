{-# LANGUAGE CPP, MagicHash, RankNTypes, RecordWildCards, UnboxedTuples #-}

-- |
-- Module      :  Data.Attoparsec.Text.Buffer
-- Copyright   :  Bryan O'Sullivan 2007-2014
-- License     :  BSD3
--
-- Maintainer  :  bos@serpentine.com
-- Stability   :  experimental
-- Portability :  GHC
--
-- An immutable buffer that supports cheap appends.

-- A Buffer is divided into an immutable read-only zone, followed by a
-- mutable area that we've preallocated, but not yet written to.
--
-- We overallocate at the end of a Buffer so that we can cheaply
-- append.  Since a user of an existing Buffer cannot see past the end
-- of its immutable zone into the data that will change during an
-- append, this is safe.
--
-- Once we run out of space at the end of a Buffer, we do the usual
-- doubling of the buffer size.

module Data.Attoparsec.Text.Buffer
    (
      Buffer
    , buffer
    , unbuffer
    , length
    , iter
    , iter_
    , substring
    , dropWord16
    ) where

import Control.Applicative ((<$>))
import Control.Exception (assert)
import Data.Attoparsec.Internal.Fhthagn (inlinePerformIO)
import Data.IORef (IORef, atomicModifyIORef, newIORef)
import Data.List (foldl1')
import Data.Monoid (Monoid(..))
import Data.Text ()
import Data.Text.Internal (Text(..))
import Data.Text.Internal.Encoding.Utf16 (chr2)
import Data.Text.Internal.Unsafe.Char (unsafeChr)
import Data.Text.Unsafe (Iter(..))
import GHC.Base (unsafeCoerce#)
import GHC.ST (ST(..), runST)
import Prelude hiding (length)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Text.Array as A

#if __GLASGOW_HASKELL__ >= 702
import Control.Monad.ST.Unsafe (unsafeIOToST)
#else
import Control.Monad.ST (unsafeIOToST)
#endif

data Buffer = Buf {
      _arr :: {-# UNPACK #-} !A.Array
    , _off :: {-# UNPACK #-} !Int
    , _len :: {-# UNPACK #-} !Int
    , _cap :: {-# UNPACK #-} !Int
    , _gen :: {-# UNPACK #-} !Int
    , _ref :: {-# UNPACK #-} !(IORef Int)
    }

instance Show Buffer where
    showsPrec p = showsPrec p . unbuffer

-- | The initial 'Buffer' has no mutable zone, so we can avoid all
-- copies in the (hopefully) common case of no further input being fed
-- to us.
buffer :: Text -> Buffer
buffer (Text arr off len) = inlinePerformIO $
  Buf arr off len len 0 <$> newIORef 0

unbuffer :: Buffer -> Text
unbuffer (Buf arr off len _ _ _) = Text arr off len

instance Monoid Buffer where
    mempty = unsafePerformIO $ Buf A.empty 0 0 0 0 <$> newIORef 0
    {-# NOINLINE mempty #-}

    mappend (Buf _ _ _ 0 _ _) b = b
    mappend a (Buf _ _ _ 0 _ _) = a
    mappend (Buf arr0 off0 len0 cap0 gen ref)
            (Buf arr1 off1 len1 _ _ _) = runST $ do
      gen' <- unsafeIOToST $
              atomicModifyIORef ref (\a -> let a' = a+1 in (a',a'))
      let newlen = len0 + len1
      if gen' == gen+1 && newlen <= cap0
        then do
          marr <- unsafeThaw arr0
          A.copyI marr (off0+len0) arr1 off1 (off0+newlen)
          arr2 <- A.unsafeFreeze marr
          return (Buf arr2 off0 newlen cap0 gen' ref)
        else do
          let newcap = newlen * 2
          marr <- A.new newcap
          A.copyI marr 0 arr0 off0 len0
          A.copyI marr len0 arr1 off1 newlen
          arr2 <- A.unsafeFreeze marr
          return (Buf arr2 0 newlen newcap gen' ref)

    mconcat [] = mempty
    mconcat xs = foldl1' mappend xs

length :: Buffer -> Int
length (Buf _ _ len _ _ _) = len
{-# INLINE length #-}

substring :: Int -> Int -> Buffer -> Text
substring s l (Buf arr off len _ _ _) =
  assert (s >= 0 && s <= len) .
  assert (l >= 0 && l <= len-s) $
  Text arr (off+s) l
{-# INLINE substring #-}

dropWord16 :: Int -> Buffer -> Text
dropWord16 s (Buf arr off len _ _ _) =
  assert (s >= 0 && s <= len) $
  Text arr (off+s) (len-s)
{-# INLINE dropWord16 #-}

-- | /O(1)/ Iterate (unsafely) one step forwards through a UTF-16
-- array, returning the current character and the delta to add to give
-- the next offset to iterate at.
iter :: Buffer -> Int -> Iter
iter (Buf arr off _len _ _ _) i
    | m < 0xD800 || m > 0xDBFF = Iter (unsafeChr m) 1
    | otherwise                = Iter (chr2 m n) 2
  where m = A.unsafeIndex arr j
        n = A.unsafeIndex arr k
        j = off + i
        k = j + 1
{-# INLINE iter #-}

-- | /O(1)/ Iterate one step through a UTF-16 array, returning the
-- delta to add to give the next offset to iterate at.
iter_ :: Buffer -> Int -> Int
iter_ (Buf arr off _len _ _ _) i | m < 0xD800 || m > 0xDBFF = 1
                                | otherwise                = 2
  where m = A.unsafeIndex arr (off+i)
{-# INLINE iter_ #-}

unsafeThaw :: A.Array -> ST s (A.MArray s)
unsafeThaw A.Array{..} = ST $ \s# ->
                          (# s#, A.MArray (unsafeCoerce# aBA) #)