module Leader where

import Types
import Control.Monad.State
import Control.Concurrent.STM
import Text.Printf
import Data.Maybe (fromJust)

processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd =
    case cmd of
        Just AppendEntries{} -> get >>= \nsd -> do
            -- TODO: init nextIndex for each follower to lastLogIndex + 1
            --broadcast requestvote rpc
            logInfo "Broadcasting AppendEntries Heartbeat RPC"
            liftio $ broadCastExceptSelf -- exclude self from the broadcast
                (fromJust cmd)
                (cMap nsd)
                (nodeId nsd)
            return nsd -- jump into the Nothing clause and start the broadcast timeout

        Just ClientReq -> get -- TODO: write entry to log, issue AppendEntries

        Just _ -> get >>= \nsd -> do
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

        Nothing -> get >>= \nsd -> do
                -- Start a randomized timeout
                -- Send out heartbeats in idle durations (idle == no client
                -- req)
                createBroadcastTimeout
                let ibox = inbox nsd
                empty <- liftstm $ isEmptyTChan ibox
                if empty
                    then do -- nothing in our inbox, restart election
                        logInfo "Inbox empty. Sending a heartbeat..."
                        writeHeartbeat nsd
                        return nsd
                    else do
                        logInfo "Something waiting in inbox"
                        return nsd -- process whatever is in our inbox
