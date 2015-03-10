{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Common where

import           Control.Monad
import           Control.Monad.Trans
import           Crypto.MAC.SipHash                   (SipHash (..),
                                                       SipKey (..), hash)
import           Data.Aeson
import           Data.Bits
import qualified Data.ByteString                      as S
import           Data.HashMap.Strict                  (HashMap)
import qualified Data.HashMap.Strict                  as H
import           Data.Monoid
import           Data.Text                            (Text)
import qualified Data.Text.Encoding                   as T
import           Data.Word
import           System.Log.Logger

import           Marquise.Client

import           Vaultaire.Collector.Ceilometer.Types

-- Utility

isEvent :: Metric -> Bool
isEvent m = H.member "event_type" $ metricMetadata m

getEventType :: Metric -> Maybe Text
getEventType m = case H.lookup "event_type" $ metricMetadata m of
    Just (String x) -> Just x
    Just _          -> Nothing
    Nothing         -> Nothing

isCompound :: Metric -> Bool
isCompound m
    | isEvent m && metricName m == "ip.floating"   = True
    | isEvent m && metricName m == "volume.size"   = True
    | isEvent m && metricName m == "image.size"    = True
    | isEvent m && metricName m == "snapshot.size" = True
    |              metricName m == "instance"      = True
    | otherwise                                    = False

-- | Constructs the internal HashMap of a SourceDict for the given Metric
--   Appropriately excludes optional fields when not present
getSourceMap :: Metric -> HashMap Text Text
getSourceMap m@Metric{..} =
    let base = [ ("_event", if isEvent m then "1" else "0")
               , ("_compound", if isCompound m then "1" else "0")
               , ("project_id",   metricProjectId)
               , ("resource_id",  metricResourceId)
               , ("metric_name",  metricName)
               , ("metric_unit",  metricUOM)
               , ("metric_type",  metricType)
               ]
        displayName = case H.lookup "display_name" metricMetadata of
            Just (String x) -> [("display_name", x)]
            Just _          -> []
            Nothing         -> []
        volumeType = case H.lookup "volume_type" metricMetadata of
            Just (String x) -> [("volume_type", x)]
            Just _          -> []
            Nothing         -> []
        counter = [("_counter", "1") | metricType == "cumulative"]
    in H.fromList $ counter <> base <> displayName <> volumeType

-- | Wrapped construction of a SourceDict with logging
mapToSourceDict :: HashMap Text Text -> IO (Maybe SourceDict)
mapToSourceDict sourceMap = case makeSourceDict sourceMap of
    Left err -> do
        putStrLn $ "[Ceilometer.Process.getSourceDict] " <>
            "Failed to create sourcedict from " <> show sourceMap <>
            " error: " <> err
        alertM "Ceilometer.Process.getSourceDict" $
            "Failed to create sourcedict from " <> show sourceMap <> " error: " <> err
        return Nothing
    Right sd -> return $ Just sd

-- | Extracts the core identifying strings from the passed Metric
getIdElements :: Metric -> Text -> [Text]
getIdElements m@Metric{..} name =
    let base     = [metricProjectId, metricResourceId, metricUOM, metricType, name]
        event    = case getEventType m of
            Just eventType -> ["_event", eventType]
            Nothing        -> []
        compound = ["_compound" | isCompound m]
    in concat [base,event,compound]

-- | Constructs a unique Address for a Metric from its identifying data
getAddress :: Metric -> Text -> Address
getAddress m name = hashIdentifier $ T.encodeUtf8 $ mconcat $ getIdElements m name

-- | Canonical siphash with key = 0
siphash :: S.ByteString -> Word64
siphash x = let (SipHash h) = hash (SipKey 0 0) x in h

-- | Canonical siphash with key = 0, truncated to 32 bits
siphash32 :: S.ByteString -> Word64
siphash32 = (`shift` (-32)) . siphash

-- | Constructs a compound payload from components
constructCompoundPayload :: Word64 -> Word64 -> Word64 -> Word64 -> Word64
constructCompoundPayload statusValue verbValue endpointValue rawPayload =
    let s = statusValue
        v = verbValue `shift` 8
        e = endpointValue `shift` 16
        r = 0 `shift` 24
        p = rawPayload `shift` 32
    in
        s + v + e + r + p

-- | Processes a pollster with no special requirements
processBasePollster :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processBasePollster m@Metric{..} = do
    sd <- liftIO $ mapToSourceDict $ getSourceMap m
    case sd of
        Just sd' -> do
            let addr = getAddress m metricName
            return $ case metricPayload of
                Just p  -> [(addr, sd', metricTimeStamp, p)]
                Nothing -> []
        Nothing -> return []

-- | Constructs the appropriate compound payload and vault data for an event
processEvent :: (Metric -> IO (Maybe Word64)) -> Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processEvent f m@Metric{..} = do
    p  <- liftIO $ f m
    sd <- liftIO $ mapToSourceDict $ getSourceMap m
    let addr = getAddress m metricName
    case liftM2 (,) p sd of
        Just (compoundPayload, sd') ->
            return [(addr, sd', metricTimeStamp, compoundPayload)]
        -- Sub functions will alert, alerts cause termination by default
        -- so this case should not be reached
        Nothing -> do
            liftIO . putStrLn $ "[Ceilometer.Process.processEvent] " <>
                "Impossible control flow reached in processEvent. Given: " <>
                show m
            liftIO $ errorM "Ceilometer.Process.processEvent" $
                "Impossible control flow reached in processEvent. Given: " <>
                show m
            return []
