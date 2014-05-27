module Follower where

import Types
import Control.Monad.State
import Control.Concurrent.STM
import Text.Printf
import Data.Maybe (fromJust, isJust)

processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd =
    case cmd of
        --start election timeout
        Nothing -> get >>= \nsd -> do
            createElectionTimeout
            let ibox = inbox nsd
            empty <- liftstm $ isEmptyTChan ibox
            if empty -- nothing in our inbox, switch to candidate
                then do
                    logInfo "Nothing waiting in inbox"
                    logInfo "Incrementing term, Switching to Candidate"
                    liftstm $ writeTChan ibox StartCanvassing
                    let newNsd = nsd{currRole=Candidate, currTerm=currTerm nsd+1}
                    put newNsd
                    return newNsd
                else do
                    logInfo "Something waiting in inbox"
                    return nsd

        Just (RequestVotes cTerm cid logState) ->
            get >>= \nsd -> do
                logInfo $ "Received: " ++ show (fromJust cmd)
                if cTerm > currTerm nsd
                    then do
                        let newNsd = nsd{votedFor=Nothing, currTerm=cTerm} -- vote for a fresh term we haven't seen before
                        put newNsd
                        castBallot newNsd
                    else castBallot nsd -- vote for the current term
                where castBallot :: NodeStateDetails -> NWS NodeStateDetails
                      castBallot n | isJust (votedFor n) && votedFor n /= cid = do
                                         logInfo $ "Reject vote: already voted for " ++ fromJust (votedFor n)
                                         rejectCandidate cid n
                                   | otherwise =
                                         if isMoreUpToDate n logState
                                            then do
                                                logInfo $ "Reject vote for " ++ fromJust cid ++ " with currTerm " ++ show cTerm
                                                rejectCandidate cid n
                                            else do -- §5.2 we're less up to date than the candidate that requested a vote
                                                    -- accept the RequestVote
                                                logInfo $ "Cast vote for " ++ fromJust cid ++ " with currTerm " ++ show cTerm
                                                liftio $ sendCommand (RespondRequestVotes (currTerm n) True (nodeId n)) cid (cMap n)
                                                let newNsd = n{votedFor=cid} -- update votedFor
                                                put newNsd
                                                return newNsd

        Just (AppendEntries lTerm lId prevlogindexterm lEntries lCommitIndex) -> get >>= \nsd -> do
            if lTerm < currTerm nsd
                then do
                    logInfo $ "Reject stale AppendEntries from " ++ (fromJust lId)
                    liftio $ sendCommand (RespondAppendEntries (currTerm nsd) (nodeId nsd) (lastLogIndex nsd) False) lId (cMap nsd)
                    return nsd
            else
                if null lEntries -- heartbeat
                    then do
                        logInfo $ "Received heartbeat from " ++ (fromJust lId)
                        let newNsd = nsd{currLeaderId = lId} -- update leader Id
                        put newNsd
                        return newNsd
                else -- normal append entries
                    if (null $ nodeLog nsd) || previousEntriesMatch prevlogindexterm nsd
                        -- If your log is empty or you have a match on the previous log index and term sent
                        -- by the leader, accept the entries
                        then do
                            writeToLog' lEntries nsd >>= \n -> do
                            logInfo $ "Accept AppendEntries from " ++ (fromJust lId)
                            liftio $ sendCommand (RespondAppendEntries (currTerm n) (nodeId n) (lastLogIndex n) True) lId (cMap n)
                            return n
                        else do
                            -- a. Remove your most recent log entry (we do this right now to avoid having to
                            -- check for conflicts (same index, diff terms)) later on. See c for an explanation.
                            -- b. Next, reject the append entries rpc.
                            -- c. The leader will decrement next index and try another append entries. When
                            -- the prevLog* finally matches, all we have to do is to append the entries the
                            -- leader sent us. This is only possible because we removed our log entries in a.
                            -- as we rejected append entries rpcs.
                            -- As an aside, note that such a destructive update to its own log must never be
                            -- carried out by a leader (we're a Follower here, so it's okay). This is called
                            -- the Leader Append-Only property
                            -- TODO: This can cause a potential problem with the Writer. How do we roll back
                            --       writer entries??
                            let newNsd = nsd{nodeLog=tail $ nodeLog nsd}
                            put newNsd
                            return newNsd

        Just (ClientReq _) -> get >>= \nsd -> do
          case currLeaderId nsd of
              Nothing -> return nsd --TODO: what should happen in this case??
              maybeLeaderId -> do
                  logInfo $ "Forwarding client request to " ++ (fromJust maybeLeaderId)
                  liftio $ sendCommand (fromJust cmd) maybeLeaderId (cMap nsd)
                  return nsd

        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

-- | Decides if the node with the state passed in (first arg) is more
-- up to date than the node with the log state passed in (second arg)
-- §5.4.1 Up-to-dateness is determined using the following two rules:
-- a. the log with the larger term in its last entry is more up to date
-- b. if both logs have the same number of entries, the longer log (i,e., larger index) is more up to date
isMoreUpToDate :: NodeStateDetails -> LogState -> Bool
isMoreUpToDate nsd logState | null $ nodeLog nsd = False
                            | lastLogTerm nsd > snd logState = True
                            | lastLogTerm nsd < snd logState = False
                            | otherwise = case compare (lastLogIndex nsd) (fst logState) of
                                              GT -> True
                                              _ -> False

-- | Returns True if we can find a match in our log that has the same Log coordinates as
--   the previous Logstate passed in by the leader
previousEntriesMatch :: LogState -> NodeStateDetails -> Bool
previousEntriesMatch (prevIdx, prevTerm) nsd = foldr f False (fst `fmap` nodeLog nsd)
    where f :: LogState -> Bool -> Bool
          f (idx, term) r | r = r
                          | idx == prevIdx && term==prevTerm = True
                          | otherwise = False

rejectCandidate :: NodeId -> NodeStateDetails -> NWS NodeStateDetails
rejectCandidate cid n = do -- §5.2 we're more up to date than the candidate that requested a vote
                           -- reject the RequestVote
    liftio $ sendCommand (RespondRequestVotes (currTerm n) False (nodeId n)) cid (cMap n)
    return n

