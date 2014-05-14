module Persistence where

{-
  This module implements persistence for nodes. It allows nodes to write
  out their persistent data to disk (this must be done BEFORE responding
  to an RPC).
  Persistent data includes:
  currentTerm   latest term server has seen (initialized to 0 
                on first boot, increases monotonically)
  votedFor      candidateId that received vote in current 
                term (or null if none)
  log[]         log entries; each entry contains command 
                for state machine, and term when entry 
                was received by leader (first index is 1)
  
-}