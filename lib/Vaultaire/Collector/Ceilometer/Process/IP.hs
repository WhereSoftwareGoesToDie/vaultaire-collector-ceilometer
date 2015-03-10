{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.IP where

import           Control.Applicative
import           Data.Aeson
import qualified Data.HashMap.Strict                           as H
import           Data.Monoid
import qualified Data.Text                                     as T
import           Data.Word
import           System.Log.Logger

import           Vaultaire.Collector.Ceilometer.Process.Common
import           Vaultaire.Collector.Ceilometer.Types

processIpEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processIpEvent = processEvent getIpPayload

-- | An allocation has no 'value' per se, so we arbitarily use 1
ipRawPayload :: Word64
ipRawPayload = 1

-- | Constructs the compound payload for ip allocation events
getIpPayload :: Metric -> IO (Maybe Word64)
getIpPayload m@Metric{..} = do
    components <- case T.splitOn "." <$> getEventType m of
        Just (_:verb:endpoint:_) -> return $ Just (verb, endpoint)
        Just x -> do
            putStrLn $ "[Ceilometer.Process.getIpPayload] " <>
                 "Invalid parse of verb + endpoint for ip event" <> show x
            alertM "Ceilometer.Process.getIpPayload"
                 $ "Invalid parse of verb + endpoint for ip event" <> show x
            return Nothing
        Nothing -> do
            putStrLn $ "[Ceilometer.Process.getIpPayload] " <>
                   "event_type field missing from ip event"
            alertM "Ceilometer.Process.getIpPayload"
                   "event_type field missing from ip event"
            return Nothing
    let status = H.lookup "status" metricMetadata
    case components of
        Just (verb, endpoint) -> do
            statusValue <- case status of
                Nothing                -> return 0
                Just Null              -> return 0
                Just (String "ACTIVE") -> return 1
                Just (String "DOWN")   -> return 2
                Just x                 -> do
                    putStrLn $ "[Ceilometer.Process.getIpPayload] " <>
                        "Invalid status for ip event: " <> show x
                    alertM "Ceilometer.Process.getIpPayload" $
                        "Invalid status for ip event: " <> show x
                    return (-1)
            verbValue <- case verb of
                "create" -> return 1
                "update" -> return 2
                "delete" -> return 3
                x        -> do
                    putStrLn $ "[Ceilometer.Process.getIpPayload] " <>
                        "Invalid verb for ip event: " <> show x
                    alertM "Ceilometer.Process.getIpPayload" $
                        "Invalid verb for ip event: " <> show x
                    return (-1)
            endpointValue <- case endpoint of
                "start" -> return 1
                "end"   -> return 2
                x       -> do
                    putStrLn $ "[Ceilometer.Process.getIpPayload] " <>
                        "Invalid endpoint for ip event: " <> show x
                    alertM "Ceilometer.Process.getIpPayload" $
                        "Invalid endpoint for ip event: " <> show x
                    return (-1)
            return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
                Nothing
            else
                Just $ constructCompoundPayload statusValue verbValue endpointValue ipRawPayload
        Nothing -> return Nothing
