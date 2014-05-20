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
import Control.Concurrent.STM
import Follower
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Text.Printf
import System.Time
import Data.Maybe (fromJust)

startInboxListener :: NodeStateDetails -> IO ()
startInboxListener nsd = do
    (lg,newNsd) <- run nsd
    putStr $ unlines $ map show lg
    startInboxListener newNsd --feed the updated state back in to run

run :: NodeStateDetails -> IO (Log, NodeStateDetails)
run = runStateT (execWriterT updateState) -- runWriterT :: WriterT w m a -> m (a, w); w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails
                                          -- runStateT :: StateT s m a -> s -> m (a, s); s = NodeStateDetails, m = IO, a = Log
                                          -- execWriterT :: Monad m => WriterT w m a -> m w; w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails

updateState :: NWS NodeStateDetails
updateState = do
        nsd <- get
        let currentRole = currRole nsd
            ibox = inbox nsd
        cmd <- liftstm $ tryReadTChan ibox
        case currentRole of
          -- TODO add handlers for Leader and Candidate
          Follower -> do
            Follower.processCommand cmd
          Candidate -> do
            --logInfo $ "Received: " ++ show cmd
            Node.processCommand cmd
            return nsd
          Leader -> do
            --logInfo $ "Received: " ++ show cmd
            return nsd

-- TODO: move this to the Candidate module
processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd = do
    case cmd of
        Just StartCanvassing -> do
            get >>= incTerm >>= \nsd -> do --increment current term
                logInfo $ "Role: " ++ (show $ currRole nsd)
                logInfo "Increment current term"
                logInfo "Vote for self"
                --vote for self
                let newNsd = nsd{votedFor=(nodeId nsd)}
                --broadcast requestvote rpc
                logInfo "Broadcasting RequestVote RPC"
                liftio $ broadCastExceptSelf -- exclude self from the broadcast
                    (RequestVotes (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd)) -- include log index and current term
                    (cMap nsd)
                    (nodeId nsd)
                return newNsd
        Just (RequestVotes _ _) -> get >>= return -- a candidate always votes for itself; hence nothing to do
        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd
        Nothing -> get >>= return
