module Node where

{-
  Generalized Raft node.
  This models all the state transitions and functionality
  of a node.
  
  Leader needs to keep track of its followers (this list can
  be initialized when the leader was still a candidate) so it knows
  how many followers it has. This way, it can decide when
  a "majority" has responded. Leader also must keep track
  of the nextIndex and matchIndex for each of its followers.
  
  Followers need to keep track of the leader so e.g. they
  can forward requests erroneously sent to them by clients
-}

import Types
import Control.Monad.State
import Control.Monad.Writer
import Data.Map as Map

initStateMap :: [Node] -> StateMap
initStateMap nodeList = Prelude.foldr (\node map -> Map.insert node Follower map) Map.empty nodeList

main :: IO ()
main = sendCmd (Node "b") (initStateMap nodeList) Bootup
  where nodeList = [Node "a", Node "b", Node "c"]

sendCmd :: Node -> StateMap -> Command -> IO ()
sendCmd node stateMap cmd = case (Map.lookup node stateMap) of -- look up node's state and call updateState
  Just state -> do
    let newState = updateState cmd state
    print newState
  Nothing -> error "No state found"

updateState :: Command -> NState -> NState
updateState cmd startState = do
  execState (runWriterT (test cmd)) startState

test :: Command -> WriterT Log (State NState) Command
test cmd = do
  curState <- get
  case curState of
    Leader -> do
      handleLeaderCommand cmd curState
    Follower -> do
      handleFollowerCommand cmd curState
    Candidate -> do
      handleCandidateCommand cmd curState

handleFollowerCommand :: Command -> NState -> WriterT Log (State NState) Command
handleFollowerCommand cmd state = case cmd of
  Bootup -> do
    tell [((1, 1), (show cmd))]
    put Leader
    return cmd
  _ -> undefined

handleCandidateCommand :: Command -> NState -> WriterT Log (State NState) Command
handleCandidateCommand cmd state = case cmd of
  -- TODO
  _ -> undefined

handleLeaderCommand :: Command -> NState -> WriterT Log (State NState) Command
handleLeaderCommand cmd state = case cmd of
  -- TODO
  _ -> undefined