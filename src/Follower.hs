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
        processCommand' >>= incTermIndex -- TODO: pretty sure the term shouldn't always increase. check the paper.
        where
            processCommand' :: NWS NodeStateDetails
            processCommand' = do
                nsd <- get
                case cmd of
                    --start election timeout
                    Nothing -> do
                        tVar <- liftio newEmptyMVar
                        liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
                        now <- liftio getClockTime
                        logInfo $ "Waiting... " ++ show now
                        liftio $ takeMVar tVar -- wait for election timeout to expire
                        now <- liftio getClockTime
                        logInfo $ printf "Election time expired " ++ show now
                        let ibox = inbox nsd
                        e <- liftstm $ isEmptyTChan ibox
                        if e -- nothing in our inbox, switch to candidate
                            then do
                                logInfo "Nothing waiting in inbox"
                                logInfo "Switching to Candidate"
                                liftstm $ writeTChan ibox StartCanvassing
                                let newNsd = nsd{currRole=Candidate}
                                return newNsd
                            else do
                                logInfo "Something waiting in inbox"
                                return nsd
                    -- TODO: Add valid commands here
                    --       e.g. RequestVoteRPC
                    Just _ -> do
                        logInfo $ "Received: " ++ (show $ fromJust cmd)
                        logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
                        return nsd
