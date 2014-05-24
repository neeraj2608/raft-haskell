module Main where

import Types
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import qualified Data.Map as Map
import Node
import Control.Monad
import GHC.Int (Int64)

main :: IO ()
main = do
        connectionMap <- newTVarIO Map.empty
        let nodeIds = ["A", "B", "C", "D", "E"] -- this should ideally come from a config file
        let ports = ["2344", "2345", "2346", "2347", "2348"] -- this should ideally come from a config file
        let nodes = map (Node . Just) nodeIds

        -- Init all the nodes
        mapM_ (startNode connectionMap) (zip nodes ports)

        -- Send some test commands
        createDelay 2
        sendCommand ClientReq (getId $ nodes!!3) connectionMap

        -- TODO: Here we should actually have an infinite loop that looks at
        -- incoming messages on this port
        createDelay 10

        --sanity check
        --putStr $ unlines $ map show $ Map.keys m

createDelay :: Int64 -> IO ()
createDelay duration = do
    tVar <- newEmptyMVar
    _ <- forkIO (do _ <- oneShotTimer (putMVar tVar True) (sDelay duration); return ())
    void $ takeMVar tVar

startNode :: ConnectionMap -> (Node, Port) -> IO()
startNode connectionMap nodePort = void $ forkIO $ uncurry initNode nodePort connectionMap

initNode :: Node -> Port -> ConnectionMap -> IO ()
initNode node _ m = do
        ibox <- newTChanIO
        let initState = NodeStateDetails Follower 0 Nothing Nothing [] 0 0 0 (getId node) ibox m
        atomically $ modifyTVar m (Map.insert (getId node) ibox)
        void $ forkIO $ Node.startInboxListener initState -- loop continuously and atomically check ibox for messages
