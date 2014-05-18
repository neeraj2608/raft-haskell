module Follower where

import Types
import Control.Monad.State
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import Text.Printf

processCommand :: Command -> NWS NodeStateDetails
processCommand cmd =
        processCommand' >> modify incTermIndex >> get -- TODO: pretty sure the term shouldn't always increase. check the paper.
        where
              processCommand' = do
                  nsd <- get
                  case cmd of
                      Bootup -> do
                          tVar <- liftio newEmptyMVar
                          liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
                          logInfo "Waiting..."
                          liftio $ takeMVar tVar -- wait for election timeout to expire
                          liftio $ putStrLn "Election time expired"
                          let ibox = inbox nsd
                          e <- liftstm $ isEmptyTChan ibox
                          when e $ -- nothing in our inbox, switch to candidate
                              do
                                  logInfo "Switching to Candidate"
                                  liftstm $ writeTChan ibox StartCanvassing
                                  put nsd{currRole=Candidate}
                      _ -> logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show cmd)
