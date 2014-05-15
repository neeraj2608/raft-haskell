module Types where
{-
  Types for Raft nodes
-}

import Control.Monad.State
import Control.Monad.Writer
import qualified Data.Map as Map

data NState = Leader | 
              Follower |
              Candidate
              deriving (Show, Eq)

data NodeStateDetails = NodeStateDetails {
                          curState :: NState,
                          commitIndex :: Integer,
                          curLeaderId :: NodeId,
                          votedFor :: NodeId,
                          followerList :: [NodeId]
                        } deriving (Show)

type NodeStateT = WriterT Log (State NodeStateDetails)

type Index = Integer
type Term = Integer
type LogState = (Index, Term)
type Log = [(LogState, String)]

type StateMap = Map.Map Node NodeStateDetails

type NodeId = Maybe String

data Node = Node {getId :: NodeId} deriving (Ord, Eq)

data Command = 
    Bootup |
    
    -- used by candidates to broadcast requestVotes
    Broadcast Command |
    
    -- broadcast by candidates
    -- candidate includes its state. Used at follower end to determine if the follower is more
    -- "up-to-date" than the candidate. See RejectVote definition to see how "up-to-date" is
    -- determined
    RequestVotes LogState |
    
    -- sent by follower to candidate in response to RequestVotes if its log is more up to date than
    -- the candidate's. Up-to-dateness is determined using the following two rules:
    -- a. the log with the larger term in its last entry is more up to date
    -- b. if both logs have the same number of entries, the longer log is more up to date
    RejectVote |
    
    -- sent by followers to candidates.
    -- A candidate votes first for itself and hence will never give out a vote to anyone else
    GiveVote |
    
    -- sent by leader to its followers
    -- 2nd arg: highest index so far committed
    -- 3rd arg: (index, term) of previous log entry. Used for log consistency check at follower end
    AppendEntry Index LogState |
    
    -- sent by follower to leader in response to AppendEntry if log consistency check fails
    RejectAppendEntry |
    
    -- sent by client to leader. if the node that receives this is not the leader, it forwards it
    -- to the leader.
    -- TODO: have some data as an argument?
    AcceptClientReq |
    
    RespondClientReq
    deriving (Show)
