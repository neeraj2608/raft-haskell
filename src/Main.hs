module Main where

import Types
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Map as Map

type Port = String
type ConnectionMap = TVar (Map.Map Node (TVar Inbox))

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

        -- Send a command to a node by writing to its inbox
        m <- readTVarIO connectionMap
        sendCommand Bootup $ Map.lookup (head nodes) m
        sendCommand Bootup $ Map.lookup (nodes !! 1) m

        --sanity check
        putStr $ unlines $ map show $ Map.keys m
        cmds <- mapM displayContents $ Map.elems m
        putStr $ unlines cmds
        where
            displayContents :: TVar Inbox -> IO String
            displayContents ibox = do
                (Inbox x) <- readTVarIO ibox
                return $ concatMap show x

forkNode :: ConnectionMap -> (Node, Port) -> IO()
forkNode connectionMap nodePort = do
        forkIO $ uncurry startNode nodePort connectionMap
        return ()

startNode :: Node -> Port -> ConnectionMap -> IO ()
startNode node _ m = do
        ibox <- newTVarIO $ Inbox [] -- inbox is empty to begin with
        atomically $ modifyTVar m (Map.insert node ibox)
        forkIO $ startNodeLifeCycle ibox -- loop continuously and atomically check ibox for messages
        return ()

startNodeLifeCycle :: TVar Inbox -> IO ()
startNodeLifeCycle _ = undefined

-- | Send a command to a node's inbox
-- TODO: eventually change the signature to Command -> Node -> IO ()
sendCommand :: Command -> Maybe (TVar Inbox) -> IO ()
sendCommand cmd (Just ibox) = atomically $ modifyTVar ibox (\x -> Inbox $ cmd:contents x)
