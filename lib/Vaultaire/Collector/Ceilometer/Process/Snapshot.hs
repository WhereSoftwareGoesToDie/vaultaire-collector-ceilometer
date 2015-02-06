{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Snapshot where

import           Control.Applicative
import           Control.Monad
import           Data.Aeson
import qualified Data.HashMap.Strict                           as H
import           Data.Monoid
import qualified Data.Text                                     as T
import           Data.Word
import           System.Log.Logger

import           Vaultaire.Collector.Ceilometer.Process.Common
import           Vaultaire.Collector.Ceilometer.Types

processSnapshotSizeEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processSnapshotSizeEvent = processEvent getSnapshotSizePayload

-- | Constructs the compound payload for ip allocation events
getSnapshotSizePayload :: Metric -> IO (Maybe Word64)
getSnapshotSizePayload m@Metric{..} = do
    components <- case T.splitOn "." <$> getEventType m of
        Just (_:verb:endpoint:__) -> return $ Just (verb, endpoint)
        Just x -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                 $ "Invalid parse of verb + endpoint for snapshot size event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                   "event_type field missing from snapshot size event"
            return Nothing
    st <- case H.lookup "status" metricMetadata of
        Just (String status) -> return $ Just status
        Just x -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                 $ "Invalid parse of status for snapshot size event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                   "Status field missing from snapshot size event"
            return Nothing
    case liftM2 (,) components st of
        Just ((verb, endpoint), status) -> do
            statusValue <- case status of
                "error"     -> return 0
                "available" -> return 1
                "creating"  -> return 2
                "deleting"  -> return 3
                x           -> do
                    alertM "Ceilometer.Process.getSnapshotSizePayload" $
                        "Invalid status for snapshot size event: " <> show x
                    return (-1)
            verbValue <- case verb of
                "create" -> return 1
                "update" -> return 2
                "delete" -> return 3
                x        -> do
                    alertM "Ceilometer.Process.getSnapshotSizePayload" $
                        "Invalid verb for snapshot size event: " <> show x
                    return (-1)
            endpointValue <- case endpoint of
                "start" -> return 1
                "end"   -> return 2
                x       -> do
                    alertM "Ceilometer.Process.getSnapshotSizePayload" $
                        "Invalid endpoint for snapshot size event: " <> show x
                    return (-1)
            return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
                Nothing
            else case metricPayload of
                Just p -> Just $ constructCompoundPayload statusValue verbValue endpointValue (fromIntegral p)
                Nothing -> Nothing
        Nothing -> return Nothing
