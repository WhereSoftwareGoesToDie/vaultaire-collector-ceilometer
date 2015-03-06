{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process
    ( processSample
    , retrieveMessage
    , runCollector
    , initState
    , cleanup
    , ackLast
    , module Process
    ) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Aeson
import qualified Data.ByteString.Lazy.Char8                      as L
import           Data.Monoid
import qualified Data.Text                                       as T
import           Data.Word
import           Options.Applicative                             hiding
                                                                  (Success)
import           System.Log.Logger
import           System.ZMQ4

import           Marquise.Client
import           Vaultaire.Collector.Common.Process              hiding
                                                                  (runCollector)
import qualified Vaultaire.Collector.Common.Process              as V (runCollector)
import           Vaultaire.Collector.Common.Types                hiding
                                                                  (Collector)

import           Vaultaire.Collector.Ceilometer.Process.Common   as Process
import           Vaultaire.Collector.Ceilometer.Process.Image    as Process
import           Vaultaire.Collector.Ceilometer.Process.Instance as Process
import           Vaultaire.Collector.Ceilometer.Process.IP       as Process
import           Vaultaire.Collector.Ceilometer.Process.Snapshot as Process
import           Vaultaire.Collector.Ceilometer.Process.Volume   as Process
import           Vaultaire.Collector.Ceilometer.Types

parseOptions :: Parser CeilometerOptions
parseOptions = CeilometerOptions
    <$> strOption
        (long "publisher-host"
         <> short 'H'

         <> metavar "HOSTNAME"
         <> help "ceilometer-publisher-zeromq host")
    <*> option auto
        (long "publisher-port"
         <> short 'p'
         <> value 8282
         <> metavar "PORT"
         <> help "ceilometer-publisher-zeromq port")

-- | Initialise ZMQ socket and context
initState :: CollectorOpts CeilometerOptions -> IO CeilometerState
initState (_, CeilometerOptions{..}) = do
    c <- context
    sock <- socket c Rep
    let connString = "tcp://" <> zmqHost <> ":" <> show zmqPort
    bind sock connString
    infoM "Ceilometer.Process.initState" $ "Listening to publishers at " <> connString
    return $ CeilometerState sock c

-- | Cleans up ZMQ socket and context
cleanup :: Collector ()
cleanup = do
    (_, CeilometerState{..}) <- get
    liftIO $ close zmqSocket
    liftIO $ term  zmqContext

-- | Core entry point for Ceilometer.Process
--   Processes JSON objects from the configured publisher and
--   writes out SimplePoints and SourceDicts to spool files
runCollector :: IO ()
runCollector = V.runCollector parseOptions initState cleanup publishSamples
  where
    publishSamples = forever $ retrieveMessage >>= processSample >>= mapM_ collectData >> ackLast
    collectData (addr, sd, ts, p) = do
        collectSource addr sd
        collectSimple (SimplePoint addr ts p)

-- | Blocking read from ceilometer-publisher-zeromq
retrieveMessage :: Collector L.ByteString
retrieveMessage = do
    (_, CeilometerState{..}) <- get
    liftIO $ L.fromStrict <$> receive zmqSocket

-- | Ack last message received from ceilometer-publisher-zeromq
ackLast :: Collector ()
ackLast = do
    (_, CeilometerState{..}) <- get
    liftIO $ send zmqSocket [] ""

-- | Takes in a JSON Object and processes it into a list of
--   (Address, SourceDict, TimeStamp, Payload) tuples
processSample :: L.ByteString -> Collector [(Address, SourceDict, TimeStamp, Word64)]
processSample bs =
    case eitherDecode bs of
        Left e  -> do
            liftIO $ alertM "Ceilometer.Process.processSample" $
                "Failed to parse: " <> L.unpack bs <> " Error: " <> e
            return []
        Right m -> process m

-- | Primary processing function, converts a parsed Ceilometer metric
--   into a list of vaultaire SimplePoint and SourceDict data
process :: Metric -> Collector [(Address, SourceDict, TimeStamp, Word64)]
process m = process' (metricName m) (isEvent m)
  where
-- Supported metrics
    -- We process both instance pollsters and events
    process' "instance"                   False = yell >> processInstancePollster   m
    process' "instance"                   True  = yell >> processInstanceEvent      m
    process' "cpu"                        False = yell >> processBasePollster       m
    process' "disk.write.bytes"           False = yell >> processBasePollster       m
    process' "disk.read.bytes"            False = yell >> processBasePollster       m
    process' "network.incoming.bytes"     False = yell >> processBasePollster       m
    process' "network.outgoing.bytes"     False = yell >> processBasePollster       m
    process' "ip.floating"                True  = yell >> processIpEvent            m
    process' "volume.size"                True  = yell >> processVolumeEvent        m
    -- We process both image.size pollsters and events
    process' "image.size"                 False = yell >> processBasePollster       m
    process' "image.size"                 True  = yell >> processImageSizeEvent     m
    process' "snapshot.size"              True  = yell >> processSnapshotSizeEvent  m

    -- Ignored metrics
    -- Tracking both disk.r/w and disk.device.r/w will most likely double count
    process' x@"disk.device.write.bytes"    y       = ignore x y
    process' x@"disk.device.read.bytes"     y       = ignore x y
    -- We meter on bytes not requests
    process' x@"disk.write.requests"        y       = ignore x y
    process' x@"disk.read.requests"         y       = ignore x y
    process' x@"disk.device.write.requests" y       = ignore x y
    process' x@"disk.device.read.requests"  y       = ignore x y
    -- We derive these from instance pollsters
    process' x@"disk.ephemeral.size"        y@True  = ignore x y
    process' x@"disk.root.size"             y@True  = ignore x y
    process' x@"volume"                     y       = ignore x y
    process' x@"vcpus"                      y       = ignore x y
    process' x@"memory"                     y       = ignore x y
    -- We meter on bytes not packets
    process' x@"network.incoming.packets"   y       = ignore x y
    process' x@"network.outgoing.packets"   y       = ignore x y
    -- We use notifications over pollsters for ip-allocations
    process' x@"ip.floating"                y@False = ignore x y

    process' x@"ip.floating.create"         y       = ignore x y
    process' x@"ip.floating.update"         y       = ignore x y
    process' x@"ip.floating.delete"         y       = ignore x y
    -- These seem to be linked to constructing the stack, and are not common
    -- We potentially care about the network/disk I/O of these ops
    process' x@"image"                      y       = ignore x y
    process' x@"image.update"               y@True  = ignore x y
    process' x@"image.download"             y@True  = ignore x y
    process' x@"image.serve"                y@True  = ignore x y
    process' x@"image.upload"               y@True  = ignore x y
    process' x@"image.delete"               y@True  = ignore x y

    -- We care about ip allocations, these metrics are superfluous
    process' x@"port"                       y       = ignore x y
    process' x@"port.create"                y       = ignore x y
    process' x@"port.update"                y       = ignore x y
    process' x@"port.delete"                y       = ignore x y
    process' x@"network"                    y       = ignore x y
    process' x@"network.create"             y       = ignore x y
    process' x@"network.update"             y       = ignore x y
    process' x@"network.delete"             y       = ignore x y
    process' x@"subnet"                     y       = ignore x y
    process' x@"subnet.create"              y       = ignore x y
    process' x@"subnet.update"              y       = ignore x y
    process' x@"subnet.delete"              y       = ignore x y
    process' x@"router"                     y       = ignore x y
    process' x@"router.create"              y       = ignore x y
    process' x@"router.update"              y       = ignore x y
    process' x@"router.delete"              y       = ignore x y
    process' x@"snapshot"                   y       = ignore x y
    process' x@"network.services.firewall.policy" y = ignore x y

    process' x y
        | "instance:" `T.isPrefixOf` x = ignore x y
        | otherwise = alert x y
    ignore x y = do
        liftIO $ infoM "Ceilometer.Process.processSample" $
            "Ignored metric: " <> show x <> " event: " <> show y
        return []
    yell =
        liftIO $ infoM "Ceilometer.Process.processSample" $
            "Process metric: " <> show (metricName m) <> " event: " <> show (isEvent m) <> " resource-id: " <> show (metricResourceId m)
    alert x y = do
        liftIO $ alertM "Ceilometer.Process.processSample" $
            "Unexpected metric: " <> show x <> " event: " <> show y <>
            "\n" <> show m
        return []
