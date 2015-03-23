{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Image where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.Trans
import           Data.Aeson
import qualified Data.HashMap.Strict                           as H
import           Data.Monoid
import           Data.Text                                     (Text)
import qualified Data.Text                                     as T
import           Data.Word
import           System.Log.Logger

import           Ceilometer.Types
import qualified Vaultaire.Collector.Common.Types              as V (Collector)

import           Vaultaire.Collector.Ceilometer.Process.Common
import           Vaultaire.Collector.Ceilometer.Types

processImageSizeEvent :: MonadIO m => Metric -> V.Collector o s m [(Address, SourceDict, TimeStamp, Word64)]
processImageSizeEvent = processEvent getImagePayload

parseImageStatus :: Text -> Maybe PFImageStatus
parseImageStatus "active"         = Just ImageActive
parseImageStatus "saving"         = Just ImageSaving
parseImageStatus "deleted"        = Just ImageDeleted
parseImageStatus "queued"         = Just ImageQueued
parseImageStatus "pending_delete" = Just ImagePendingDelete
parseImageStatus "killed"         = Just ImageKilled
parseImageStatus _                = Nothing

parseImageVerb :: Text -> Maybe PFImageVerb
parseImageVerb "serve"    = Just ImageServe
parseImageVerb "update"   = Just ImageUpdate
parseImageVerb "upload"   = Just ImageUpload
parseImageVerb "download" = Just ImageDownload
parseImageVerb "delete"   = Just ImageDelete
parseImageVerb _          = Nothing

-- | Constructs the compound payload for image events
getImagePayload :: Metric -> IO (Maybe Word64)
getImagePayload m@Metric{..} = do
    verb <- case T.splitOn "." <$> getEventType m of
        Just (_:verb:_) -> case parseImageVerb verb of
            Just x  -> return $ Just x
            Nothing -> do
                alertM "Ceilometer.Process.getImagePayload" $
                    "Invalid verb for image event: " <> show verb
                return Nothing
        Just x -> do
            alertM "Ceilometer.Process.getImagePayload"
                 $ "Invalid parse of verb for image event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getImagePayload"
                   "event_type field missing from image event"
            return Nothing
    status <- case H.lookup "status" metricMetadata of
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
    return $ do
        s <- status
        v <- verb
        let e = Instant
        p <- fromIntegral <$> metricPayload
        return $ review (prCompoundEvent . pdImage) $ PDImage s v e p
