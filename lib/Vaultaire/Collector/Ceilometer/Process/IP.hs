{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.IP where

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

processIpEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processIpEvent = processEvent getIpPayload

parseIPStatus :: Maybe Value -> Maybe PFIPStatus
parseIPStatus Nothing                  = Just IPNone
parseIPStatus (Just Null)              = Just IPNone
parseIPStatus (Just (String "ACTIVE")) = Just IPActive
parseIPStatus (Just (String "DOWN"))   = Just IPDown
parseIPStatus _                        = Nothing

parseIPVerb :: Text -> Maybe PFIPVerb
parseIPVerb "create" = Just IPCreate
parseIPVerb "update" = Just IPUpdate
parseIPVerb "delete" = Just IPDelete
parseIPVerb _        = Nothing

-- | Constructs the compound payload for ip allocation events
getIpPayload :: Metric -> IO (Maybe Word64)
getIpPayload m@Metric{..} = do
    components <- case T.splitOn "." <$> getEventType m of
        Just (_:verb:endpoint:_) -> do
            v <- case parseIPVerb verb of
                Just x  -> return $ Just x
                Nothing -> do
                    alertM "Ceilometer.Process.getIpPayload"
                         $ "Invalid verb for ip event: " <> show verb
                    return Nothing
            e <- case parseEndpoint (Just endpoint) of
                Just x  -> return $ Just x
                Nothing -> do
                    alertM "Ceilometer.Process.getIpPayload"
                        $  "Invalid endpoint for ip event: " <> show endpoint
                    return Nothing
            return $ liftA2 (,) v e
        Just x -> do
            alertM "Ceilometer.Process.getIpPayload"
                 $ "Invalid parse of verb + endpoint for ip event" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getIpPayload"
                   "event_type field missing from ip event"
            return Nothing
    status <- case H.lookup "status" metricMetadata of
        Nothing                -> return $ Just IPNone
        Just Null              -> return $ Just IPNone
        Just (String "ACTIVE") -> return $ Just IPActive
        Just (String "DOWN")   -> return $ Just IPDown
        Just x                 -> do
            alertM "Ceilometer.Process.getIpPayload"
                $  "Invalid status for ip event: " <> show x
            return Nothing
    return $ do
        (v, e) <- components
        s      <- status
        let p = IPAlloc
        return $ review (prCompoundEvent . pdIP) $ PDIP s v e p
