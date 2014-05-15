module Follower where

import Types

handleCommand :: Command -> NState -> NState
handleCommand cmd state = case cmd of
  Bootup -> undefined
    -- start timeout and wait for an AppendEntries RPC or a RequestVote RPC
  _ -> undefined