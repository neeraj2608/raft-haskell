module Candidate where

import Types
import Control.Monad.State
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import Text.Printf
import System.Time
import Data.Maybe (fromJust)

processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd = do
    case cmd of
        Just StartCanvassing -> do
            get >>= \nsd -> do
                logInfo $ "Role: " ++ (show $ currRole nsd)
                logInfo "Vote for self"
                --vote for self
                let newNsd = nsd{votedFor=(nodeId nsd)}
                put newNsd
                --broadcast requestvote rpc
                logInfo "Broadcasting RequestVote RPC"
                liftio $ broadCastExceptSelf -- exclude self from the broadcast
                    (RequestVotes (currTerm nsd) (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd)) -- include log index and current term
                    (cMap nsd)
                    (nodeId nsd)
                -- Start a randomized timeout
                -- if at the end of that time, we have not received any
                -- responses or we have not received a clear majoity,
                -- restart the election. Note that if someone else had
                -- received a majority, they would have sent us an
                -- AppendEntries RPC and our inbox wouldn't be empty. The
                -- only case in which our inbox can be empty is either no
                -- one responds or no one else got a majority vote
                tVar <- liftio newEmptyMVar
                liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
                startTime <- liftio getClockTime
                logInfo $ "Waiting... " ++ show startTime
                liftio $ takeMVar tVar -- wait for election timeout to expire
                endTime <- liftio getClockTime
                logInfo $ printf "Election time expired " ++ show endTime
                let ibox = inbox nsd
                empty <- liftstm $ isEmptyTChan ibox
                if empty
                    then do -- nothing in our inbox, restart election
                        logInfo $ "Inbox empty. Restarting election..."
                        liftstm $ writeTChan ibox StartCanvassing
                        return newNsd
                    else do
                        logInfo "Something waiting in inbox"
                        return newNsd -- process whatever is in our inbox
        Just (RequestVotes _ _ _) -> get >>= return -- a candidate always votes for itself; hence nothing to do
        Just (RespondRequestVotes term voteGranted) -> get >>= \nsd -> do
           if (currTerm nsd < term) -- we're out of date, revert to Follower
              then do
                  let newNsd = nsd {currRole=Follower, currTerm=term}
                  put newNsd
                  return newNsd
              else undefined -- TODO: see if we have majority yet.
                             --       if no, keep waiting (this will be
                             --       handled by the Nothing clause)
                             --       if yes, become leader and send out a heartbeat
        Just (AppendEntries lTerm _ _ _ _) -> get >>= \nsd -> do
           if (currTerm nsd < lTerm) -- there's another leader ahead of us, revert to Follower
              then do
                  let newNsd = nsd {currRole=Follower, currTerm=lTerm}
                  put newNsd
                  return newNsd
              else undefined -- TODO
        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd
        Nothing -> get >>= return
