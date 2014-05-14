module Types where
{-
  Types for Raft nodes
-}

data NodeState = Leader | 
                 Follower |
                 Candidate
                 
data Command = Broadcast |
               RequestVotes |
               AppendEntries  
                 
               