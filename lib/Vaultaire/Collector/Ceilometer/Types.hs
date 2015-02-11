{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Vaultaire.Collector.Ceilometer.Types
    ( CeilometerTime(..)
    , Metric(..)
    , Flavor(..)
    , CeilometerOptions(..)
    , CeilometerState(..)
    , Collector
    , metricParserWithName
    , module Vaultaire.Types
    ) where

import           Control.Applicative
import           Control.Monad
import           Data.Aeson
import           Data.Aeson.Types
import           Data.HashMap.Strict              (HashMap)
import           Data.Maybe
import           Data.Text                        (Text)
import qualified Data.Text                        as T
import           Data.Time.Clock
import           Data.Time.Format
import           Data.Word
import           System.Locale
import           System.ZMQ4

import qualified Vaultaire.Collector.Common.Types as V (Collector)
import           Vaultaire.Types

newtype CeilometerTime = CeilometerTime UTCTime

instance Read CeilometerTime where
    readsPrec _ s = maybeToList $ (,"") <$> CeilometerTime <$> parse' s
      where
        parse' :: String -> Maybe UTCTime
        parse' x  = parseTime defaultTimeLocale "%FT%T%QZ" x
                <|> parseTime defaultTimeLocale "%FT%T%Q" x
                <|> parseTime defaultTimeLocale "%FT%T%Q%z" x
                <|> parseTime defaultTimeLocale "%F %T%Q%z" x
                <|> parseTime defaultTimeLocale "%F %T%Q" x

instance FromJSON CeilometerTime where
    parseJSON (String t) = pure $ read $ T.unpack t
    parseJSON _ = mzero

instance FromJSON TimeStamp where
    parseJSON x = ceilometerToTimeStamp <$> parseJSON x

ceilometerToTimeStamp :: CeilometerTime -> TimeStamp
ceilometerToTimeStamp (CeilometerTime t) = convertToTimeStamp t

data Metric = Metric
    { metricName       :: Text
    , metricType       :: Text
    , metricUOM        :: Text
    , metricPayload    :: Maybe Word64
    , metricProjectId  :: Text
    , metricResourceId :: Text
    , metricTimeStamp  :: TimeStamp
    , metricMetadata   :: HashMap Text Value
    } deriving Show

data Flavor = Flavor
    { instanceVcpus     :: Word32
    , instanceRam       :: Word32
    , instanceDisk      :: Word32
    , instanceEphemeral :: Word32
    } deriving Show

data CeilometerOptions = CeilometerOptions
    { zmqHost :: String
    , zmqPort :: Int
    }

data CeilometerState = CeilometerState
    { zmqSocket  :: Socket Rep
    , zmqContext :: Context
    }

type Collector = V.Collector CeilometerOptions CeilometerState IO

instance FromJSON Metric where
    parseJSON (Object s) = Metric
        <$> s .: "name"
        <*> s .: "type"
        <*> s .: "unit"
        <*> s .: "volume"
        <*> s .: "project_id"
        <*> s .: "resource_id"
        <*> s .: "timestamp"
        <*> s .: "resource_metadata"
    parseJSON o = error $ "Cannot parse metrics from non-objects. Given: " ++ show o

instance FromJSON Flavor where
    parseJSON (Object s) = Flavor
        <$> s .: "vcpus"
        <*> s .: "ram"
        <*> s .: "disk"
        <*> s .: "ephemeral"
    parseJSON o = error $ "Cannot parse flavor from non-objects. Given: " ++ show o

metricParserWithName :: Text -> Value -> Parser Metric
metricParserWithName name o = do
    b <- parseJSON o
    if metricName b == name then
        return b
    else
        error $ concat ["Cannot decode: ", show o, " as ", show name, " metric."]
