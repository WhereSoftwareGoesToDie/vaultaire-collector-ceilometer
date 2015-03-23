{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Snapshot where

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

processSnapshotSizeEvent :: MonadIO m => Metric -> V.Collector o s m [(Address, SourceDict, TimeStamp, Word64)]
processSnapshotSizeEvent = processEvent getSnapshotSizePayload

parseSnapshotStatus :: Text -> Maybe PFSnapshotStatus
parseSnapshotStatus "error"     = Just SnapshotError
parseSnapshotStatus "available" = Just SnapshotAvailable
parseSnapshotStatus "creating"  = Just SnapshotCreating
parseSnapshotStatus "deleting"  = Just SnapshotDeleting
parseSnapshotStatus _           = Nothing

parseSnapshotVerb :: Text -> Maybe PFSnapshotVerb
parseSnapshotVerb "create" = Just SnapshotCreate
parseSnapshotVerb "update" = Just SnapshotUpdate
parseSnapshotVerb "delete" = Just SnapshotDelete
parseSnapshotVerb _        = Nothing

-- | Constructs the compound payload for ip allocation events
getSnapshotSizePayload :: Metric -> IO (Maybe Word64)
getSnapshotSizePayload m@Metric{..} = do
    components <- case T.splitOn "." <$> getEventType m of
        Just (_:verb:endpoint:__) -> do
            v <- case parseSnapshotVerb verb of
                Just x  -> return $ Just x
                Nothing -> do
                    alertM "Ceilometer.Process.getSnapshotSizePayload"
                         $ "Invalid verb for snapshot size event: " <> show verb
                    return Nothing
            e <- case parseEndpoint (Just endpoint) of
                Just x  -> return $ Just x
                Nothing -> do
                    alertM "Ceilometer.Process.getSnapshotSizePayload"
                         $ "Invalid endpoint for snapshot size event: " <> show endpoint
                    return Nothing
            return $ liftA2 (,) v e
        Just x -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                 $ "Invalid parse of verb + endpoint for snapshot size event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                   "event_type field missing from snapshot size event"
            return Nothing
    status <- case H.lookup "status" metricMetadata of
        Just (String status) -> case parseSnapshotStatus status of
            Just x  -> return $ Just x
            Nothing -> do
                alertM "Ceilometer.Process.getSnapshotSizePayload"
                     $ "Invalid status for snapshot size event: " <> show status
                return Nothing
        Just x -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                 $ "Invalid parse of status for snapshot size event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload"
                   "Status field missing from snapshot size event"
            return Nothing
    return $ do
        (v, e) <- components
        s      <- status
        p      <- fromIntegral <$> metricPayload
        return $ review (prCompoundEvent . pdSnapshot) $ PDSnapshot s v e p
