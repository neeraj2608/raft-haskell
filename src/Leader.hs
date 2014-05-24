module Leader where

import Types
import Control.Monad.State
import Control.Monad.Writer
import Text.Printf
import Data.Maybe (fromJust)

processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd =
    case cmd of
        Just ClientReq -> get -- TODO: write entry to log, issue AppendEntries
                              -- TODO: wait for commit. apply to state machine. respond to client

        Just (RespondAppendEntries fId fIndex fTerm success) -> get >>= \nsd ->
            if fTerm < currTerm nsd
                then do
                  logInfo "Reverting to Follower"
                  let newNsd = nsd {currRole=Follower, currTerm=fTerm}
                  put newNsd
                  return newNsd
                else do
                    -- If AppendEntries succeeds:
                    -- update nextIndex and matchIndex for follower (§5.3) 
                    -- If AppendEntries fails because of log inconsistency:
                    -- decrement nextIndex and retry (§5.3)
                    let newIndex = if success then fIndex + 1 else fIndex - 1
                        newNsd = nsd{followerList=updateNextIndex fId newIndex $ followerList nsd}
                    put newNsd
                    return newNsd -- from here, we can either
                                  -- a. go into ClientReq if a client sent us a new request (in which
                                  --    case an AppendEntries would be sent eventually)
                                  --    In this case, regardless of success or not, this fId node
                                  --    would get sent a fresh AppendEntries extending all the way
                                  --    up to end of the leader's newly updated log (the difference
                                  --    between the failure and success scenarios being that the
                                  --    AppendEntries could either start from a decremented fIndex
                                  --    if fId had returned with a failure, or with an incremented
                                  --    fIndex if fId had returned with a success)
                                  -- b. go into Nothing (in which case an AppendEntries would be
                                  --    sent immediately).
                                  --    In this case,
                                  --      1. if fId just returned with a success, in the Nothing
                                  --      clause we'd send it a heartbeat (not an AppendEntries)
                                  --      2. if fId just returned with a failure, in the Nothing
                                  --      clause, we'd sent it a fresh AppendEntries starting with
                                  --      a decremented nextIndex
                                  --    This difference in behavior arises from the index comparison
                                  --    that we make in sendHeartbeat

        Nothing -> get >>= sendHeartbeat >>= \nsd -> do -- send off a heartbeat
            -- Start a randomized timeout
            -- Send out heartbeats on expiry (if the inbox is still empty, we'll end up in the
            -- Nothing clause again and a heartbeat will be sent)
            createBroadcastTimeout
            -- TODO: where to increment commitIndex?
            return nsd

        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

sendHeartbeat :: NodeStateDetails -> NWS NodeStateDetails
sendHeartbeat nsd = do
    lg <- execWriterT (return nsd) -- extract the current log
    mapM_ (sendHeartbeat' lg) $ followerList nsd
    return nsd
    where
          sendHeartbeat' :: Log -> (NodeId, Index) -> NWS ()
          sendHeartbeat' lg (nid, nextIndex)
              -- §5.3 If last log index ≥ nextIndex for a follower: send 
              -- AppendEntries RPC with log entries starting at nextIndex
              | lastLogIndex nsd >= nextIndex = liftio $ sendCommand (appendEntriesCmd lg nextIndex) nid (cMap nsd)
              -- else send heartbeat with [] entries (??)
              | otherwise = do
                  logInfo $ "Sending Heartbeat to " ++ fromJust nid
                  liftio $ sendCommand heartbeatCmd nid (cMap nsd)

          appendEntriesCmd :: Log -> Index -> Command
          appendEntriesCmd lg nextIndex = AppendEntries (currTerm nsd) (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd) (newerLogEntries lg nextIndex) (commitIndex nsd)

          newerLogEntries :: Log -> Index -> Log
          newerLogEntries lg nextIndex = dropWhile (\((lgIndex,_),_) -> lgIndex < nextIndex) lg

          heartbeatCmd :: Command
          heartbeatCmd = AppendEntries (currTerm nsd) (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd) [] (commitIndex nsd)

updateNextIndex :: NodeId -> Index -> [(NodeId, Index)] -> [(NodeId, Index)]
updateNextIndex nid newIndex = fmap (\(nId, oldIndex) -> if nId == nid then (nId,newIndex) else (nId, oldIndex))
