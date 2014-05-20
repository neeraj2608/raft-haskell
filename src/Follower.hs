module Follower where

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
                    --start election timeout
                    Nothing -> get >>= \nsd -> do
                        logInfo $ "Role: " ++ (show $ currRole nsd)
                        tVar <- liftio newEmptyMVar
                        liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
                        startTime <- liftio getClockTime
                        logInfo $ "Waiting... " ++ show startTime
                        liftio $ takeMVar tVar -- wait for election timeout to expire
                        endTime <- liftio getClockTime
                        logInfo $ printf "Election time expired " ++ show endTime
                        let ibox = inbox nsd
                        e <- liftstm $ isEmptyTChan ibox
                        if e -- nothing in our inbox, switch to candidate
                            then do
                                logInfo "Nothing waiting in inbox"
                                logInfo "Switching to Candidate"
                                liftstm $ writeTChan ibox StartCanvassing
                                let newNsd = nsd{currRole=Candidate}
                                put newNsd
                                return newNsd
                            else do
                                logInfo "Something waiting in inbox"
                                return nsd
                    Just (RequestVotes nid logState) -> do
                        get >>= \nsd -> do
                            logInfo $ "Role: " ++ (show $ currRole nsd)
                            logInfo $ "Received: " ++ (show $ fromJust cmd)
                            if isMoreUpToDate nsd logState
                                then do -- we're more up to date than the candidate that requested a vote
                                        -- reject the RequestVote
                                    logInfo $ "Reject vote: we're more up to date than " ++ fromJust nid
                                    liftio $ sendCommand RejectVote nid (cMap nsd)
                                    return nsd
                                else do -- we're less up to date than the candidate that requested a vote
                                        -- accept the RequestVote
                                    logInfo $ "Accept vote : we're less up to date than " ++ fromJust nid
                                    liftio $ sendCommand GiveVote nid (cMap nsd)
                                    let newNsd = nsd{votedFor=nid} -- update votedFor
                                    put newNsd
                                    return newNsd
                    Just _ -> get >>= \nsd -> do
                        logInfo $ "Role: " ++ (show $ currRole nsd)
                        logInfo $ "Received: " ++ (show $ fromJust cmd)
                        logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
                        return nsd

-- | Decides if the node with the state passed in (first arg) is more
-- up to date than the node with the log state passed in (second arg)
-- 5.4.1 Up-to-dateness is determined using the following two rules:
-- a. the log with the larger term in its last entry is more up to date
-- b. if both logs have the same number of entries, the longer log (i,e., larger index) is more up to date
isMoreUpToDate :: NodeStateDetails -> LogState -> Bool
isMoreUpToDate nsd logState | (lastLogTerm nsd > snd logState) = True
                            | (lastLogTerm nsd < snd logState) = False
                            | otherwise = case (compare (lastLogIndex nsd) (fst logState)) of
                                              GT -> True
                                              _ -> False

