module Node where

{-
  Generalized Raft node.
  This models all the state transitions and functionality
  of a node.
  
  Leader needs to keep track of its followers (this list can
  be initialized when the leader was still a candidate) so it knows
  how many followers it has. This way, it can decide when
  a "majority" has responded. Leader also must keep track
  of the nextIndex and matchIndex for each of its followers.
  
  Followers need to keep track of the leader so e.g. they
  can forward requests erroneously sent to them by clients
-}

import Types
import Control.Monad.State
import Control.Monad.Writer
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Data.Maybe (fromJust)

main :: IO ()
main = do
        (lg,_) <- run Bootup
        putStrLn "Log:"
        putStrLn $ unlines $ map show lg
        return ()

toNWS :: NodeStateDetails -> NWS ()
toNWS = put

liftio :: IO a -> WriterT Log (StateT NodeStateDetails IO) a
liftio = lift . lift

run :: Command -> IO (Log, NodeStateDetails)
run cmd = runStateT (execWriterT (updateStateT cmd)) initState -- runWriterT :: WriterT w m a -> m (a, w)
                                                               -- runStateT :: StateT s m a -> s -> m (a, s)
        where initState = NodeStateDetails Follower 0 Nothing Nothing [] 0 0 (Just "node1")


updateStateT :: Command -> NWS ()
updateStateT cmd = do
        nsd <- get
        let currentState = curState nsd
        case currentState of
          Follower -> do
            logInfo (show cmd)
            newNsd <- Node.handleCommand cmd nsd
            put newNsd

handleCommand :: Command -> NodeStateDetails -> NWS NodeStateDetails
handleCommand cmd nsd =
        case cmd of
            Bootup -> do
                tVar <- liftio newEmptyMVar
                liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration
                logInfo "Waiting..."
                liftio $ takeMVar tVar
                liftio $ putStrLn "Timeout"
                logInfo "Switching to Leader"
                return nsd{curState=Leader}
            _ -> undefined

logInfo :: String -> NWS ()
logInfo info = do
        nsd <- get
        let nodeid = nodeId nsd
        let index = lastLogIndex nsd
        let term = lastLogTerm nsd
        tell [((index,term),fromJust nodeid ++ " " ++ info)]
