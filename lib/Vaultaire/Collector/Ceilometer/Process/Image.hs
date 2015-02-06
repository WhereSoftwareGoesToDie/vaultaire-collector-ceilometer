{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Image where

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

processImageSizeEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processImageSizeEvent = processEvent getImagePayload

-- | Constructs the compound payload for image events
getImagePayload :: Metric -> IO (Maybe Word64)
getImagePayload m@Metric{..} = do
    v <- case T.splitOn "." <$> getEventType m of
        Just (_:verb:_) -> return $ Just verb
        Just x -> do
            alertM "Ceilometer.Process.getImagePayload"
                 $ "Invalid parse of verb for image event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getImagePayload"
                   "event_type field missing from image event"
            return Nothing
    st <- case H.lookup "status" metricMetadata of
        Just (String status) -> return $ Just status
        Just x -> do
            alertM "Ceilometer.Process.getImagePayload"
                 $ "Invalid parse of status for image event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getImagePayload"
                   "Status field missing from image event"
            return Nothing
    case liftM2 (,) v st of
        Just (verb, status) -> do
            statusValue <- case status of
                "active"         -> return 1
                "saving"         -> return 2
                "deleted"        -> return 3
                "queued"         -> return 4
                "pending_delete" -> return 5
                "killed"         -> return 6
                x        -> do
                    alertM "Ceilometer.Process.getImagePayload" $
                           "Invalid status for image event: " <> show x
                    return (-1)
            verbValue <- case verb of
                "serve"    -> return 1
                "update"   -> return 2
                "upload"   -> return 3
                "download" -> return 4
                "delete"   -> return 5
                x          -> do
                    alertM "Ceilometer.Process.getImagePayload" $
                        "Invalid verb for image event: " <> show x
                    return (-1)
            let endpointValue = 0
            return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
                Nothing
            else case metricPayload of
                Just p  -> Just $ constructCompoundPayload statusValue verbValue endpointValue (fromIntegral p)
                Nothing -> Nothing
        Nothing -> return Nothing
