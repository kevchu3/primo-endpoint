{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Config
  ( Collection(..)
  , Collections
  , collectionId
  , Config
  , loadConfig
  , allCollections
  , lookupCollection
  , loadCollection
  ) where

import           Control.Arrow ((***))
import           Control.Monad (guard, liftM2)
import           Control.Monad.Trans.Maybe (MaybeT(..))
import qualified Data.Aeson.Types as JSON
import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HMap
import           Data.Foldable (fold)
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE (encodeUtf8)
import           Data.Time.Clock (NominalDiffTime, getCurrentTime, diffUTCTime)
import qualified Data.Vector as V
import qualified Data.Yaml as YAML
import           System.FilePath ((</>), (<.>), joinPath)
import           Text.Read (readMaybe)

import           Util
import           Document
import           Fields
import           ISO639
import           Source.FDA
import           Source.DLTS
import           Source.DLib
import           Source.SDR
import           Source.SpecialCollections

type Interval = NominalDiffTime

-- |Bootstrapping configuration values, needed to load the rest of the config file.
data PreConfig = PreConfig
  { configInterval :: Interval
  , configFDACollections :: Int
  }

instance JSON.FromJSON PreConfig where
  parseJSON = JSON.withObject "pre-config" $ \o -> PreConfig
    <$> o JSON..: "interval"
    <*> (o JSON..: "fda" >>= (JSON..: "collections"))

-- |Cached indices for converting to collection identifiers.
-- Currenly only used for FDA.
data Indices = Indices
  { fdaIndex :: HMap.HashMap Int Int -- ^map from FDA handle suffix to database id
  } deriving (Show, Read)

loadIndices :: PreConfig -> IO Indices
loadIndices conf = Indices
  <$> loadFDAIndex (configFDACollections conf)

-- |Possible metadata sources.
-- These correspond to modules in "Source" and the collection source config key.
data Source
  = SourceCollections Collections -- ^aggregate multiple collections
  | SourceFDA Int
  | SourceDLTS DLTSCore T.Text
  | SourceDLib BS.ByteString
  | SourceSDR
  | SourceSpecialCollections [(BS.ByteString, BS.ByteString)]

data Collection = Collection
  { collectionKey :: [T.Text] -- ^Unique key for this collection
  , collectionSource :: !Source
  , collectionCache :: FilePath -- ^JSON cache file for processed 'Document's
  , collectionInterval :: !Interval -- ^Max cache file age before reloading
  , collectionName :: Maybe T.Text
  , collectionFields :: Generators -- ^Metadata field mapping
  , collectionVerbose :: !Bool
  }

collectionId :: Collection -> T.Text
collectionId = T.intercalate "/" . collectionKey

-- |Map from 'collectionKey' to 'Collection'
type Collections = HMap.HashMap T.Text Collection

-- |A loaded configuration
type Config = Collection

-- |Values used during loading the config file
data Env = Env
  { envPreConfig :: !PreConfig
  , envCache :: !FilePath -- ^Cache directory
  , envISO639 :: !ISO639
  , envIndices :: !Indices
  , envGenerators :: !Generators -- ^Generator macros expanded during loading 'collectionFields'
  , envTemplates :: !(HMap.HashMap T.Text Generators) -- ^Templates that can be included in 'collectionFields'
  , envVerbose :: !Bool
  }

fixLanguage :: ISO639 -> Generators -> Generators
fixLanguage iso = HMap.adjust (languageGenerator iso) "language"

-- |@parseSource collection source_type@
parseSource :: Env -> JSON.Object -> T.Text -> JSON.Parser Source
parseSource env o "FDA" = SourceFDA
  <$> (maybe (o JSON..: "id") (\h -> maybe (fail "Unknown FDA handle") return $ HMap.lookup h (fdaIndex $ envIndices env)) =<< o JSON..:? "hdl")
parseSource _ o "DLTS" = SourceDLTS
  <$> o JSON..: "core"
  <*> o JSON..: "code"
parseSource _ o "DLib" = SourceDLib
  <$> (TE.encodeUtf8 <$> o JSON..: "path")
parseSource _ _ "SDR" = return SourceSDR
parseSource _ o "SpecialCollections" = SourceSpecialCollections
  <$> (map (TE.encodeUtf8 *** TE.encodeUtf8) . HMap.toList <$> o JSON..: "filters")
parseSource _ _ s = fail $ "Unknown collection source: " ++ show s

-- |@parseCollection generators templates key value@
parseCollection :: Env -> [T.Text] -> JSON.Value -> JSON.Parser Collection
parseCollection env key = JSON.withObject "collection" $ \o -> do
  s <- parseSource env o =<< o JSON..: "source"
  i <- o JSON..:? "interval"
  n <- o JSON..:? "name"
  f <- parseGenerators (envGenerators env) =<< o JSON..:? "fields" JSON..!= JSON.Null
  t <- withArrayOrNullOrSingleton (foldMapM getTemplate) =<< o JSON..:? "template" JSON..!= JSON.Null
  return Collection
    { collectionKey = key
    , collectionCache = envCache env </> joinPath (map T.unpack key) <.> "json"
    , collectionSource = s
    , collectionInterval = fromMaybe (configInterval $ envPreConfig env) i
    , collectionName = n
    , collectionFields =
      HMap.insert "id" (fieldGenerator "id")
      $ HMap.insert "collection" (fieldGenerator "collection")
      $ fixLanguage (envISO639 env)
      $ f <> t
    , collectionVerbose = envVerbose env
    }
  where
  getTemplate = JSON.withText "template name" $ \s ->
    maybe (fail $ "Undefined template: " ++ show s) return $ HMap.lookup s $ envTemplates env

parseConfig :: Env -> JSON.Value -> JSON.Parser Config
parseConfig env = JSON.withObject "config" $ \o -> do
  g <- o JSON..:? "generators" JSON..!= mempty
  t <- withObjectOrNull "templates" (mapM $ parseGenerators g) =<< o JSON..:? "templates" JSON..!= JSON.Null
  c <- JSON.withObject "collections" (HMap.traverseWithKey $ parseCollection env{ envGenerators = g <> envGenerators env, envTemplates = t <> envTemplates env } . return)
    =<< o JSON..: "collections"
  return Collection
    { collectionKey = []
    , collectionSource = SourceCollections c
    , collectionCache = envCache env </> "json"
    , collectionInterval = configInterval (envPreConfig env) / fromIntegral (max 1 $ HMap.size c)
    , collectionName = Just "all"
    , collectionFields = mempty
    , collectionVerbose = envVerbose env
    }

updateIndices :: Bool -> PreConfig -> FilePath -> IO Indices
updateIndices force pc f = maybe (do
    idx <- loadIndices pc
    writeFile f $ show idx
    return idx)
  return =<< runMaybeT (do
    guard $ not force
    d <- MaybeT $ Just <$> liftM2 diffUTCTime getCurrentTime (getModificationTime0 f)
    guard $ d < configInterval pc
    MaybeT $ readMaybe <$> readFile f)

-- @loadConfig force cacheDir confFile@
loadConfig :: Bool -> FilePath -> FilePath -> Bool -> IO Config
loadConfig force cache conf verb = do
  jc <- fromMaybe JSON.Null <$> YAML.decodeFile conf
  pc <- parseJSONM jc
  idx <- updateIndices force pc (cache </> "index")
  iso <- loadISO639 (cache </> "iso639")
  parseM (parseConfig Env
    { envPreConfig = pc
    , envCache = cache
    , envISO639 = iso
    , envIndices = idx
    , envGenerators = HMap.empty
    , envTemplates = HMap.empty
    , envVerbose = verb
    }) jc

allCollections :: Config -> [Collection]
allCollections c = c : ac (collectionSource c) where
  ac (SourceCollections l) = foldMap allCollections l
  ac _ = []

lookupCollection :: [T.Text] -> Config -> Maybe Collection
lookupCollection [] c = Just c
lookupCollection (k:l) Collection{ collectionSource = SourceCollections c } = lookupCollection l =<< HMap.lookup k c
lookupCollection _ _ = Nothing

loadCollection :: Collection -> Either Collections (IO Documents)
loadCollection Collection{..} =
  fmap (V.map $ generateFields collectionFields) <$> loadSource collectionSource where
  loadSource (SourceCollections l) = Left l
  loadSource (SourceFDA i) = Right $ loadFDA i
  loadSource (SourceDLTS c i) = Right $ loadDLTS (last collectionKey) collectionName c i fl
  loadSource (SourceDLib p) = Right $ loadDLib (last collectionKey) (fold collectionName) p
  loadSource SourceSDR = Right $ loadSDR
  loadSource (SourceSpecialCollections f) = Right $ loadSpecialCollections (last collectionKey) f
  fl = generatorsFields collectionFields
