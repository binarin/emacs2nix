{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Applicative
import Control.Concurrent.Async
import Control.Exception (SomeException(..), handle)
import Data.Aeson (FromJSON(..), ToJSON(..))
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Types as JSON
import Data.ByteString.Base32 (Base32)
import qualified Data.ByteString.Base32 as Base32
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as BC
import Data.Digest.Pure.SHA (showDigest, sha256)
import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Traversable (for)
import GHC.Generics
import Network.HTTP.Client
  ( Manager, defaultManagerSettings, httpLbs, parseUrl, responseBody
  , withManager )
import System.Console.GetOpt
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>), (<.>))
import System.IO (hClose, hPutStrLn, stderr)
import System.IO.Temp (withSystemTempFile)
import System.Process (readProcess)

import Paths_elpa2nix

main :: IO ()
main = do
  opts@(Options {..}) <- getOptions
  getArchives opts >>= writePackages output

data Package =
  Package
  { ver :: [Integer]
  , deps :: Maybe (Map Text [Integer])
  , desc :: Text
  , dist :: Text -- TODO: replace with an enumeration
  , hash :: Maybe Text
  , archive :: Maybe String
  , broken :: Maybe Bool
  }
  deriving (Eq, Generic, Read, Show)

instance FromJSON Package where
  parseJSON = JSON.genericParseJSON JSON.defaultOptions

instance ToJSON Package where
  toJSON = JSON.genericToJSON JSON.defaultOptions

data Options =
  Options
  { output :: FilePath
  , uris :: [String]
  }

getOptions :: IO Options
getOptions = do
  args <- getArgs
  (opts, uris_) <-
       case getOpt Permute optdescr args of
         (opts, uris_, []) ->
           return (foldl (flip id) defaultOptions opts, uris_)
         (_, _, errs) -> do
           error (concat errs ++ usageInfo header optdescr)
  return opts { uris = uris_ }
  where
    header = "Usage: elpa2nix [OPTION...] URIs..."
    defaultOptions = Options { output = "", uris = [] }
    optdescr =
      [ Option ['o'] [] (ReqArg setOutput "FILE") "output FILE" ]
    setOutput out opts = opts { output = out }

die :: String -> IO ()
die str = hPutStrLn stderr str >> exitFailure

getArchives :: Options -> IO (Map Text Package)
getArchives Options {..} =
  withManager defaultManagerSettings $ \man -> do
    archives <- runConcurrently $ for uris $ \uri ->
      Concurrently (getPackages man uri)
    let pkgs = foldr (M.unionWith keepLatestVersion) M.empty archives
    oldPkgs <- readPackages output
    runConcurrently $ M.traverseWithKey (hashPackage oldPkgs man) pkgs
  where
    keepLatestVersion a b =
      case comparing ver a b of
        LT -> b
        GT -> a
        EQ -> b

getPackages :: Manager -> String -> IO (Map Text Package)
getPackages man uri = do
  archive <- fetchArchive man uri
  withSystemTempFile "elpa2nix-archive-contents-" $ \path h -> do
    B.hPutStr h archive
    hClose h
    M.map setArchive <$> readArchive path
  where
    setArchive pkg = pkg { archive = Just uri }

fetchArchive :: Manager -> String -> IO ByteString
fetchArchive man uri = do
  req <- parseUrl (uri </> "archive-contents")
  responseBody <$> httpLbs req man

readArchive :: FilePath -> IO (Map Text Package)
readArchive path = do
  load <- getDataFileName "elpa2json.el"
  json <- readProcess "emacs" ["--batch", "--load", load, "--eval", eval] ""
  let Just pkgs = JSON.decode $ BC.pack json
  return pkgs
  where
    eval = "(print-archive-contents-as-json " ++ show path ++ ")"

readPackages :: FilePath -> IO (Map Text Package)
readPackages path =
  handle (\(SomeException _) -> return M.empty) $ do
    json <- B.readFile path
    let Just pkgs = JSON.decode json
    return pkgs

hashPackage :: Map Text Package -> Manager -> Text -> Package -> Concurrently Package
hashPackage pkgs man name pkg =
  Concurrently $ handle brokenPkg $
  case M.lookup name pkgs of
    Just pkg' | isJust (hash pkg') -> return pkg'
    _ -> do
      let uri = fromMaybe (errorPkg "missing archive URI") (archive pkg)
          filename = T.unpack name ++ version
          version =
            case ver pkg of
              [] -> ""
              vers -> "-" ++ intercalate "." (map show vers)
          ext = case dist pkg of
                  "single" -> "el"
                  "tar" -> "tar"
                  other ->
                    errorPkg $ "unrecognized distribution type " ++ T.unpack other
          pkgurl = uri </> filename <.> ext
      req <- parseUrl pkgurl
      hash_ <- T.pack . showDigest . sha256 . responseBody <$> httpLbs req man
      return pkg { hash = Just hash_ }
  where
    errorPkg msg = error $ T.unpack name ++ ": " ++ msg
    brokenPkg (SomeException _) = return pkg { broken = Just True }

writePackages :: FilePath -> Map Text Package -> IO ()
writePackages path pkgs = BC.writeFile path (JSON.encode pkgs)