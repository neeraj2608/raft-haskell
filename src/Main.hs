module Main where

import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import Control.Monad
import Node
import GHC.Int (Int64)
import System.IO
import System.Random
import System.Time
import Types
import qualified Data.Map as Map

main :: IO ()
main = do
        connectionMap <- newTVarIO Map.empty
        let nodeIds = ["A", "B", "C", "D", "E"] -- this should ideally come from a config file
        let ports = ["2344", "2345", "2346", "2347", "2348"] -- this should ideally come from a config file
        let nodes = map (Node . Just) nodeIds

        logFile <- openFile "nodeLog.txt" WriteMode -- the filename should come from a config file

        -- Init all the nodes
        mapM_ (startNode connectionMap logFile) (zip nodes ports)

        -- Send some test commands
        createDelay 6 -- let the system settle down
        sendCommand (ClientReq "testClientCommand1") (getId $ nodes!!3) connectionMap

        createDelay 2 -- let the system settle down
        sendCommand (ClientReq "testClientCommand2") (getId $ nodes!!2) connectionMap

        -- TODO: Here we should actually have an infinite loop that looks at
        -- incoming messages on this port
        createDelay 10

        hClose logFile

createDelay :: Int64 -> IO ()
createDelay duration = do
    tVar <- newEmptyMVar
    _ <- forkIO (do _ <- oneShotTimer (putMVar tVar True) (sDelay duration); return ())
    void $ takeMVar tVar

startNode :: ConnectionMap -> Handle -> (Node, Port) -> IO()
startNode connectionMap logFileHandle nodePort = void $ forkIO $ uncurry initNode nodePort connectionMap logFileHandle

initNode :: Node -> Port -> ConnectionMap -> Handle -> IO ()
initNode node _ m logFileHandle = do
        ibox <- newTChanIO
        time <- System.Time.toCalendarTime =<< getClockTime
        let std = mkStdGen $ fromIntegral $ ctPicosec time
            (dur, newStd) = randomR (150000, 300000) std
            initState = NodeStateDetails Follower 0 Nothing Nothing [] 0 (getId node) ibox m [] newStd dur
        atomically $ modifyTVar m (Map.insert (getId node) ibox)
        void $ forkIO $ Node.startInboxListener initState logFileHandle -- loop continuously and atomically check ibox for messages
