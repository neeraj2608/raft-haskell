module Main where

import Types
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Map as Map
import Control.Monad
import Node

type Port = String
type ConnectionMap = TVar (Map.Map Node (TChan Command))

main :: IO ()
main = do
        -- Create an inbox for each node and adds a node -> Inbox
        -- mapping in ConnectionMap
        -- Each node keeps looking at its inbox for messages
        connectionMap <- newTVarIO Map.empty
        let nodeIds = ["A", "B", "C"] -- this should ideally come from a config file
        let ports = ["2344", "2345", "2346"] -- this should ideally come from a config file
        let nodes = map (Node . Just) nodeIds
        mapM_ (forkNode connectionMap) (zip nodes ports)

        -- Init all the nodes
        m <- readTVarIO connectionMap
        mapM_ initNode $ Map.elems m
        sendCommand AcceptClientReq (Map.lookup (head nodes) m)

        --sanity check
        putStr $ unlines $ map show $ Map.keys m

initNode :: TChan Command -> IO ()
initNode = sendCommand Bootup . Just

forkNode :: ConnectionMap -> (Node, Port) -> IO()
forkNode connectionMap nodePort = do
        forkIO $ uncurry startNode nodePort connectionMap
        return ()

startNode :: Node -> Port -> ConnectionMap -> IO ()
startNode node _ m = do
        ibox <- newTChanIO -- inbox is empty to begin with
        atomically $ modifyTVar m (Map.insert node ibox)
        forkIO $ Node.startNodeLifeCycle ibox -- loop continuously and atomically check ibox for messages
        return ()

-- | Send a command to a node's inbox
-- TODO: eventually change the signature to Command -> Node -> IO ()
sendCommand :: Command -> Maybe (TChan Command) -> IO ()
sendCommand cmd (Just ibox) = do
        putStrLn $ "Sending command " ++ show cmd
        atomically $ writeTChan ibox cmd
