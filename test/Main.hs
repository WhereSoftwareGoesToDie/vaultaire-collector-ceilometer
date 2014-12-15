{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Applicative
import           Control.Monad.Trans
import           Data.Aeson
import           Data.Bits
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString.Lazy.Char8         as BSL
import           Data.HashMap.Strict                (HashMap)
import qualified Data.HashMap.Strict                as H
import           Data.Maybe
import           Data.Monoid
import           Data.Text                          (Text)
import           Data.Word
import           Test.Hspec
import           Test.HUnit.Base

import           Vaultaire.Collector.Common.Process
import           Vaultaire.Types

import           Ceilometer.Process
import           Ceilometer.Types

-- Convenience run function
runTestPublisher :: Publisher a -> IO a
runTestPublisher = runNullCollector (pure $ CeilometerOptions "" "" "" True True "" 0 "") (\_ -> return $ CeilometerState undefined undefined) (return ())

-- Volume Events

expectedVolumePayload :: Word64
expectedVolumePayload = 2 + (1 `shift` 8) + (1 `shift` 16) + (10 `shift` 32)

expectedVolumeTimestamp :: TimeStamp
expectedVolumeTimestamp = TimeStamp 1411371101378773000

expectedVolumeHashmap :: HashMap Text Text
expectedVolumeHashmap = H.fromList
  [ ("_event", "1"),
    ("_compound", "1"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("metric_name", "volume.size"),
    ("metric_unit", "GB"),
    ("metric_type", "gauge"),
    ("display_name", "cathartic"),
    ("volume_type", "lethargic")
  ]

expectedVolumeSd :: SourceDict
expectedVolumeSd = either error id (makeSourceDict expectedVolumeHashmap)

-- IP Floating Events

expectedIPFloatingPayload :: Word64
expectedIPFloatingPayload = 2 + (1 `shift` 8) + (2 `shift` 16) + (1 `shift` 32)

expectedIPFloatingTimestamp :: TimeStamp
expectedIPFloatingTimestamp = TimeStamp 1411371303030569000

expectedIPFloatingHashmap :: HashMap Text Text
expectedIPFloatingHashmap = H.fromList
  [ ("_event", "1"),
    ("_compound", "1"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("metric_name", "ip.floating"),
    ("metric_unit", "ip"),
    ("metric_type", "gauge")
  ]

expectedIPFloatingSd :: SourceDict
expectedIPFloatingSd = either error id (makeSourceDict expectedIPFloatingHashmap)

-- Instance Pollsters

expectedInstancePollsterTimestamp :: TimeStamp
expectedInstancePollsterTimestamp = TimeStamp 1412235708000000000

expectedInstanceFlavorPayload :: Word64
expectedInstanceFlavorPayload = siphash "2"

expectedInstanceFlavorHashmap :: HashMap Text Text
expectedInstanceFlavorHashmap = H.fromList
  [ ("metric_name", "instance_flavor"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("display_name", "cathartic"),
    ("metric_type", "gauge"),
    ("metric_unit", "instance"),
    ("_compound", "0"),
    ("_event", "0")
  ]

expectedInstanceFlavorSd :: SourceDict
expectedInstanceFlavorSd = either error id (makeSourceDict expectedInstanceFlavorHashmap)

expectedInstanceRamPayload :: Word64
expectedInstanceRamPayload = 2048

expectedInstanceRamHashmap :: HashMap Text Text
expectedInstanceRamHashmap = H.fromList
  [ ("metric_name", "instance_ram"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("display_name", "cathartic"),
    ("metric_type", "gauge"),
    ("metric_unit", "MB"),
    ("_compound", "0"),
    ("_event", "0")
  ]

expectedInstanceRamSd :: SourceDict
expectedInstanceRamSd = either error id (makeSourceDict expectedInstanceRamHashmap)

expectedInstanceVCpuPayload :: Word64
expectedInstanceVCpuPayload = 1

expectedInstanceVCpuHashmap :: HashMap Text Text
expectedInstanceVCpuHashmap = H.fromList
  [ ("metric_name", "instance_vcpus"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("display_name", "cathartic"),
    ("metric_type", "gauge"),
    ("metric_unit", "vcpu"),
    ("_compound", "0"),
    ("_event", "0")
  ]

expectedInstanceVCpuSd :: SourceDict
expectedInstanceVCpuSd = either error id (makeSourceDict expectedInstanceVCpuHashmap)

expectedInstanceDiskPayload :: Word64
expectedInstanceDiskPayload = 20

expectedInstanceDiskHashmap :: HashMap Text Text
expectedInstanceDiskHashmap = H.fromList
  [ ("metric_name", "instance_disk"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("display_name", "cathartic"),
    ("metric_type", "gauge"),
    ("metric_unit", "GB"),
    ("_compound", "0"),
    ("_event", "0")
  ]

expectedInstanceDiskSd :: SourceDict
expectedInstanceDiskSd = either error id (makeSourceDict expectedInstanceDiskHashmap)

-- Network Rx/Tx

expectedNetworkRxPayload :: Word64
expectedNetworkRxPayload = 58832

expectedNetworkRxTimestamp :: TimeStamp
expectedNetworkRxTimestamp = TimeStamp 1412295907000000000

expectedNetworkRxHashmap :: HashMap Text Text
expectedNetworkRxHashmap = H.fromList
  [ ("metric_name", "network.incoming.bytes"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("metric_type", "cumulative"),
    ("metric_unit", "B"),
    ("_compound", "0"),
    ("_event", "0"),
    ("_counter", "1")
  ]

expectedNetworkRxSd :: SourceDict
expectedNetworkRxSd = either error id (makeSourceDict expectedNetworkRxHashmap)

expectedNetworkTxPayload :: Word64
expectedNetworkTxPayload = 21816

expectedNetworkTxTimestamp :: TimeStamp
expectedNetworkTxTimestamp = TimeStamp 1412295932000000000

expectedNetworkTxHashmap :: HashMap Text Text
expectedNetworkTxHashmap = H.fromList
  [ ("metric_name", "network.outgoing.bytes"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("metric_type", "cumulative"),
    ("metric_unit", "B"),
    ("_compound", "0"),
    ("_event", "0"),
    ("_counter", "1")
  ]

expectedNetworkTxSd :: SourceDict
expectedNetworkTxSd = either error id (makeSourceDict expectedNetworkTxHashmap)

-- Disk Read/Write

expectedDiskReadPayload :: Word64
expectedDiskReadPayload =  117644800

expectedDiskReadTimestamp :: TimeStamp
expectedDiskReadTimestamp = TimeStamp 1412295960000000000

expectedDiskReadHashmap :: HashMap Text Text
expectedDiskReadHashmap = H.fromList
  [ ("metric_name", "disk.read.bytes"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("display_name", "cathartic"),
    ("metric_type", "cumulative"),
    ("metric_unit", "B"),
    ("_compound", "0"),
    ("_event", "0"),
    ("_counter", "1")
  ]

expectedDiskReadSd :: SourceDict
expectedDiskReadSd = either error id (makeSourceDict expectedDiskReadHashmap)

expectedDiskWritePayload :: Word64
expectedDiskWritePayload = 12387328

expectedDiskWriteTimestamp :: TimeStamp
expectedDiskWriteTimestamp = TimeStamp 1412295959000000000

expectedDiskWriteHashmap :: HashMap Text Text
expectedDiskWriteHashmap = H.fromList
  [ ("metric_name", "disk.write.bytes"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("display_name", "cathartic"),
    ("metric_type", "cumulative"),
    ("metric_unit", "B"),
    ("_compound", "0"),
    ("_event", "0"),
    ("_counter", "1")
  ]

expectedDiskWriteSd :: SourceDict
expectedDiskWriteSd = either error id (makeSourceDict expectedDiskWriteHashmap)

-- Cpu Usage

expectedCpuPayload :: Word64
expectedCpuPayload = 49320000000

expectedCpuTimestamp :: TimeStamp
expectedCpuTimestamp = TimeStamp 1412295961000000000

expectedCpuHashmap :: HashMap Text Text
expectedCpuHashmap = H.fromList
  [ ("metric_name", "cpu"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("display_name", "cathartic"),
    ("metric_type", "cumulative"),
    ("metric_unit", "ns"),
    ("_compound", "0"),
    ("_event", "0"),
    ("_counter", "1")
  ]

expectedCpuSd :: SourceDict
expectedCpuSd = either error id (makeSourceDict expectedCpuHashmap)

-- Images

expectedImagePollsterPayload :: Word64
expectedImagePollsterPayload = 1120272384

expectedImagePollsterTimestamp :: TimeStamp
expectedImagePollsterTimestamp = TimeStamp 200000000000

expectedImagePollsterHashmap :: HashMap Text Text
expectedImagePollsterHashmap = H.fromList
  [ ("metric_name", "image.size"),
    ("project_id", "magic"),
    ("resource_id", "magic"),
    ("metric_type", "gauge"),
    ("metric_unit", "B"),
    ("_compound", "0"),
    ("_event", "0")
  ]

expectedImagePollsterSd :: SourceDict
expectedImagePollsterSd = either error id (makeSourceDict expectedImagePollsterHashmap)

-- Snapshots

expectedSnapshotPayload :: Word64
expectedSnapshotPayload = 1 + (1 `shift` 8) + (2 `shift` 16) + (40 `shift` 32)

expectedSnapshotTimestamp :: TimeStamp
expectedSnapshotTimestamp = TimeStamp 0

expectedSnapshotHashmap :: HashMap Text Text
expectedSnapshotHashmap = H.fromList
  [ ("metric_name", "snapshot.size"),
    ("project_id", "lethargic"),
    ("resource_id", "harpic"),
    ("display_name", "alice-in-wonderland"),
    ("metric_type", "gauge"),
    ("metric_unit", "GB"),
    ("_compound", "1"),
    ("_event", "1")
  ]

expectedSnapshotSd :: SourceDict
expectedSnapshotSd = either error id (makeSourceDict expectedSnapshotHashmap)

suite :: Spec
suite = do
    describe "Processing Supported Metrics" $ do
        it "Processes volume.size events" testVolume
        it "Processes ip.floating events" testIPFloating
        it "Processes instance pollsters" testInstancePollster
        it "Processes network rx/tx pollsters" testNetworkRxTx
        it "Processes disk read/write pollsters" testDiskReadWrite
        it "Processes cpu usage pollsters" testCpu
        it "Processes image size pollsters" testImagePollster
        it "Processes snapshot size events" testSnapshot
    describe "Ignoring Unsupported Metrics" $ do
        it "Ignores disk read/write requests pollsters" testIgnoreDiskRequests
        it "Ignores specifically sized instance pollsters" testIgnoreSizedInstances
    describe "Utility" $
        it "Processes timestamps correctly" testTimeStamp

main :: IO ()
main = hspec suite

testVolume :: IO ()
testVolume = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/volume.json"
    processedVolume <- processSample rawJSON
    liftIO $ case processedVolume of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedVolumeSd
            ts @?= expectedVolumeTimestamp
            p  @?= expectedVolumePayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedVolume has ", show n, " elements:, ", show xs, ". Expected 1"]

testIPFloating :: IO ()
testIPFloating = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/ip_floating.json"
    processedIPFloating <- processSample rawJSON
    liftIO $ case processedIPFloating of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedIPFloatingSd
            ts @?= expectedIPFloatingTimestamp
            p  @?= expectedIPFloatingPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedIPFloating has ", show n, " elements:, ", show xs, ". Expected 1"]

testInstancePollster :: IO ()
testInstancePollster = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/instance_pollster.json"
    processedInstance <- processSample rawJSON
    liftIO $ case processedInstance of
        [(_, vSd, vTs, vP), (_, rSd, rTs, rP), (_, dSd, dTs, dP), (_, fSd, fTs, fP)] -> do
            vTs @?= expectedInstancePollsterTimestamp
            rTs @?= vTs
            dTs @?= vTs
            fTs @?= vTs
            vSd @?= expectedInstanceVCpuSd
            vP  @?= expectedInstanceVCpuPayload
            rSd @?= expectedInstanceRamSd
            rP  @?= expectedInstanceRamPayload
            dSd @?= expectedInstanceDiskSd
            dP  @?= expectedInstanceDiskPayload
            fSd @?= expectedInstanceFlavorSd
            fP  @?= expectedInstanceFlavorPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedInstance has ", show n, " elements:, ", show xs, ". Expected 4"]

testNetworkRxTx :: IO ()
testNetworkRxTx = runTestPublisher $ do
    rxJSON <- liftIO $ BSL.readFile "test/json_files/network_rx.json"
    txJSON <- liftIO $ BSL.readFile "test/json_files/network_tx.json"
    processedRx <- processSample rxJSON
    liftIO $ case processedRx of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedNetworkRxSd
            ts @?= expectedNetworkRxTimestamp
            p  @?= expectedNetworkRxPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedRx has ", show n, " elements:, ", show xs, ". Expected 1"]
    processedTx <- processSample txJSON
    liftIO $ case processedTx of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedNetworkTxSd
            ts @?= expectedNetworkTxTimestamp
            p  @?= expectedNetworkTxPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedTx has ", show n, " elements:, ", show xs, ". Expected 1"]

testDiskReadWrite :: IO ()
testDiskReadWrite = runTestPublisher $ do
    readJSON  <- liftIO $ BSL.readFile "test/json_files/disk_read.json"
    writeJSON <- liftIO $ BSL.readFile "test/json_files/disk_write.json"
    processedRead <- processSample readJSON
    liftIO $ case processedRead of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedDiskReadSd
            ts @?= expectedDiskReadTimestamp
            p  @?= expectedDiskReadPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedRead has ", show n, " elements:, ", show xs, ". Expected 1"]
    processedWrite <- processSample writeJSON
    liftIO $ case processedWrite of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedDiskWriteSd
            ts @?= expectedDiskWriteTimestamp
            p  @?= expectedDiskWritePayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedWrite has ", show n, " elements:, ", show xs, ". Expected 1"]

testCpu :: IO ()
testCpu = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/cpu.json"
    processedCpu <- processSample rawJSON
    liftIO $ case processedCpu of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedCpuSd
            ts @?= expectedCpuTimestamp
            p  @?= expectedCpuPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedCpu has ", show n, " elements:, ", show xs, ". Expected 1"]

testImagePollster :: IO ()
testImagePollster = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/image_size_pollster.json"
    processedImagePollster <- processSample rawJSON
    liftIO $ case processedImagePollster of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedImagePollsterSd
            ts @?= expectedImagePollsterTimestamp
            p  @?= expectedImagePollsterPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedImagePollster has ", show n, " elements:, ", show xs, ". Expected 1"]

testSnapshot :: IO ()
testSnapshot = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/snapshot_size.json"
    processedSnapshot <- processSample rawJSON
    liftIO $ case processedSnapshot of
        [x@(_, sd, ts, p)] -> do
            sd @?= expectedSnapshotSd
            ts @?= expectedSnapshotTimestamp
            p  @?= expectedSnapshotPayload
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedSnapshot has ", show n, " elements:, ", show xs, ". Expected 1"]

testIgnoreDiskRequests :: IO ()
testIgnoreDiskRequests = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/disk_write_requests.json"
    processedDiskRequest <- processSample rawJSON
    liftIO $ case processedDiskRequest of
        [] -> return ()
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedDiskRequest has ", show n, " elements:, ", show xs, ". Expected 0"]

testIgnoreSizedInstances :: IO ()
testIgnoreSizedInstances = runTestPublisher $ do
    rawJSON <- liftIO $ BSL.readFile "test/json_files/instance_tiny.json"
    processedSizedInstance <- processSample rawJSON
    liftIO $ case processedSizedInstance of
        [] -> return ()
        xs -> do
            let n = length xs
            assertFailure $ concat ["processedSizedInstance has ", show n, " elements:, ", show xs, ". Expected 0"]

newtype WrappedTimeStamp = WrappedTimeStamp { unwrap :: TimeStamp }

instance Show WrappedTimeStamp where
    show = show . unwrap

instance FromJSON WrappedTimeStamp where
    parseJSON (Object x) = WrappedTimeStamp <$> x .: "x"

testTimeStamp :: IO ()
testTimeStamp = do
    let wrap ts = "{\"x\": \"" <> ts <> "\"}"
    let f ts = fmap unwrap $ decode $ wrap ts
    let basic1 = f "1970-01-01 00:00:00"
    let basic2 = f "1970-01-01T00:00:00Z"
    let tz1    = f "1970-01-01 00:00:00-0200"
    let tz2    = f "1993-03-17T21:00:00+1000"
    basic1 @?= (Just $ TimeStamp 0)
    basic2 @?= (Just $ TimeStamp 0)
    tz1    @?= (Just $ TimeStamp (7200*10^9))
    tz2    @?= (Just $ TimeStamp (732366000*10^9))
