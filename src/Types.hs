{-# LANGUAGE FlexibleInstances #-}
module Types where

import Control.Monad.State
import Control.Monad.Writer
import Control.Concurrent.STM
import qualified Data.Map as Map

data Role = Leader |
            Follower |
            Candidate
            deriving (Show, Eq)

type NWS = WriterT Log (StateT NodeStateDetails IO)

-- | Encapsulates the state of a Raft node
data NodeStateDetails = NodeStateDetails {
                          currRole :: Role, -- ^ Current role of this node
                          commitIndex :: Integer,
                          curLeaderId :: NodeId, -- ^  Id of the current leader. Used by followers to redirect requests sent to them by clients
                          votedFor :: NodeId, -- ^ Id of the last node we voted for
                          followerList :: [NodeId], -- ^ List of NodeIds of this node's followers
                          lastLogIndex :: Integer, -- ^ The last index in the log written thus far
                          lastLogTerm :: Integer, -- ^ The last term in the log written thus far
                          nodeId :: Maybe String,  -- ^ The id of this node
                          inbox :: TChan Command
                        } deriving (Show)

instance Show (TChan Command) where
        show _ = "inbox"

type NodeId = Maybe String

data Node = Node {getId :: NodeId} deriving (Ord, Eq, Show)

type Index = Integer
type Term = Integer
type LogState = (Index, Term)
type Log = [(LogState, String)]

type StateMap = Map.Map Node NodeStateDetails

data Command =
    Bootup |

    -- used by candidates to broadcast requestVotes
    Broadcast Command |

    StartCanvassing |

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
