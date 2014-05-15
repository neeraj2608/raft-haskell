module Driver where

{-
  Simulates network connections between different nodes.
  Used for testing algorithm implementation.
  
  Need to build in some delay in broadcastTimes for testing
-}

import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Types
import Node

main = do
    map (invokeCmd Bootup) nodeList
    return ()
    --repeatedTimer (putStrLn "hi") (msDelay 500)
    
    where
        nodeList = [Node "a", Node "b", Node "c", Node "d", Node "e"]
    -- have list of 5 nodes
    -- init every node
    -- nodes will pick leader
    -- send any of the 5 nodes a request