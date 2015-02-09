{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Image where

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

processImageSizeEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processImageSizeEvent = processEvent getImagePayload

parseImageStatus :: Text -> Maybe Word8
parseImageStatus x = review pfImageStatus <$> parseImageStatus' x
  where
    parseImageStatus' "active"         = Just ImageActive
    parseImageStatus' "saving"         = Just ImageSaving
    parseImageStatus' "deleted"        = Just ImageDeleted
    parseImageStatus' "queued"         = Just ImageQueued
    parseImageStatus' "pending_delete" = Just ImagePendingDelete
    parseImageStatus' "killed"         = Just ImageKilled
    parseImageStatus' _                = Nothing

parseImageVerb :: Text -> Maybe Word8
parseImageVerb x = review pfImageVerb <$> parseImageVerb' x
  where
    parseImageVerb' "serve"    = Just ImageServe
    parseImageVerb' "update"   = Just ImageUpdate
    parseImageVerb' "upload"   = Just ImageUpload
    parseImageVerb' "download" = Just ImageDownload
    parseImageVerb' "delete"   = Just ImageDelete
    parseImageVerb' _          = Nothing

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
    statusValue <- case H.lookup "status" metricMetadata of
        Just (String status) -> case parseImageStatus status of
            Just x  -> return $ Just x
            Nothing -> do
                alertM "Ceilometer.Process.getImagePayload" $
                       "Invalid status for image event: " <> show status
                return Nothing
        Just x -> do
            alertM "Ceilometer.Process.getImagePayload"
                 $ "Invalid parse of status for image event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getImagePayload"
                   "Status field missing from image event"
            return Nothing
    case v of
        Just verb -> do
            verbValue <- case parseImageVerb verb of
                Just x  -> return $ Just x
                Nothing -> do
                    alertM "Ceilometer.Process.getImagePayload" $
                        "Invalid verb for image event: " <> show verb
                    return Nothing
            let endpointValue = parseEndpoint Nothing
            let payload = case metricPayload of
                    Just p -> do
                        sv <- statusValue
                        vv <- verbValue
                        ev <- endpointValue
                        return $ constructCompoundPayload sv vv ev (fromIntegral p)
                    Nothing -> Nothing
            return payload
        Nothing -> return Nothing
