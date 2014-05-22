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
            logInfo $ "Role: " ++ show (currRole nsd)
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
                logInfo $ "Role: " ++ show (currRole nsd)
                logInfo $ "Received: " ++ show (fromJust cmd)
                if cTerm < currTerm nsd
                    then do -- our current term is more than the candidate's
                            -- reject the RequestVote
                        logInfo $ "Reject vote: our currTerm " ++ show (currTerm nsd) ++ "> " ++ fromJust cid ++ "'s currTerm" ++ show cTerm
                        liftio $ sendCommand (RespondRequestVotes (currTerm nsd) False (nodeId nsd)) cid (cMap nsd)
                        return nsd
                    else
                        if cTerm > currTerm nsd
                            then do
                                let newNsd = nsd{votedFor=Nothing, currTerm=cTerm} -- vote for a fresh term we haven't seen before
                                put newNsd
                                castBallot newNsd
                            else castBallot nsd -- vote for the current term
                        where castBallot :: NodeStateDetails -> NWS NodeStateDetails
                              castBallot n | isJust (votedFor n) && votedFor n /= cid = do
                                                 logInfo $ "Reject vote: already voted for " ++ fromJust (votedFor n)
                                                 rejectCandidate n
                                           | otherwise =
                                                 if isMoreUpToDate n logState
                                                    then do
                                                        logInfo $ "Reject vote: our currTerm " ++ show (currTerm n) ++ " > "
                                                                  ++ fromJust cid ++ "'s currTerm " ++ show cTerm
                                                        rejectCandidate n
                                                    else do -- we're less up to date than the candidate that requested a vote
                                                            -- accept the RequestVote
                                                        logInfo $ "Accept vote: our currTerm " ++ show (currTerm n)
                                                                  ++ " <= " ++ fromJust cid ++ "'s currTerm " ++ show cTerm
                                                        liftio $ sendCommand (RespondRequestVotes (currTerm n) True (nodeId n)) cid (cMap n)
                                                        let newNsd = n{votedFor=cid} -- update votedFor
                                                        put newNsd
                                                        return newNsd

                              rejectCandidate :: NodeStateDetails -> NWS NodeStateDetails
                              rejectCandidate n = do -- we're more up to date than the candidate that requested a vote
                                                    -- reject the RequestVote
                                         liftio $ sendCommand (RespondRequestVotes (currTerm n) False (nodeId n)) cid (cMap n)
                                         return n

        Just (AppendEntries lTerm lId (prevLogIndex, prevLogTerm) lEntries lCommitIndex)
            | null lEntries -> get >>= \nsd -> do
                logInfo $ "Received heartbeat from " ++ (fromJust lId)
                let newNsd = nsd{currLeaderId = lId} -- update leader Id
                put newNsd
                return newNsd
            | otherwise -> get >>= \nsd -> do
                if lTerm < currTerm nsd
                    then do
                        logInfo $ "Reject stale AppendEntries from " ++ (fromJust lId)
                        liftio $ sendCommand (RespondAppendEntries (currTerm nsd) False) lId (cMap nsd)
                        return nsd
                    else return nsd --TODO: log consistency check

        Just ClientReq -> get >>= \nsd -> do
          case currLeaderId nsd of
              Nothing -> return nsd
              maybeLeaderId -> do
                  logInfo $ "Forwarding client request to " ++ (fromJust maybeLeaderId)
                  liftio $ sendCommand (RespondAppendEntries (currTerm nsd) False) maybeLeaderId (cMap nsd)
                  return nsd

        Just _ -> get >>= \nsd -> do
            logInfo $ "Role: " ++ show (currRole nsd)
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

-- | Decides if the node with the state passed in (first arg) is more
-- up to date than the node with the log state passed in (second arg)
-- 5.4.1 Up-to-dateness is determined using the following two rules:
-- a. the log with the larger term in its last entry is more up to date
-- b. if both logs have the same number of entries, the longer log (i,e., larger index) is more up to date
isMoreUpToDate :: NodeStateDetails -> LogState -> Bool
isMoreUpToDate nsd logState | lastLogTerm nsd > snd logState = True
                            | lastLogTerm nsd < snd logState = False
                            | otherwise = case compare (lastLogIndex nsd) (fst logState) of
                                              GT -> True
                                              _ -> False
