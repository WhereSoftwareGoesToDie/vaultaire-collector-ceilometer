{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Volume where

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

processVolumeEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processVolumeEvent = processEvent getVolumePayload

-- | Constructs the compound payload for volume events
getVolumePayload :: Metric -> IO (Maybe Word64)
getVolumePayload m@Metric{..} = do
    components <- case T.splitOn "." <$> getEventType m of
        Just (_:verb:endpoint:__) -> return $ Just (verb, endpoint)
        Just x -> do
            alertM "Ceilometer.Process.getVolumePayload"
                 $ "Invalid parse of verb + endpoint for volume event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getVolumePayload"
                   "event_type field missing from volume event"
            return Nothing
    st <- case H.lookup "status" metricMetadata of
        Just (String status) -> return $ Just status
        Just x -> do
            alertM "Ceilometer.Process.getVolumePayload"
                 $ "Invalid parse of status for volume event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getVolumePayload"
                   "Status field missing from volume event"
            return Nothing
    case liftM2 (,) components st of
        Just ((verb, endpoint), status) -> do
            statusValue <- case status of
                "error"     -> return 0
                "available" -> return 1
                "creating"  -> return 2
                "extending" -> return 3
                "deleting"  -> return 4
                "attaching" -> return 5
                "detaching" -> return 6
                "in-use"    -> return 7
                "retyping"  -> return 8
                "uploading" -> return 9
                x           -> do
                    alertM "Ceilometer.Process.getVolumePayload" $
                        "Invalid status for volume event: " <> show x
                    return (-1)
            verbValue <- case verb of
                "create" -> return 1
                "resize" -> return 2
                "delete" -> return 3
                "attach" -> return 4
                "detach" -> return 5
                "update" -> return 6
                x        -> do
                    alertM "Ceilometer.Process.getVolumePayload" $
                        "Invalid verb for volume event: " <> show x
                    return (-1)
            endpointValue <- case endpoint of
                "start" -> return 1
                "end"   -> return 2
                x       -> do
                    alertM "Ceilometer.Process.getVolumePayload" $
                        "Invalid endpoint for volume event: " <> show x
                    return (-1)
            return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
                Nothing
            else case metricPayload of
                    Just p -> Just $ constructCompoundPayload statusValue verbValue endpointValue p
                    Nothing -> Nothing
        Nothing -> return Nothing
