{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Instance where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Trans
import           Data.Aeson
import qualified Data.HashMap.Strict                           as H
import           Data.List
import           Data.Maybe
import           Data.Monoid
import qualified Data.Text.Encoding                            as T
import           Data.Word
import           System.Log.Logger

import           Vaultaire.Collector.Ceilometer.Process.Common
import           Vaultaire.Collector.Ceilometer.Types


processInstanceEvent :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processInstanceEvent _ = return [] -- See https://github.com/anchor/vaultaire-collector-ceilometer/issues/4

-- | Extracts vcpu, ram, disk and flavor data from an instance pollster
--   Publishes each of these as their own metric with their own Address
processInstancePollster :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processInstancePollster m@Metric{..} = do
    let baseMap = getSourceMap m --The sourcedict for the 4 metrics is mostly shared
    let names = ["instance_vcpus", "instance_ram", "instance_disk", "instance_flavor"]
    let uoms  = ["vcpu"          , "MB"          , "GB"           , "instance"       ]
    let addrs = map (getAddress m) names
    --Modify the metric-specific sourcedict fields
    let sourceMaps = map (\(name, uom) -> H.insert "metric_unit" uom
                                        $ H.insert "metric_name" name baseMap)
                         (zip names uoms)
    --Filter out any sourcedicts which failed to process
    --Each individual failure is logged in mapToSourceDict
    sds <- liftIO $ catMaybes <$> forM sourceMaps mapToSourceDict
    --Check if all 4 metrics' sourcedicts successully parsed
    if length sds == 4 then
        case H.lookup "flavor" metricMetadata of
            Just flavor -> case fromJSON flavor of
                Error e -> do
                    liftIO . putStrLn $
                        "[Ceilometer.Process.processInstancePollster] " <>
                        "Failed to parse flavor sub-object for instance pollster" <>
                        show e
                    liftIO $ alertM "Ceilometer.Process.processInstancePollster" $
                        "Failed to parse flavor sub-object for instance pollster" <> show e
                    return []
                Success f -> do
                    payloads <- liftIO $ getInstancePayloads m f
                    case payloads of
                        Just ps -> return $ zip4 addrs sds (repeat metricTimeStamp) ps
                        Nothing -> return []
            Nothing -> do
                liftIO . putStrLn $
                    "[Ceilometer.Process.processInstancePollster]" <>
                    "Flavor sub-object missing from instance pollster"
                liftIO $ alertM "Ceilometer.Process.processInstancePollster"
                                "Flavor sub-object missing from instance pollster"
                return []
    else do
        liftIO . putStrLn $ "Ceilometer.Process.processInstance" <>
            "Failure to convert all sourceMaps to SourceDicts for instance pollster"
        liftIO $ alertM "Ceilometer.Process.processInstance"
            "Failure to convert all sourceMaps to SourceDicts for instance pollster"
        return []

-- | Constructs the compound payloads for instance pollsters
--   Returns Nothing on failure and a list of 4 Word64s, the
--   instance_vcpus, instance_ram, instance_disk and instance_flavor
--   compound payloads respectively.
getInstancePayloads :: Metric -> Flavor -> IO (Maybe [Word64])
getInstancePayloads Metric{..} Flavor{..} = do
    st <- case H.lookup "status" metricMetadata of
        Just (String status) -> return $ Just status
        Just x -> do
            putStrLn $ "[Ceilometer.Process.getInstancePayloads] " <>
                 "Invalid parse of status for instance pollster" <> show x
            alertM "Ceilometer.Process.getInstancePayloads"
                 $ "Invalid parse of status for instance pollster" <> show x
            return Nothing
        Nothing -> do
            putStrLn $ "[Ceilometer.Process.getInstancePayloads] " <>
                   "Status field missing from instance pollster"
            alertM "Ceilometer.Process.getInstancePayloads"
                   "Status field missing from instance pollster"
            return Nothing
    ty <- case H.lookup "instance_type" metricMetadata of
        Just (String instanceType) -> return $ Just instanceType
        Just x -> do
            putStrLn $ "[Ceilometer.Process.getInstancePayloads] " <>
                 "Invalid parse of instance_type for instance pollster: " <>
                 show x
            alertM "Ceilometer.Process.getInstancePayloads"
                 $ "Invalid parse of instance_type for instance pollster: " <> show x
            return Nothing
        Nothing -> do
            putStrLn $ "[Ceilometer.Process.getInstancePayloads] " <>
                   "instance_type field missing from instance pollster"
            alertM "Ceilometer.Process.getInstancePayloads"
                   "instance_type field missing from instance pollster"
            return Nothing
    case liftM2 (,) st ty of
        Just (status, instanceType) -> do
            let instanceType' = siphash32 $ T.encodeUtf8 instanceType
            let diskTotal = instanceDisk + instanceEphemeral
            let rawPayloads = [instanceVcpus, instanceRam, diskTotal, instanceType']
            -- These are taken from nova.api.openstack.common in the
            -- OpenStack Nova codebase.
            -- FIXME(fractalcat): shouldn't this be an enum?
            statusValue <- case status of
                "error"             -> return  0
                "active"            -> return  1
                "shutoff"           -> return  2
                "build"             -> return  3
                "rebuild"           -> return  4
                "deleted"           -> return  5
                "soft_deleted"      -> return  6
                "shelved"           -> return  7
                "shelved_offloaded" -> return  8
                "reboot"            -> return  9
                "hard_reboot"       -> return 10
                "password"          -> return 11
                "resize"            -> return 12
                "verify_resize"     -> return 13
                "revert_resize"     -> return 14
                "paused"            -> return 15
                "suspended"         -> return 16
                "rescue"            -> return 17
                "migrating"         -> return 18
                x                   -> do
                    putStrLn $ "[Ceilometer.Process.getInstancePayloads] " <>
                         "Invalid status for instance pollster: " <>
                         show x
                    alertM "Ceilometer.Process.getInstancePayloads"
                         $ "Invalid status for instance pollster: " <> show x
                    return (-1)
            return $ if statusValue == (-1) then
                Nothing
            else
                -- Since this is for pollsters, both verbs and endpoints are meaningless
                Just $ map (constructCompoundPayload statusValue 0 0) rawPayloads
        Nothing -> return Nothing
