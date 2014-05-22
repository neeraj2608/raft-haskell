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

        Just (RespondAppendEntries fTerm success) -> get -- TODO: If successful: update nextIndex and matchIndex for 
                                                         -- follower (§5.3) 
                                                         -- If AppendEntries fails because of log inconsistency:
                                                         -- decrement nextIndex and retry (§5.3)

        Nothing -> get >>= sendHeartbeat >>= \nsd -> do -- send off a heartbeat. Do it at once if we've
                                                        -- just become a leader. If we're already a
                                                        -- leader, this will be invoked after a heartbeat
                                                        -- timeout (see below)
            -- Start a randomized timeout
            -- Send out heartbeats on expiry
            createBroadcastTimeout
            return nsd -- if the inbox is still empty, we'll end up in the
                       -- Nothing clause again and a heartbeat WILL be sent

        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

sendHeartbeat :: NodeStateDetails -> NWS NodeStateDetails
sendHeartbeat nsd = do
    logInfo "Sending AppendEntries Heartbeat RPC"
    lg <- execWriterT (return nsd) -- extract the current log
    mapM_ (sendHeartbeat' lg) $ followerList nsd
    return nsd
    where
          sendHeartbeat' :: Log -> (NodeId, Index) -> NWS ()
          sendHeartbeat' lg (nid, nextIndex)
              -- §5.3 If last log index ≥ nextIndex for a follower: send 
              -- AppendEntries RPC with log entries starting at nextIndex
              | (lastLogIndex nsd) >= nextIndex = liftio $ sendCommand (appendEntriesCmd lg nextIndex) nid (cMap nsd)
              -- else send heartbeat with [] entries (??)
              | otherwise = liftio $ sendCommand heartbeatCmd nid (cMap nsd)

          appendEntriesCmd :: Log -> Index -> Command
          appendEntriesCmd lg nextIndex = AppendEntries (currTerm nsd) (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd) (newerLogEntries lg nextIndex) (commitIndex nsd)

          newerLogEntries :: Log -> Index -> Log
          newerLogEntries lg nextIndex = dropWhile (\((lgIndex,_),_) -> lgIndex < nextIndex) lg

          heartbeatCmd :: Command
          heartbeatCmd = AppendEntries (currTerm nsd) (nodeId nsd) (lastLogIndex nsd, lastLogTerm nsd) [] (commitIndex nsd)
