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
import qualified Data.Map as Map
import Follower
import Candidate
import Leader

initStateMap :: [Node] -> StateMap
initStateMap = foldr (\node map -> Map.insert node Follower map) Map.empty

main :: IO ()
main = do
  let states = map (\x -> sendCmd x (initStateMap nodeList) Bootup) nodeList
  putStrLn $ unlines $ map show states 
  where nodeList = [Node "a", Node "b", Node "c"]

sendCmd :: Node -> StateMap -> Command -> [String]
sendCmd node stateMap cmd = case Map.lookup node stateMap of
  Just state -> do
    map (\(x,y) -> (getId node) ++ " " ++ (show . fst) x ++ " " ++ (show . snd) x ++ " " ++  y) $ updateState cmd state
  Nothing -> error "No state found for node " ++ [getId node]

updateState :: Command -> NState -> Log
updateState cmd = (snd . (evalState $ runWriterT (updateStateT cmd)))

updateStateT :: Command -> WriterT Log (State NState) ()
updateStateT cmd = do
  curState <- get
  case curState of
    Leader -> do
      tell [((1, 1), show cmd)]
      put $ Leader.handleCommand cmd curState
    Follower -> do
      tell [((1, 1), show cmd)]
      put $ Follower.handleCommand cmd curState
    Candidate -> do
      tell [((1, 1), show cmd)]
      put $ Candidate.handleCommand cmd curState