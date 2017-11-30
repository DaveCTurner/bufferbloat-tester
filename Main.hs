{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent (threadDelay)
import Data.Monoid
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import Data.Binary.Get
import Data.ByteString.Builder
import Data.ByteString.Builder.Extra
import Data.Conduit
import Data.Conduit.Binary hiding (drop)
import Data.Conduit.ByteString.Builder
import Data.Conduit.Network.UDP
import Data.Time
import Data.Time.ISO8601
import Data.Word
import Data.Int
import Network.Socket
import Options.Applicative
import Options.Generic
import System.Clock
import Text.Printf
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Conduit.List as DCL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

data Options
  = Server { listenPort :: String }
  | Client { remoteAddr :: String
           , durationSecs :: Int
           , rateBytesPerSec :: Int
           }
  deriving (Generic, Show)

instance ParseRecord Options

newtype ServerTime = ServerTime { unServerTime :: Integer } deriving (Show, Eq)
subtractServerTime :: ServerTime -> ServerTime -> ServerTime
subtractServerTime (ServerTime t1) (ServerTime t2) = ServerTime (t1 - t2)

newtype ClientTime = ClientTime { unClientTime :: Integer } deriving (Show, Eq)
subtractClientTime :: ClientTime -> ClientTime -> ClientTime
subtractClientTime (ClientTime t1) (ClientTime t2) = ClientTime (t1 - t2)

data ReceivedMessage = ReceivedMessage
  { rmServerTime :: ServerTime
  , rmClientTime :: ClientTime
  , rmSequenceNumber :: Word64
  } deriving (Show, Eq)

main :: IO ()
main = withSocketsDo $ getRecord "bufferbloat-tester" >>= \case
  Server{..} -> do

    let hints = defaultHints
          { addrFlags = [AI_PASSIVE]
          , addrFamily = AF_INET
          , addrSocketType = Datagram
          }

    addrs <- getAddrInfo (Just hints) Nothing (Just listenPort)

    bracket (socket AF_INET Datagram defaultProtocol)
            (close)
            $ \sock -> do

      bind sock $ addrAddress $ addrs !! 0

      let messagesToLogEntries = await >>= \case

            Just msg | B.length (msgData msg) > 24 -> do

                  receivedTime <- liftIO $ ServerTime <$> toNanoSecs <$> getTime Monotonic

                  let (ct, sq) = flip runGet (BL.fromStrict $ msgData msg) $ do
                          ctSec <- getInt64be
                          ctNsec <- getInt64be
                          sq <- getWord64be
                          return (ClientTime $ toNanoSecs $ TimeSpec ctSec ctNsec, sq)

                  yield ReceivedMessage
                    { rmServerTime = receivedTime
                    , rmClientTime = ct
                    , rmSequenceNumber = sq
                    }

                  messagesToLogEntries

            Just msg | B.take 4 (msgData msg) == "DONE" -> return ()

            _ -> messagesToLogEntries

          offsetFromFirstMessage = await >>= \case
            Nothing -> return ()
            Just rm0 -> let
              offsetServerTime = flip subtractServerTime (rmServerTime rm0)
              offsetClientTime = flip subtractClientTime (rmClientTime rm0)
              applyOffset rm = rm
                { rmServerTime = offsetServerTime (rmServerTime rm)
                , rmClientTime = offsetClientTime (rmClientTime rm)
                }
              in (yield rm0 >> awaitForever yield) =$= DCL.map applyOffset

          openLogOnFirstMessage = await >>= \case
            Nothing -> return ()
            Just rm -> do
              let fixChar c = if c `elem` ("T:" :: String) then '.' else c
              now <- map fixChar <$> formatISO8601Millis <$> liftIO getCurrentTime
              let logFileName = "bufferbloat-tester-" ++ now ++ ".log"
              (yield rm >> awaitForever yield)
                =$= DCL.map formatTabSeparated
                =$= (awaitForever yield >> yield (T.encodeUtf8 "Finished\n"))
                =$= sinkFile logFileName

          formatTabSeparated rm = T.encodeUtf8 $ T.pack $ printf
            "%d\t%d\t%d\n" (rmSequenceNumber rm)
                           (unClientTime $ rmClientTime rm)
                           (unServerTime $ rmServerTime rm)

      forever $ do
        runResourceT $ runConduit
                $  sourceSocket sock 4096
               =$= messagesToLogEntries
               =$= offsetFromFirstMessage
               =$= openLogOnFirstMessage

        putStrLn "Finished run"

  Client{..} -> do

    bracket (socket AF_INET Datagram defaultProtocol)
            (close)
            $ \sock -> do

      let (host, colonPort) = break (== ':') remoteAddr

      let hints = defaultHints
            { addrFlags = []
            , addrFamily = AF_INET
            , addrSocketType = Datagram
            }

      addrs <- getAddrInfo (Just hints) (Just host) (Just $ drop 1 colonPort)
      let destination = addrAddress $ addrs !! 0

      startTimeNsec <- toNanoSecs <$> getTime Monotonic

      let maxBucketLevel = 1000000
          durationNSec = fromIntegral durationSecs * 1000000000

      let generatePackets sequenceNumber lastBucketLevel lastSendTimeNsec = do
            now <- liftIO $ getTime Monotonic
            let nowNsec = toNanoSecs now
            when (nowNsec - startTimeNsec < durationNSec) $

              let nextBucketLevel = lastBucketLevel
                        - (fromIntegral rateBytesPerSec * (nowNsec - lastSendTimeNsec))
                            `div` 1000000000
                        + 1024

              in if nextBucketLevel > maxBucketLevel
                  then do
                    liftIO $ threadDelay 10000
                    generatePackets sequenceNumber lastBucketLevel lastSendTimeNsec

                  else do
                    yield $ BL.toStrict $ toLazyByteString
                                $  int64BE (sec  now)
                                <> int64BE (nsec now)
                                <> word64BE sequenceNumber
                                <> padding
                    generatePackets (sequenceNumber + 1) nextBucketLevel nowNsec

      bracket (socket AF_INET Datagram defaultProtocol)
              (close)
              $ \sock ->

        runConduit $ generatePackets 0 1000000 startTimeNsec
          =$= (awaitForever yield >> yield (T.encodeUtf8 "DONE"))
          =$= DCL.map (\msg -> Message msg destination)
          =$= sinkToSocket sock

padding :: Builder
padding = byteString (B.replicate 1000 0x40)
