module Node where

{-
  Generalized Raft node.

  Followers need to keep track of the leader so e.g. they
  can forward requests erroneously sent to them by clients
-}

import Candidate
import Control.Monad.State
import Control.Monad.Writer
import Control.Concurrent.STM
import Data.Maybe (fromJust)
import Follower
import Leader
import System.IO
import Text.Printf
import Types

startInboxListener :: NodeStateDetails -> Handle -> IO ()
startInboxListener nsd logFileHandle = do
    (lg,newNsd) <- run nsd
    hPutStr logFileHandle $ unlines $ map show lg -- write out the node log to a file
    startInboxListener newNsd logFileHandle -- feed the updated state back in to run

run :: NodeStateDetails -> IO (Log, NodeStateDetails)
run = runStateT (execWriterT updateState) -- runStateT :: StateT s m a -> s -> m (a, s); s = NodeStateDetails, m = IO, a = Log
                                          -- execWriterT :: Monad m => WriterT w m a -> m w; w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails

updateState :: NWS NodeStateDetails
updateState = do
    nsd <- get
    let currentRole = currRole nsd
        ibox = inbox nsd
    cmd <- liftstm $ tryReadTChan ibox
    case currentRole of
      Follower -> Follower.processCommand cmd
      _ -> possiblyRevertToFollower cmd

-- | This function either:
--   a. Reverts a node to follower state if it receives an RPC with a term larger than
--      its current term (signifying that it is out of date). The node also updates its
--      current term to the larger value.
--   OR
--   b. If the term of the received RPC is smaller than the node's current term, then
--      the node continues to process the command
--      Two additional things may need to happen:
--      1. If the RPC was an AppendEntries, it must be rejected so the out of date leader
--         that sent it can revert itself to a follower
--      2. If the RPC was a RequestVotes, it must be rejected so the out of date candidate
--         that sent it can revert itself to a follower
possiblyRevertToFollower :: Maybe Command -> NWS NodeStateDetails
possiblyRevertToFollower cmd = do
    nsd <- get
    newNsd <- case cmd of
        Just (RequestVotes term nid _) -> revertToFollowerOrContinueInSameState nid term nsd cmd
        Just (RespondRequestVotes term _ nid) -> revertToFollowerOrContinueInSameState nid term nsd cmd
        Just (AppendEntries term nid _ _ _) -> revertToFollowerOrContinueInSameState nid term nsd cmd
        Just (RespondAppendEntries term nid _ _) -> revertToFollowerOrContinueInSameState nid term nsd cmd
        _ -> return nsd
    case currRole newNsd of
        Follower -> Follower.processCommand cmd
        Leader -> Leader.processCommand cmd
        Candidate -> Candidate.processCommand cmd

revertToFollowerOrContinueInSameState :: NodeId -> Term -> NodeStateDetails -> Maybe Command -> NWS NodeStateDetails
revertToFollowerOrContinueInSameState sId sTerm nsd cmd =
    if currTerm nsd < sTerm -- §5.2 there's another leader ahead of us, revert to Follower
        then do
            logInfo $ "Another leader " ++ fromJust sId ++ " found. Reverting to follower"
            let newNsd = nsd {currRole=Follower, currTerm=sTerm}
            put newNsd
            -- note that here we do not respond to the leader. This means that this AppendEntries RPC is effectively lost.
            -- That is not a problem, however, as the leader will keep sending AppendEntries until it hears back from all
            -- its followers.
            return newNsd
        else do
            -- §5.1 we're ahead of the other guy. reject stale RPC and continue in same state
            -- note that here we do actually send a response back so the "leader" can update its current term and revert
            -- to a follower
            case cmd of
                Just (RequestVotes _ _ _) -> do
                    logInfo $ printf "Received stale %s RPC from %s. Reject and continue as %s" (show $ fromJust cmd) (fromJust sId) $ show (currRole nsd)
                    rejectCandidate sId nsd
                Just (AppendEntries _ _ _ _ _) -> do
                    logInfo $ printf "Received stale %s RPC from %s. Reject and continue as %s" (show $ fromJust cmd) (fromJust sId) $ show (currRole nsd)
                    liftio $ sendCommand (RespondAppendEntries (currTerm nsd) (nodeId nsd) (lastLogIndex nsd) False) sId (cMap nsd) >> return nsd
                _ -> return nsd
