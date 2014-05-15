module Leader where

import Types

handleCommand :: Command -> NState -> NState
handleCommand cmd state = case cmd of
  _ -> undefined