{-# LANGUAGE FlexibleInstances #-}
module Types where

import Data.Maybe (fromJust)
import Control.Monad.State
import Control.Monad.Writer
import Control.Concurrent.STM
import System.Random
import System.Time
import System.Timeout
import Text.Printf
import qualified Data.Map as Map

type NWS = WriterT Log (StateT NodeStateDetails IO)
type Port = String
type ConnectionMap = TVar (Map.Map NodeId (TChan Command))
type NodeId = Maybe String
type Index = Integer
type Term = Integer
type LogState = (Index, Term)
type Log = [(LogState, String)]
type StateMap = Map.Map Node NodeStateDetails

data Role = Leader |
            Follower |
            Candidate
            deriving (Show, Eq)

-- | Encapsulates the state of a Raft node
data NodeStateDetails = NodeStateDetails {
                          currRole :: Role, -- ^ Current role of this node
                          commitIndex :: Integer, -- ^ Used by leader. latest log index known to be safely committed
                          currLeaderId :: NodeId, -- ^ Id of the current leader. Used by followers to redirect requests sent to them by clients
                          votedFor :: NodeId, -- ^ Id of the last node we voted for
                          followerList :: [(NodeId, Index)], -- ^ List of NodeIds + nextIndex for this node's followers
                          currTerm :: Term, -- ^ The latest term seen by this node
                          nodeId :: NodeId,  -- ^ The id of this node
                          inbox :: TChan Command,
                          cMap :: ConnectionMap,
                          nodeLog :: Log,
                          stdGen :: StdGen,
                          electionDur :: Int
                        }

data Node = Node {getId :: NodeId} deriving (Ord, Eq, Show)

data Command =
    -- broadcast by candidates
    -- 5.4.1 candidate includes its state. Used at follower end to determine if the follower is more
    -- "up-to-date" than the candidate. See RejectVote definition to see how "up-to-date" is
    -- determined
    RequestVotes Term NodeId LogState |

    -- §5.4.1 sent by follower to candidate in response to RequestVotes if its log is more up to date than
    -- the candidate's. Up-to-dateness is determined using the following two rules:
    -- a. the log with the larger term in its last entry is more up to date
    -- b. if both logs have the same number of entries, the longer log (i,e., larger index) is more up to date
    -- The response consists of the current term at the receiver and a Bool
    -- indicating whether the vote was granted.
    RespondRequestVotes Term Bool NodeId |

    -- sent by leader to its followers
    AppendEntries Term NodeId LogState Log Index |

    -- sent by follower to leader in response to AppendEntry if log consistency check fails
    RespondAppendEntries Term NodeId Index Bool |

    -- sent by client to leader. if the node that receives this is not the leader, it forwards it
    -- to the leader.
    -- TODO: have some data as an argument? we'll just say String for the moment
    ClientReq String |

    RespondClientReq
    deriving (Show)

liftio :: IO a -> NWS a
liftio = lift . lift

liftstm :: STM a -> NWS a
liftstm = liftio . atomically

-- | Increments the last log index and logs a string to the new
--   index. The string is tagged with term = current term.
--   Also updates the log in the StateT monad
writeToLog :: String -> NodeStateDetails -> NWS NodeStateDetails
writeToLog info nsd = do
        let index = lastLogIndex nsd
            currterm = currTerm nsd
            newLog = ((index+1,currterm),info)
            newNsd = nsd{nodeLog=newLog:nodeLog nsd} -- consing to head is O(1). Better than ++ which is O(n) in length of first list
        tell $ addNodeInfo nsd [newLog]
        put newNsd
        return newNsd

writeToLog' :: Log -> NodeStateDetails -> NWS NodeStateDetails
writeToLog' lg nsd = do
        let newNsd = nsd{nodeLog=lg++nodeLog nsd}
        tell $ addNodeInfo nsd lg
        put newNsd
        return newNsd

addNodeInfo :: NodeStateDetails -> Log -> Log
addNodeInfo nsd = fmap f
    where f :: (LogState, String) -> (LogState, String)
          f (x, s) = (x, fromJust (nodeId nsd) ++ " " ++ (show . currRole) nsd ++ " " ++ s)

lastLogIndex :: NodeStateDetails -> Index
lastLogIndex nsd = fst $ lastLogIndexTerm nsd

lastLogTerm :: NodeStateDetails -> Index
lastLogTerm nsd = snd $ lastLogIndexTerm nsd

lastLogIndexTerm :: NodeStateDetails -> (Index, Term)
lastLogIndexTerm nsd | null $ nodeLog nsd = (0, 0) -- index starts off at 1 (0 is incremented to 1 in writeToLog)
                     | otherwise = fst $ head $ nodeLog nsd

-- This method is called by the Leader while sending an AppendEntries command. Since
-- this can only happen after the leader has appended at least one client request to
-- its log, nodeLog has to have a length of at least 1.
prevLogIndexTerm :: NodeStateDetails -> (Index, Term)
prevLogIndexTerm nsd | length (nodeLog nsd) == 1 = (0, 0)
                     | otherwise = fst $ nodeLog nsd !! 1

-- | Log a string to STDOUT. Uses the current term and index
logInfo :: String -> NWS ()
logInfo info = do
        nsd <- get
        let nodeid = nodeId nsd
            index = lastLogIndex nsd
            term = currTerm nsd
        liftio $ putStrLn (show index ++ " " ++ show term ++ " " ++ fromJust nodeid ++ " " ++ (show . currRole) nsd ++ " " ++ info)

-- | broadcast to all nodes except yourself
broadCastExceptSelf :: Command -> ConnectionMap -> NodeId -> IO ()
broadCastExceptSelf cmd connectionMap nid = do
        m <- readTVarIO connectionMap
        mapM_ (sendCommand' cmd) $ Map.elems $ Map.filterWithKey (\n _ -> n /= nid) m

broadCast :: Command -> ConnectionMap -> IO ()
broadCast cmd connectionMap = do
        m <- readTVarIO connectionMap
        mapM_ (sendCommand' cmd) $ Map.elems m

-- | Send a command to a node
sendCommand :: Command -> NodeId -> ConnectionMap -> IO ()
sendCommand cmd nid cm = do
        m <- atomically $ readTVar cm
        case Map.lookup nid m of
            Nothing -> error $ "No mapping for node Id " ++ fromJust nid
            Just tChan -> sendCommand' cmd tChan

-- | Send a command to a node's inbox
sendCommand' :: Command -> TChan Command -> IO ()
sendCommand' cmd ibox =
        --printf "Sending command: %s\n" $ show cmd
        atomically $ writeTChan ibox cmd

-- | Used to broadcast heartbeats
-- note that broadcast time << election time << MTBF
-- broadcast time is a function of your network topology
-- election timeouts are under programmer control
-- duration is specified in microseconds
createBroadcastTimeout :: NWS ()
createBroadcastTimeout = createTimeout 250000

-- | Used for election timeouts
-- note that broadcast time << election time << MTBF
-- duration is specified in microseconds
createElectionTimeout :: NWS ()
createElectionTimeout = do
    nsd <- get
    let duration = electionDur nsd
    logInfo $ printf "Using election timeout = %s mSec" $ show $ duration `div` 1000
    createTimeout duration

-- | Used by candidates to randomize backoff time at the start of every election. The randomized
--   time so chosen will be used until the next time this node starts an election
resetRandomizedElectionTimeout :: NodeStateDetails -> NWS NodeStateDetails
resetRandomizedElectionTimeout nsd = do
    time <- liftio $ System.Time.toCalendarTime =<< getClockTime
    let std = mkStdGen $ fromIntegral $ ctPicosec time
        (dur, newStd) = randomR (150000,300000) std
        newNsd = nsd{stdGen=newStd, electionDur=dur}
    put newNsd
    logInfo $ printf "Reset election timeout = %s mSec" $ show $ dur `div` 1000
    createTimeout dur
    return newNsd

-- | duration is specified in microseconds
createTimeout :: Int -> NWS ()
createTimeout duration = do
    nsd <- get
    startTime <- liftio getClockTime
    result <- liftio $ timeout duration (atomically $ peekTChan (inbox nsd))
    endTime <- liftio getClockTime
    logInfo $ printf "%s mSec elapsed; Received = %s" (show $ (`div` 1000000000) $ tdPicosec (diffClockTimes startTime endTime)) (show result)
