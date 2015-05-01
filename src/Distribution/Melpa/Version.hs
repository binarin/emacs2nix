{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}

module Distribution.Melpa.Version where

import Data.Aeson
import Data.Aeson.Types (defaultOptions)
#if __GLASGOW_HASKELL__ < 710
import Data.Monoid
#endif
import GHC.Generics

newtype Version = Version [Integer]
  deriving (Eq, Generic, Read, Show)

instance Ord Version where
  compare (Version as) (Version bs) = foldr mappend EQ (zipWith compare as bs)

instance FromJSON Version where
  parseJSON = genericParseJSON defaultOptions

instance ToJSON Version where
  toJSON = genericToJSON defaultOptions
