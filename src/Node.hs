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
import Control.Concurrent.STM

--main :: IO ()
--main = do
--        (lg,_) <- run Bootup
--        putStrLn "Log:"
--        putStrLn $ unlines $ map show lg
--        return ()

startInboxListener :: TChan Command -> IO ()
startInboxListener ibox = forever $ do
    cmd <- atomically $ readTChan ibox
    (lg,_) <- Node.run cmd
    putStrLn "Log:"
    putStrLn $ unlines $ map show lg

toNWS :: NodeStateDetails -> NWS ()
toNWS = put

liftio :: IO a -> WriterT Log (StateT NodeStateDetails IO) a
liftio = lift . lift

run :: Command -> IO (Log, NodeStateDetails)
run cmd = runStateT (execWriterT updateState) initState -- runWriterT :: WriterT w m a -> m (a, w); w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails
                                                        -- runStateT :: StateT s m a -> s -> m (a, s); s = NodeStateDetails, m = IO, a = Log
                                                        -- execWriterT :: Monad m => WriterT w m a -> m w; w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails
        where initState = NodeStateDetails Follower 0 Nothing Nothing [] 0 0 (Just "node1") [cmd]

updateState :: NWS NodeStateDetails
updateState = do
        nsd <- get
        let currentState = currRole nsd
            ibox = inbox nsd
        logInfo $ "Role " ++ show currentState
        if null ibox
            then return nsd
            else do
                let ([cmd],rest) = splitAt 1 ibox
                put nsd{inbox=rest}
                case currentState of
                  -- TODO add handlers for Leader and Candidate
                  Follower -> do
                    logInfo (show cmd)
                    liftM incTermIndex $ Node.processCommand cmd
                  Candidate -> do
                    logInfo (show cmd)
                    return nsd

incTermIndex :: NodeStateDetails -> NodeStateDetails
incTermIndex nsd = nsd{lastLogIndex=lastLogIndex nsd + 1, lastLogTerm=lastLogTerm nsd + 1}

-- TODO move this to the Follower module
processCommand :: Command -> NWS NodeStateDetails
processCommand cmd =
        processCommand' >> modify incTermIndex >> updateState
        where
              processCommand' = do
                  nsd <- get
                  case cmd of
                      Bootup -> do
                          tVar <- liftio newEmptyMVar
                          liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
                          logInfo "Waiting..."
                          liftio $ takeMVar tVar -- wait for election timeout to expire
                          liftio $ putStrLn "Election time expired"
                          let ibox = inbox nsd
                          when (null ibox) $ -- nothing in our inbox, switch to candidate
                              do
                                  logInfo "Switching to Candidate"
                                  put nsd{currRole=Candidate, inbox=StartCanvassing:ibox}

-- | Log a string. Uses the current term and index
logInfo :: String -> NWS ()
logInfo info = do
        nsd <- get
        let nodeid = nodeId nsd
        let index = lastLogIndex nsd
        let term = lastLogTerm nsd
        tell [((index,term),fromJust nodeid ++ " " ++ info)]
