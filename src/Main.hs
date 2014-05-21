module Main where

import Types
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import qualified Data.Map as Map
import Node
import Data.Maybe (fromJust)
import Control.Monad

main :: IO ()
main = do
        connectionMap <- newTVarIO Map.empty
        let nodeIds = ["A", "B"] -- , "B", "C"] -- this should ideally come from a config file
        let ports = ["2344", "2345"] -- , "2345", "2346"] -- this should ideally come from a config file
        let nodes = map (Node . Just) nodeIds

        -- Init all the nodes
        mapM_ (startNode connectionMap) (zip nodes ports)

        -- Send some test commands
        --m <- readTVarIO connectionMap
        --sendCommand AcceptClientReq (fromJust $ Map.lookup (head nodes) m)

        -- TODO: Here we should actually have an infinite loop that looks at
        -- incoming messages on this port
        tVar <- newEmptyMVar
        forkIO (do oneShotTimer (putMVar tVar True) (sDelay 12); return ())
        void $ takeMVar tVar

        --sanity check
        --putStr $ unlines $ map show $ Map.keys m

startNode :: ConnectionMap -> (Node, Port) -> IO()
startNode connectionMap nodePort = void $ forkIO $ uncurry initNode nodePort connectionMap

initNode :: Node -> Port -> ConnectionMap -> IO ()
initNode node _ m = do
        ibox <- newTChanIO
        let initState = NodeStateDetails Follower 0 Nothing Nothing [] 0 0 0 (getId node) ibox m
        atomically $ modifyTVar m (Map.insert (getId node) ibox)
        void $ forkIO $ Node.startInboxListener initState -- loop continuously and atomically check ibox for messages
