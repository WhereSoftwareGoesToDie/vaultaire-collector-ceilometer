{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Ceilometer.Types where

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
import           Network.AMQP
import           System.Locale

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

data ErrorMessage = ErrorMessage
    { errorPublisher :: Text
    , errorTimeStamp :: TimeStamp
    } deriving Show

data Flavor = Flavor
    { instanceVcpus     :: Word64
    , instanceRam       :: Word64
    , instanceDisk      :: Word64
    , instanceEphemeral :: Word64
    } deriving Show

data CeilometerOptions = CeilometerOptions
    { rabbitLogin        :: Text
    , rabbitVHost        :: Text
    , rabbitHost         :: String
    , rabbitPort         :: Integer
    , rabbitHa           :: Bool
    , rabbitUseSSL       :: Bool
    , rabbitQueue        :: Text
    , rabbitPollPeriod   :: Int
    , rabbitPasswordFile :: FilePath
    }

data CeilometerState = CeilometerState
    { ceilometerMessageConn :: Connection
    , ceilometerMessageChan :: Channel
    }

type Collector = V.Collector CeilometerOptions CeilometerState IO

type PublicationData = Collector [(Address, SourceDict, TimeStamp, Word64)]

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

instance FromJSON ErrorMessage where
    parseJSON (Object s) = ErrorMessage
        <$> s .: "publisher_id"
        <*> s .: "timestamp"
    parseJSON o = error $ "Cannot parse error message from non-objects. Given: " ++ show o

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
