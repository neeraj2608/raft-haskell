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
import Control.Concurrent.STM
import Text.Printf
import Follower

startInboxListener :: NodeStateDetails -> IO ()
startInboxListener nsd = forever $ do
    (lg,_) <- Node.run nsd
    putStrLn "Log:"
    putStrLn $ unlines $ map show lg

run :: NodeStateDetails -> IO (Log, NodeStateDetails)
run = runStateT (execWriterT updateState) -- runWriterT :: WriterT w m a -> m (a, w); w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails
                                          -- runStateT :: StateT s m a -> s -> m (a, s); s = NodeStateDetails, m = IO, a = Log
                                          -- execWriterT :: Monad m => WriterT w m a -> m w; w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails

updateState :: NWS NodeStateDetails
updateState = do
        nsd <- get
        let currentState = currRole nsd
            ibox = inbox nsd
        logInfo $ "Role: " ++ show currentState
        cmd <- liftstm $ readTChan ibox
        case currentState of
          -- TODO add handlers for Leader and Candidate
          Follower -> do
            logInfo $ "Received: " ++ show cmd
            liftM incTermIndex $ Follower.processCommand cmd
          Candidate -> do
            logInfo $ "Received: " ++ show cmd
            return nsd

-- TODO move this to the Follower module
--processCommand :: Command -> NWS NodeStateDetails
--processCommand cmd =
--        processCommand' >> modify incTermIndex >> get -- TODO: pretty sure the term shouldn't always increase. check the paper.
--        where
--              processCommand' = do
--                  nsd <- get
--                  case cmd of
--                      Bootup -> do
--                          tVar <- liftio newEmptyMVar
--                          liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
--                          logInfo "Waiting..."
--                          liftio $ takeMVar tVar -- wait for election timeout to expire
--                          liftio $ putStrLn "Election time expired"
--                          let ibox = inbox nsd
--                          e <- liftstm $ isEmptyTChan ibox
--                          when e $ -- nothing in our inbox, switch to candidate
--                              do
--                                  logInfo "Switching to Candidate"
--                                  liftstm $ writeTChan ibox StartCanvassing
--                                  put nsd{currRole=Candidate}
--                      _ -> logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show cmd)
