module Leader where

import Control.Applicative ((<$>))
import Control.Monad.State
import Data.Maybe (fromJust)
import Text.Printf
import Types

processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd =
    case cmd of
        Just (ClientReq clientData) -> get >>=
            writeToLog clientData >>= \_ -> do
            logInfo $ "Received " ++ clientData ++ " from client"
            get
            -- TODO: wait for commit. apply to state machine. respond to client

        Just (RespondAppendEntries fTerm fId fIndex success) -> get >>= \nsd ->
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
                                  --    that we make in sendHeartbeatOrAppendEntries

        Nothing -> get >>= sendHeartbeatOrAppendEntries >>= \nsd -> do -- send off a heartbeat
            -- Start a timeout
            -- Send out heartbeats on expiry (if the inbox is still empty, we'll end up in the
            -- Nothing clause again and a heartbeat will be sent)
            createBroadcastTimeout
            return nsd
            -- TODO: where to increment commitIndex?

        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

sendHeartbeatOrAppendEntries :: NodeStateDetails -> NWS NodeStateDetails
sendHeartbeatOrAppendEntries nsd = do
    let lg = nodeLog nsd -- extract the current log
    logInfo $ "follower list: " ++ show (fst <$> followerList nsd)
    mapM_ (sendHeartbeatOrAppendEntries' lg) $ followerList nsd
    return nsd
    where
        sendHeartbeatOrAppendEntries' :: Log -> (NodeId, Index) -> NWS ()
        sendHeartbeatOrAppendEntries' lg (nid, nextIndex)
            -- §5.3 If last log index ≥ nextIndex for a follower: send
            -- AppendEntries RPC with log entries starting at nextIndex
            | lastLogIndex nsd >= nextIndex = do
                logInfo $ printf "my last index = %s, %s's next index = %s" (show $ lastLogIndex nsd) (fromJust nid) (show nextIndex)
                logInfo $ printf "Sending AppendEntries to %s" $ fromJust nid
                liftio $ sendCommand (createAppendEntries lg nextIndex) nid (cMap nsd)
            -- else send heartbeat with [] entries (??)
            | otherwise = do
                logInfo $ "Sending Heartbeat to " ++ fromJust nid
                liftio $ sendCommand createHeartbeat nid (cMap nsd)

        createAppendEntries :: Log -> Index -> Command
        createAppendEntries lg nextIndex = AppendEntries (currTerm nsd) (nodeId nsd) (prevLogIndexTerm nsd) (collectNewerLogEntries lg nextIndex) (commitIndex nsd)

        collectNewerLogEntries :: Log -> Index -> Log
        collectNewerLogEntries lg nextIndex = takeWhile (\((lgIndex,_),_) -> lgIndex >= nextIndex) lg

        createHeartbeat :: Command
        createHeartbeat = AppendEntries (currTerm nsd) (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd) [] (commitIndex nsd)

updateNextIndex :: NodeId -> Index -> [(NodeId, Index)] -> [(NodeId, Index)]
updateNextIndex nid newIndex = fmap (\(nId, oldIndex) -> if nId == nid then (nId,newIndex) else (nId, oldIndex))
