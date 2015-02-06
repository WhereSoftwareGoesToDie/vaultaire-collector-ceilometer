{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Volume where

import           Control.Applicative
import           Control.Lens
import           Data.Aeson
import qualified Data.HashMap.Strict                           as H
import           Data.Monoid
import           Data.Text                                     (Text)
import qualified Data.Text                                     as T
import           Data.Word
import           System.Log.Logger

import           Ceilometer.Types

import           Vaultaire.Collector.Ceilometer.Process.Common
import           Vaultaire.Collector.Ceilometer.Types

processVolumeEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processVolumeEvent = processEvent getVolumePayload

parseVolumeStatus :: Text -> Maybe Word8
parseVolumeStatus x = review pfVolumeStatus <$> parseVolumeStatus' x
  where
    parseVolumeStatus' "error"     = Just VolumeError
    parseVolumeStatus' "available" = Just VolumeAvailable
    parseVolumeStatus' "creating"  = Just VolumeCreating
    parseVolumeStatus' "extending" = Just VolumeExtending
    parseVolumeStatus' "deleting"  = Just VolumeDeleting
    parseVolumeStatus' "attaching" = Just VolumeAttaching
    parseVolumeStatus' "detaching" = Just VolumeDetaching
    parseVolumeStatus' "in-use"    = Just VolumeInUse
    parseVolumeStatus' "retyping"  = Just VolumeRetyping
    parseVolumeStatus' "uploading" = Just VolumeUploading
    parseVolumeStatus' _           = Nothing

parseVolumeVerb :: Text -> Maybe Word8
parseVolumeVerb x = review pfVolumeVerb <$> parseVolumeVerb' x
  where
    parseVolumeVerb' "create" = Just VolumeCreate
    parseVolumeVerb' "resize" = Just VolumeResize
    parseVolumeVerb' "delete" = Just VolumeDelete
    parseVolumeVerb' "attach" = Just VolumeAttach
    parseVolumeVerb' "detach" = Just VolumeDetach
    parseVolumeVerb' "update" = Just VolumeUpdate
    parseVolumeVerb' _        = Nothing

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
    statusValue <- case H.lookup "status" metricMetadata of
        Just (String status) -> case parseVolumeStatus status of
            Just x  -> return $ Just x
            Nothing -> do
                alertM "Ceilometer.Process.getVolumePayload" $
                    "Invalid status for volume event: " <> show status
                return Nothing
        Just x -> do
            alertM "Ceilometer.Process.getVolumePayload" $
                   "Invalid parse of status for volume event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getVolumePayload"
                   "Status field missing from volume event"
            return Nothing
    case components of
        Just (verb, endpoint) -> do
            verbValue <- case parseVolumeVerb verb of
                Just x  -> return $ Just x
                Nothing -> do
                    alertM "Ceilometer.Process.getVolumePayload" $
                           "Invalid verb for volume event: " <> show verb
                    return Nothing
            endpointValue <- case parseEndpoint (Just endpoint) of
                Just x -> return $ Just x
                Nothing -> do
                    alertM "Ceilometer.Process.getVolumePayload" $
                           "Invalid endpoint for volume event: " <> show endpoint
                    return Nothing
            let payload = case metricPayload of
                    Just p -> do
                        sv <- statusValue
                        vv <- verbValue
                        ev <- endpointValue
                        return $ constructCompoundPayload sv vv ev (fromIntegral p)
                    Nothing -> Nothing
            return payload
        Nothing -> return Nothing
