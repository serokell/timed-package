{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}

module Main
    ( main
    , yohohoScenario
--    , rpcScenario
    , transferScenario
--    , runEmulation
--    , runReal
    ) where

import           Control.Monad                     (forever, when)
import           Control.Monad.Catch               (handleAll)
import           Control.Monad.Trans               (liftIO)
import           Data.Binary                       (Binary, Get, Put, get, put)
import           Data.Conduit                      (yield, (=$=))
import qualified Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (conduitGet, conduitPut)
import           Data.Data                         (Data)
import           Data.MessagePack                  (MessagePack (..))
import           Data.Void                         (Void)
import           Formatting                        (sformat, shown, string, (%))
import           GHC.Generics                      (Generic)

import           Control.TimeWarp.Logging          (Severity (Debug), initLogging,
                                                    logDebug, logError, logInfo,
                                                    logWarning, usingLoggerName)
import           Control.TimeWarp.Rpc              (Listener (..), Message,
                                                    MonadTransfer (..), NamedBinaryP (..),
                                                    NetworkAddress, Port, listenE,
                                                    listenOutboundE, localhost, reply,
                                                    replyRaw, runDialog, runTransfer,
                                                    send)
import           Control.TimeWarp.Timed            (MonadTimed (wait), Second, after, for,
                                                    fork_, ms, runTimedIO, schedule, sec',
                                                    till, work)

main :: IO ()
main = return ()  -- use ghci

{-
runReal :: MsgPackRpc a -> IO a
runReal = runMsgPackRpc

runEmulation :: PureRpc IO a -> IO a
runEmulation scenario = do
    gen <- newStdGen
    runPureRpc delays gen scenario
  where
    delays :: Microsecond
    delays = interval 50 ms
-}

-- * data types

data Ping = Ping
    deriving (Generic, Data, Binary, MessagePack, Message)

data Pong = Pong
    deriving (Generic, Data, Binary, MessagePack, Message)

instance Message Void

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    } deriving (Generic, Data, Binary, MessagePack)

instance Message EpicRequest


-- * scenarios

guy :: Int -> NetworkAddress
guy = (localhost, ) . guysPort

guysPort :: Int -> Port
guysPort = (+10000)

-- Emulates dialog of two guys:
-- 1: Ping
-- 2: Pong
-- 1: EpicRequest ...
-- 2: <prints result>
yohohoScenario :: IO ()
yohohoScenario = runTimedIO $ do
    liftIO $ initLogging ["guy"] Debug

    -- guy 1
    usingLoggerName "guy.1" . runTransfer . runDialog packing . fork_ $ do
        work (till finish) $
            listenE (guysPort 1) logError
                [ Listener $ \Pong -> ha $
                  do logDebug "Got Pong!"
                     reply $ EpicRequest 14 " men on the dead man's chest"
                ]
        -- guy 1 initiates dialog
        wait (for 100 ms)
        send (guy 2) Ping

    -- guy 2
    usingLoggerName "guy.2" . runTransfer . runDialog packing . fork_ $ do
        work (till finish) $
            listenE (guysPort 2) logError
                [ Listener $ \Ping ->
                  do logDebug "Got Ping!"
                     send (guy 1) Pong
                ]
        work (till finish) $
            listenOutboundE (guy 1) logError
                [ Listener $ \EpicRequest{..} -> ha $
                  do logDebug "Got EpicRequest!"
                     wait (for 0.1 sec')
                     logInfo $ sformat (shown%string) (num + 1) msg
                ]
    wait (till finish)
  where
    finish :: Second
    finish = 1

    ha = handleAll $ logError . sformat shown

    packing :: NamedBinaryP
    packing = NamedBinaryP


-- | Example of `Transfer` usage
transferScenario :: IO ()
transferScenario = runTimedIO $ do
    liftIO $ initLogging ["node"] Debug
    usingLoggerName "node.server" $ runTransfer $
        work (for 500 ms) $ ha $
            listenRaw 1234 (forever $ conduitGet decoder) $
            \req -> do
                logInfo $ sformat ("Got "%shown) req
                replyRaw $ yield (put $ sformat "Ok!") =$= conduitPut

    wait (for 100 ms)

    usingLoggerName "node.client-1" $ runTransfer $
        schedule (after 200 ms) $ ha $ do
            work (for 500 ms) $ ha $
                listenOutboundRaw (localhost, 1234) (forever $ conduitGet get) logInfo
            sendRaw (localhost, 1234) $  CL.sourceList ([1..5] :: [Int])
                                     =$= CL.map Left
                                     =$= CL.map encoder
                                     =$= conduitPut
--                                     =$= awaitForever (\m -> yield "trash" >> yield m)

    usingLoggerName "node.client-2" $ runTransfer $
        schedule (after 200 ms) $ ha $ do
            sendRaw (localhost, 1234) $  CL.sourceList ([1..5] :: [Int])
                                     =$= CL.map (, -1)
                                     =$= CL.map Right
                                     =$= CL.map encoder
                                     =$= conduitPut
            work (for 500 ms) $ ha $
                listenOutboundRaw (localhost, 1234) (forever $ conduitGet get) logInfo

    wait (for 1000 ms)
  where
    ha = handleAll $ logWarning . sformat ("Exception: "%shown)

    decoder :: Get (Either Int (Int, Int))
    decoder = do
        magic <- get
        when (magic /= magicVal) $
            fail "Missed magic constant!"
        get

    encoder :: Either Int (Int, Int) -> Put
    encoder d = put magicVal >> put d

    magicVal :: Int
    magicVal = 234

{-
rpcScenario :: IO ()
rpcScenario = runTimedIO $ do
    liftIO $ initLogging ["server", "cli"] Debug
    usingLoggerName "server" . runTransfer . runBinaryDialog . runRpc $
        work (till finish) $
            serve 1234
                [ Method $ \Ping -> do
                  do logInfo "Got Ping! Wait a sec..."
                     wait (for 1000 ms)
                     logInfo "Replying"
                     return Pong
                ]

    wait (for 100 ms)
    usingLoggerName "client" . runTransfer . runBinaryDialog . runRpc $ do
        Pong <- call (localhost, 1234) Ping
        logInfo "Got Pong!"
    return ()
  where
    finish :: Second
    finish = 5

-}
