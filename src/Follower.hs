module Follower where

import Types
import Control.Monad.State
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import Text.Printf
import System.Time

processCommand :: Command -> NWS NodeStateDetails
processCommand cmd = do
        processCommand' >>= incTermIndex -- TODO: pretty sure the term shouldn't always increase. check the paper.
        where
            processCommand' :: NWS NodeStateDetails
            processCommand' = do
                nsd <- get
                case cmd of
                    Bootup -> do
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
                                logInfo "Switching to Candidate"
                                liftstm $ writeTChan ibox StartCanvassing
                                let newNsd = nsd{currRole=Candidate}
                                return newNsd
                            else return nsd
                    _ -> do
                        logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show cmd)
                        return nsd
