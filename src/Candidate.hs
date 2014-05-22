module Candidate where

import Types
import Control.Monad.State
import Control.Concurrent.STM
import Text.Printf
import Data.Maybe (fromJust)
import qualified Data.Map as Map

processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd =
    case cmd of
        Just StartCanvassing ->
            get >>= \nsd -> do
                logInfo $ "Role: " ++ show (currRole nsd)
                logInfo $ "Received: " ++ show (fromJust cmd)
                logInfo "Vote for self"
                --vote for self
                let newNsd = nsd{votedFor=nodeId nsd}
                put newNsd
                --broadcast requestvote rpc
                logInfo "Broadcasting RequestVote RPC"
                liftio $ broadCastExceptSelf -- exclude self from the broadcast
                    (RequestVotes (currTerm nsd) (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd)) -- include log index and current term
                    (cMap nsd)
                    (nodeId nsd)
                return newNsd -- jump into the Nothing clause and start the timeout
        Just RequestVotes{} -> get -- a candidate always votes for itself; hence nothing to do
        Just (RespondRequestVotes term voteGranted nid) -> get >>= \nsd -> do
           logInfo $ "Role: " ++ show (currRole nsd)
           logInfo $ "Received: " ++ show (fromJust cmd)
           if currTerm nsd < term
              then do -- we're out of date, revert to Follower
                  logInfo "Reverting to Follower"
                  let newNsd = nsd {currRole=Follower, currTerm=term}
                  put newNsd
                  return newNsd
              else if voteGranted
                  then do
                      logInfo $ "Got vote from " ++ fromJust nid
                      let newNsd = nsd {followerList=nid:followerList nsd} -- update followers list
                      put newNsd
                      maj <- liftio $ hasMajority newNsd
                      if maj
                          then do -- if yes, become leader and send out a heartbeat
                              writeHeartbeat newNsd
                              logInfo "Received majority; switching to Leader"
                              put newNsd{currRole=Leader}
                              get
                          else do
                              logInfo "No majority yet"
                              return newNsd -- if no, start another timeout and wait (this will be handled by the Nothing clause)
                  else do
                      logInfo $ "Reject vote from " ++ fromJust nid
                      return nsd  -- rejected; start another timeout and wait (this will be handled by the Nothing clause)
        Just (AppendEntries lTerm lId _ _ _) -> get >>= \nsd ->
           if currTerm nsd < lTerm -- there's another leader ahead of us, revert to Follower
              then do
                  logInfo $ "Another leader " ++ fromJust lId ++ " found"
                  let newNsd = nsd {currRole=Follower, currTerm=lTerm}
                  put newNsd
                  return newNsd
              else undefined -- TODO
        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd
        Nothing -> get >>= \nsd -> do
                -- Start a randomized timeout
                -- if at the end of that time, we have not received any
                -- responses or we have not received a clear majoity,
                -- restart the election. Note that if someone else had
                -- received a majority, they would have sent us an
                -- AppendEntries RPC and our inbox wouldn't be empty. The
                -- only case in which our inbox can be empty is either no
                -- one responds (or responds but it gets lost on the way)
                -- or no one else got a majority vote
                createElectionTimeout
                let ibox = inbox nsd
                empty <- liftstm $ isEmptyTChan ibox
                if empty
                    then do -- nothing in our inbox, restart election
                        logInfo "Inbox empty. Restarting election..."
                        liftstm $ writeTChan ibox StartCanvassing
                        return nsd
                    else do
                        logInfo "Something waiting in inbox"
                        return nsd -- process whatever is in our inbox

hasMajority :: NodeStateDetails -> IO Bool
hasMajority nsd = do
        m <- atomically $ readTVar (cMap nsd)
        return (length (followerList nsd) + 1 > (length (Map.keys m) `div` 2)) -- the +1 is for the candidate itself
