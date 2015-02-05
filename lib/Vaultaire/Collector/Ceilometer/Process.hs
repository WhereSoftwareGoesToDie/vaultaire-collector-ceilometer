{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Vaultaire.Collector.Ceilometer.Process
    ( processSample
    , processError
    , retrieveMessage
    , runErrorCollector
    , runCollector
    , initState
    , cleanup
    , module Process
    ) where

import           Control.Applicative
import           Control.Concurrent                              hiding (yield)
import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Aeson
import           Data.Bifunctor
import qualified Data.ByteString                                 as S
import qualified Data.ByteString.Lazy.Char8                      as L
import qualified Data.HashMap.Strict                             as H
import           Data.Monoid
import qualified Data.Text                                       as T
import qualified Data.Text.Encoding                              as T
import qualified Data.Text.IO                                    as T
import           Data.Word
import           Network.AMQP
import           Options.Applicative                             hiding
                                                                  (Success)
import           System.IO
import           System.Log.Logger

import           Marquise.Client
import           Vaultaire.Collector.Common.Process              hiding
                                                                  (runCollector,
                                                                  runCollectorN)
import qualified Vaultaire.Collector.Common.Process              as V (runCollector, runCollectorN)
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
    <$> (T.pack <$> strOption
        (long "rabbit-login"
         <> short 'u'
         <> metavar "USERNAME"
         <> help "RabbitMQ username"))
    <*> (T.pack <$> strOption
        (long "rabbit-virtual-host"
         <> short 'r'
         <> metavar "VIRTUAL_HOSTNAME"
         <> value "/"
         <> help "RabbitMQ virtual host"))
    <*> strOption
        (long "rabbit-host"
         <> short 'H'
         <> metavar "HOSTNAME"
         <> help "RabbitMQ host")
    <*> option auto
        (long "rabbit-port"
         <> short 'p'
         <> value 5672
         <> metavar "PORT"
         <> help "RabbitMQ port")
    <*> switch
        (long "rabbit-ha"
         <> short 'a'
         <> help "Use highly available queues for RabbitMQ")
    <*> switch
        (long "rabbit-ssl"
        <> short 's'
        <> help "Use SSL for RabbitMQ")
    <*> (T.pack <$> strOption
        (long "rabbit-queue"
         <> short 'q'
         <> value "metering"
         <> metavar "QUEUE"
         <> help "RabbitMQ queue"))
    <*> option auto
        (long "poll-period"
         <> short 't'
         <> value 5
         <> metavar "POLL-PERIOD"
         <> help "Time to wait (in seconds) before re-querying empty queue.")
    <*> strOption
        (long "password-file"
         <> short 'f'
         <> metavar "PASSWORD-FILE"
         <> help "File containing the password to use for RabbitMQ")

initState :: CollectorOpts CeilometerOptions -> IO CeilometerState
initState (_, CeilometerOptions{..}) = do
     password <- T.strip <$> withFile rabbitPasswordFile ReadMode T.hGetContents
     conn <- openConnection' rabbitHost (fromInteger rabbitPort) rabbitVHost rabbitLogin password
     infoM "Ceilometer.Process.initState" "Connected to RabbitMQ server"
     chan <- openChannel conn
     infoM "Ceilometer.Process.initState" "Opened channel"
     return $ CeilometerState conn chan

cleanup :: Collector ()
cleanup = do
    (_, CeilometerState conn _ ) <- get
    liftIO $ closeConnection conn

-- | Core entry point for Ceilometer.Process
--   Processes JSON objects from the configured queue and publishes
--   SimplePoints and SourceDicts to the vault
runCollector :: IO ()
runCollector = V.runCollectorN parseOptions initState cleanup publishSamples
  where
    publishSamples = do
        (_, CeilometerOptions{..}) <- ask
        (_, CeilometerState{..}) <- get
        forever $ do
            msg <- retrieveMessage
            case msg of
                Nothing -> liftIO $ do
                    infoM "Ceilometer.Process.publishSamples" $
                        "No message received, sleeping for " <> show rabbitPollPeriod <> " s"
                    threadDelay (1000000 * rabbitPollPeriod)
                Just (msg', env) -> do
                    tuples <- processSample msg'
                    forM_ tuples collectData
                    liftIO $ ackEnv env

runErrorCollector :: IO ()
runErrorCollector = V.runCollector parseOptions initState cleanup publishErrors
  where
    publishErrors = do
        (_, CeilometerOptions{..}) <- ask
        (_, CeilometerState{..}) <- get
        forever $ do
            msg <- retrieveMessage
            case msg of
                Nothing          -> liftIO $ do
                    infoM "Ceilometer.Process.publishErrors" $
                        "No message received, sleeping for " <> show rabbitPollPeriod <> " s"
                    threadDelay (1000000 * rabbitPollPeriod)
                Just (msg', env) -> do
                    processed <- processError msg'
                    case processed of
                        Just x  -> collectError x
                        Nothing -> return ()
                    liftIO $ ackEnv env

retrieveMessage :: Collector (Maybe (L.ByteString, Envelope))
retrieveMessage = do
    (_, CeilometerOptions{..}) <- ask
    (_, CeilometerState{..}) <- get
    liftIO $ fmap (first msgBody) <$> getMsg ceilometerMessageChan Ack rabbitQueue

collectData :: (Address, SourceDict, TimeStamp, Word64) -> Collector ()
collectData (addr, sd, ts, p) = do
    collectSource addr sd
    collectSimple (SimplePoint addr ts p)

collectError :: (Address, SourceDict, TimeStamp, S.ByteString) -> Collector ()
collectError (addr, sd, ts, p) = do
    collectSource addr sd
    collectExtended (ExtendedPoint addr ts p)

processError :: L.ByteString -> Collector (Maybe (Address, SourceDict, TimeStamp, S.ByteString))
processError bs = case eitherDecode bs of
    Left e -> do
        liftIO $ alertM "Ceilometer.Process.publishErrors" $
                        "Failed to parse: " <> L.unpack bs <> " Error: " <> e
        return Nothing
    Right ErrorMessage{..} -> do
        let addr = hashIdentifier $ T.encodeUtf8 errorPublisher
        let sdPairs = [ ("publisher_id", errorPublisher)
                      , ("_extended", "1") ]
        sd <- liftIO $ mapToSourceDict $ H.fromList sdPairs
        return $ case sd of
            Just sd' -> Just (addr, sd', errorTimeStamp, mconcat $ L.toChunks bs)
            Nothing  -> Nothing

-- | Takes in a JSON Object and processes it into a list of
--   (Address, SourceDict, TimeStamp, Payload) tuples
processSample :: L.ByteString -> PublicationData
processSample bs =
    case eitherDecode bs of
        Left e  -> do
            liftIO $ alertM "Ceilometer.Process.processSample" $
                "Failed to parse: " <> L.unpack bs <> " Error: " <> e
            return []
        Right m -> process m

process :: Metric -> PublicationData
process m = process' (metricName m) (isEvent m)
  where
-- Supported metrics
    -- We process both instance pollsters and events
    process' "instance"                   False = processInstancePollster   m
    process' "instance"                   True  = processInstanceEvent      m
    process' "cpu"                        False = processBasePollster       m
    process' "disk.write.bytes"           False = processBasePollster       m
    process' "disk.read.bytes"            False = processBasePollster       m
    process' "network.incoming.bytes"     False = processBasePollster       m
    process' "network.outgoing.bytes"     False = processBasePollster       m
    process' "ip.floating"                True  = processIpEvent            m
    process' "volume.size"                True  = processVolumeEvent        m
    -- We process both image.size pollsters and events
    process' "image.size"                 False = processBasePollster       m
    process' "image.size"                 True  = processImageSizeEvent     m
    process' "snapshot.size"              True  = processSnapshotSizeEvent  m

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
    alert x y = do
        liftIO $ alertM "Ceilometer.Process.processSample" $
            "Unexpected metric: " <> show x <> " event: " <> show y <>
            "\n" <> show m
        return []
