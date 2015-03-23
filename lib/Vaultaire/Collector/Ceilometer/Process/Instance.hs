{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process.Instance where

import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Control.Monad.Trans
import           Data.Aeson
import qualified Data.Bimap                                    as B
import qualified Data.HashMap.Strict                           as H
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Text                                     (Text)
import           Data.Word
import           System.Log.Logger

import           Ceilometer.Types                              hiding (Flavor)
import qualified Vaultaire.Collector.Common.Types              as V (Collector)

import           Vaultaire.Collector.Ceilometer.Process.Common
import           Vaultaire.Collector.Ceilometer.Types


processInstanceEvent :: MonadIO m =>  Metric -> V.Collector o s m [(Address, SourceDict, TimeStamp, Word64)]
processInstanceEvent _ = return [] -- See https://github.com/anchor/vaultaire-collector-ceilometer/issues/4

-- | Extracts vcpu, ram, disk and flavor data from an instance pollster
--   Publishes each of these as their own metric with their own Address
processInstancePollster :: MonadIO m => Metric -> V.Collector o s m [(Address, SourceDict, TimeStamp, Word64)]
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
                    liftIO $ alertM "Ceilometer.Process.processInstancePollster" $
                        "Failed to parse flavor sub-object for instance pollster" <> show e
                    return []
                Success f -> do
                    payloads <- liftIO $ getInstancePayloads m f
                    case payloads of
                        Just ps -> return $ zip4 addrs sds (repeat metricTimeStamp) ps
                        Nothing -> return []
            Nothing -> do
                liftIO $ alertM "Ceilometer.Process.processInstancePollster"
                                "Flavor sub-object missing from instance pollster"
                return []
    else do
        liftIO $ alertM "Ceilometer.Process.processInstance"
            "Failure to convert all sourceMaps to SourceDicts for instance pollster"
        return []


-- These are taken from nova.api.openstack.common in the
-- OpenStack Nova codebase.
parseInstanceStatus :: Text -> Maybe PFInstanceStatus
parseInstanceStatus "error"             = Just InstanceError
parseInstanceStatus "active"            = Just InstanceActive
parseInstanceStatus "shutoff"           = Just InstanceShutoff
parseInstanceStatus "build"             = Just InstanceBuild
parseInstanceStatus "rebuild"           = Just InstanceRebuild
parseInstanceStatus "deleted"           = Just InstanceDeleted
parseInstanceStatus "soft_deleted"      = Just InstanceSoftDeleted
parseInstanceStatus "shelved"           = Just InstanceShelved
parseInstanceStatus "shelved_offloaded" = Just InstanceShelvedOffloaded
parseInstanceStatus "reboot"            = Just InstanceReboot
parseInstanceStatus "hard_reboot"       = Just InstanceHardReboot
parseInstanceStatus "password"          = Just InstancePassword
parseInstanceStatus "resize"            = Just InstanceResize
parseInstanceStatus "verify_resize"     = Just InstanceVerifyResize
parseInstanceStatus "revert_resize"     = Just InstanceRevertResize
parseInstanceStatus "paused"            = Just InstancePaused
parseInstanceStatus "suspended"         = Just InstanceSuspended
parseInstanceStatus "rescue"            = Just InstanceRescue
parseInstanceStatus "migrating"         = Just InstanceMigrating
parseInstanceStatus _                   = Nothing

-- | Constructs the compound payloads for instance pollsters
--   Returns Nothing on failure and a list of 4 Word64s, the
--   instance_vcpus, instance_ram, instance_disk and instance_flavor
--   compound payloads respectively.
getInstancePayloads :: Metric -> Flavor -> IO (Maybe [Word64])
getInstancePayloads Metric{..} Flavor{..} = do
    status <- case H.lookup "status" metricMetadata of
        Just (String status) -> case parseInstanceStatus status of
            Just x  -> return $ Just x
            Nothing -> do
                alertM "Ceilometer.Process.getInstancePayloads"
                     $ "Invalid status for instance pollster: " <> show status
                return Nothing
        Just x -> do
            alertM "Ceilometer.Process.getInstancePayloads"
                 $ "Invalid parse of status for instance pollster" <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getInstancePayloads"
                   "Status field missing from instance pollster"
            return Nothing
    instanceFlavor <- case H.lookup "instance_type" metricMetadata of
        Just (String instanceType) -> return $ Just instanceType
        Just x -> do
            alertM "Ceilometer.Process.getInstancePayloads"
                 $ "Invalid parse of instance_type for instance pollster: " <> show x
            return Nothing
        Nothing -> do
            alertM "Ceilometer.Process.getInstancePayloads"
                   "instance_type field missing from instance pollster"
            return Nothing
    let diskTotal = instanceDisk + instanceEphemeral
    return $ do
        s <- status
        f <- instanceFlavor
        let fm = B.empty --FlavorMap is unused for pretty printing/encoding
        return
            [ review (prCompoundPollster . pdInstanceVCPU     ) (PDInstanceVCPU   s instanceVcpus)
            , review (prCompoundPollster . pdInstanceRAM      ) (PDInstanceRAM    s instanceRam  )
            , review (prCompoundPollster . pdInstanceDisk     ) (PDInstanceDisk   s diskTotal    )
            , review (prCompoundPollster . pdInstanceFlavor fm) (PDInstanceFlavor s f            )
            ]
