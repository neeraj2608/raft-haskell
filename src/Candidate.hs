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
        Nothing -> get >>= \nsd -> do
            --vote for self
            let newNsd = nsd{votedFor=nodeId nsd}
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
            -- one responds (or responds but it gets lost on the way)
            -- or no one else got a majority vote
            resetRandomizedElectionTimeout newNsd >>= \n -> do
            let ibox = inbox n
            empty <- liftstm $ isEmptyTChan ibox
            if empty
                then do -- nothing in our inbox, restart election
                    logInfo "Inbox empty. Restarting election..."
                    return n
                else do
                    logInfo "Something waiting in inbox"
                    return n -- process whatever is in our inbox

        Just RequestVotes{} -> get -- a candidate always votes for itself; hence nothing to do

        Just (RespondRequestVotes term voteGranted nid) -> get >>= \nsd -> do
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
                      -- we use the follList to keep track of the successful replies
                      -- and hence, if we've reached the majority. Once we have a majority,
                      -- we will overwrite the follList to include ALL the servers in
                      -- the cluster (this is done below)
                      let newNsd = nsd {followerList=(nid, 0):followerList nsd} -- update followers list. the '0' is just a filler.
                                                                                -- the actual nextIndex will be filled in if and
                                                                                -- when this node becomes a leader below
                      put newNsd
                      maj <- liftio $ hasMajority newNsd
                      if maj
                          then do -- §5.2 if yes, become leader and send out a heartbeat
                              logInfo "Received majority; updating everyone's nextIndexes + switching to Leader"
                              -- here we rewrite the follList to include ALL the servers, not just the ones we heard back from
                              m <- liftio $ atomically $ readTVar (cMap nsd)
                              let follList = map (\x -> (x, lastLogIndex nsd + 1)) $ Map.keys $ Map.filterWithKey (\n _ -> n /= nodeId nsd) m
                              put newNsd{currRole=Leader, followerList=follList}
                              get
                          else do
                              logInfo "No majority yet"
                              return newNsd -- §5.2 if no, start another timeout and wait (this will be handled by the Nothing clause)
                  else do
                      logInfo $ "Reject vote from " ++ fromJust nid
                      return nsd  -- §5.2 rejected; start another timeout and wait (this will be handled by the Nothing clause)

        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

hasMajority :: NodeStateDetails -> IO Bool
hasMajority nsd = do
    m <- atomically $ readTVar (cMap nsd)
    return (length (followerList nsd) + 1 > (length (Map.keys m) `div` 2)) -- the +1 is for the candidate itself
