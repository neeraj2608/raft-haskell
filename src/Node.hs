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
import Data.Maybe (fromJust)

initStateMap :: [Node] -> StateMap
initStateMap = foldr (\node map -> Map.insert node initState map) Map.empty
  where initState = NodeStateDetails Follower 0 Nothing Nothing []

main :: IO ()
main = do
  let states = map (\x -> sendCmd x (initStateMap nodeList) Bootup) nodeList
  putStrLn $ unlines $ map show states 
  where nodeList = [Node (Just "a"), Node (Just "b"), Node (Just "c")]

sendCmd :: Node -> StateMap -> Command -> [String]
sendCmd node initStateMap cmd = case Map.lookup node initStateMap of
  Just state -> do
    map (\(x,y) -> (fromJust $ getId node) ++ " " ++ (show . fst) x ++ " " ++ (show . snd) x ++ " " ++  y) $ updateState cmd state
  Nothing -> error "No state found for node " ++ [show $ getId node]

updateState :: Command -> NodeStateDetails -> Log
updateState cmd = (snd . (evalState $ runWriterT (updateStateT cmd)))

updateStateT :: Command -> NodeStateT ()
updateStateT cmd = do
  s <- get
  let currentState = curState s
  case currentState of
    Leader -> do
      tell [((1, 1), show cmd)]
      let newState = Leader.handleCommand cmd currentState
      put s{curState=newState}
    Follower -> do
      tell [((1, 1), show cmd)]
      let newState = Follower.handleCommand cmd currentState
      put s{curState=newState}
    Candidate -> do
      tell [((1, 1), show cmd)]
      let newState = Candidate.handleCommand cmd currentState
      put s{curState=newState}
