module Main where

import Types
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Map as Map
import Node
import Data.Maybe
import Control.Monad

type Port = String
type ConnectionMap = TVar (Map.Map Node (TChan Command))

main :: IO ()
main = do
        connectionMap <- newTVarIO Map.empty
        let nodeIds = ["A", "B", "C"] -- this should ideally come from a config file
        let ports = ["2344", "2345", "2346"] -- this should ideally come from a config file
        let nodes = map (Node . Just) nodeIds

        -- Init all the nodes
        mapM_ (startNode connectionMap) (zip nodes ports)

        -- Send some test commands
        m <- readTVarIO connectionMap
        sendCommand AcceptClientReq (fromJust $ Map.lookup (head nodes) m)

        --sanity check
        putStr $ unlines $ map show $ Map.keys m

broadCast :: Command -> ConnectionMap -> IO ()
broadCast cmd connectionMap = do
        m <- readTVarIO connectionMap
        mapM_ (sendCommand cmd) $ Map.elems m

startNode :: ConnectionMap -> (Node, Port) -> IO()
startNode connectionMap nodePort = void $ forkIO $ uncurry initNode nodePort connectionMap

initNode :: Node -> Port -> ConnectionMap -> IO ()
initNode node _ m = do
        ibox <- newTChanIO
        atomically $ do
            writeTChan ibox Bootup -- put Bootup in the inbox so the node can start up
            modifyTVar m (Map.insert node ibox)
        void $ forkIO $ Node.startInboxListener ibox -- loop continuously and atomically check ibox for messages

-- | Send a command to a node's inbox
-- TODO: eventually change the signature to Command -> Node -> IO ()
sendCommand :: Command -> TChan Command -> IO ()
sendCommand cmd ibox = do
        putStrLn $ "Sending command " ++ show cmd
        atomically $ writeTChan ibox cmd
