------------------------------- MODULE Janus -------------------------------

EXTENDS Naturals, Sequences, TLC, FiniteSets
CONSTANT M, N, X \* N partitions, in X-way replica

CONSTANT OP
CONSTANT PIE
CONSTANT TXN
CONSTANT TXN_POOL
  
CONSTANT Shard(_)

MAX(m, n) == IF m > n THEN m ELSE n

(* status space of a transaction *)
UNKNOWN      == 0
PRE_ACCEPTED == 1
PREPARED     == 2
ACCEPTED     == 3 
COMMITTING   == 4
DECIDED      == 5

FAST_QUORUM == (X * 2) \div 3 + 1
SLOW_QUORUM == X \div 2 + 1 

id_counter == 0

(* serialization graph *)

IsSrzGraph(G) == (* True iff G is a srz graph *)
  /\ G = [node |-> G.node, edge |-> G.edge]
  /\ G.edge \subseteq (G.node \X G.node)

SubSrzGraph(G) == 
  { H \in [node : SUBSET G.node, edge : SUBSET (G.node \X G.node)] :
      /\ IsSrzGraph(H) 
      /\ H.edge \subseteq G.edge
      /\ \forall m \in H.node, n \in H.node: 
        /\ <<m, n>> \in G.edge => <<m, n>> \in H.edge 
        /\ <<m, n>> \in G.edge => <<m, n>> \in H.edge
  }
  
SrzAddNode(G, node) == 
  [G EXCEPT !.node = @ \union {node}]

SrzAddEdge(G, m, n) == 
  [G EXCEPT !.edge = @ \union {<<m, n>>}]

Path(G) == 
  {p \in Seq(G.node) : /\ p /= <<>>
                       /\ \forall i \in 1 .. (Len(p)-1) : <<p[i], p[i+1]>> \in G.edge}

  
Cyclic(G) == 
  \exists p \in Path(G) : /\ Len(p) > 1
                          /\ p[1] = p[Len(p)]
                            
Acyclic(G) == ~Cyclic(G)                             
  
(* dependency graph *) 

IsDepGraph(G) == (* True iff G is a dep graph. *)
  /\ G = [node |-> G.node, 
          edge |-> G.edge, 
          status |-> G.status, 
          svrset |-> G.svrset, 
          max_ballot |-> G.max_ballot]
  /\ G.edge \subseteq (G.node \X G.node \X {"i", "d"})
  /\ G.status \in [i \in G.node |-> {UNKNOWN, PRE_ACCEPTED, PREPARED, ACCEPTED, COMMITTING, DECIDED}]
  /\ G.svrset \in [i \in G.node |-> SUBSET {M+1 .. M+N}]
  /\ G.max_ballot \in [i \in G.node |-> Nat]

SubDepGraph(G) == (* The set of all subgraphs of a dep graph. 
                     Note: All edges that belong to the included nodes are included. *)
  { H \in [node : SUBSET G.node, edge : SUBSET (G.node \X G.node \X {"i", "d"})] :
      /\ IsDepGraph(H) 
      /\ H.edge \subseteq G.edge
      /\ \forall m \in H.node, n \in H.node: /\ <<m, n, "i">> \in G.edge => <<m, n, "i">> \in H.edge 
                                             /\ <<m, n, "d">> \in G.edge => <<m, n, "d">> \in H.edge
  }

DepAddNode(G, node, status, svrset) == 
  IF node \in G.node 
    THEN [G EXCEPT !.status[node] = MAX(@, status), !.svrset[node] = @ \union svrset]
    ELSE [G EXCEPT !.node = @ \union {node}, !.status[node] = status, !.svrset[node] = svrset]
        
DepAddEdge(G, edge) == 
  [G EXCEPT !.edge = @\union edge]

\* TODO    
Aggregate(G1, G2) == 
  [node |-> G1.node \union G2.node, edge |-> G1.edge \union G2.edge, 
    status |-> [m \in G1.node \union G2.node |-> IF m \in G1.node THEN 
                                                   IF m \in G2.node THEN 
                                                     MAX(G1.status[m], G2.status[m]) 
                                                   ELSE 
                                                     G1.status[m] 
                                                 ELSE
                                                   G2.status[m]
               ],
    svrset |-> [m \in G1.node \union G2.node |-> IF m \in G1.node THEN
                                                   IF m \in G2.node THEN
                                                     G1.svrset[m] \union G2.svrset[m]
                                                   ELSE
                                                     G1.svrset[m]
                                                   ELSE
                                                     G2.svrset[m]
               ]
  ]
  
FindOrCreateTxn(dep, tid) == 
  IF tid \in dep.node THEN 
    [status |-> dep.status[tid], max_ballot |-> dep.max_ballot[tid]]
  ELSE
    [status |-> UNKNOWN, max_ballot |-> 0]

TempOp(acks) == 
  [x \in acks |-> x.dep]

CommitReady(accept_acks, partitions) == 
  IF \forall p \in partitions: Len(accept_acks[p]) >= SLOW_QUORUM THEN TRUE ELSE FALSE  

UpdateBallot(dep, tid, ballot, status) == 
  [dep EXCEPT !.status[tid] = status, !.max_ballot[tid] = ballot]

FastPathPossible(pre_accept_acks, partitions) == 
  IF \exists p \in partitions: 
       /\ Len(pre_accept_acks[p]) >= X - FAST_QUORUM
       /\ \forall m, n \in pre_accept_acks[p]: m.dep /= n.dep
    THEN FALSE
  ELSE TRUE   
  
PickXXX(acks) == 
  CHOOSE a \in acks: TRUE

FastPathReady(pre_accept_acks, partitions) == 
  \forall p \in partitions: 
    /\ Len(pre_accept_acks[p]) >= FAST_QUORUM
    /\ \forall m, n \in pre_accept_acks[p]: m.dep = n.dep  

SlowPathPossible(prepare_acks, partitions) == 
  \forall p \in partitions: 
    /\ Len(prepare_acks[p]) >= SLOW_QUORUM

\* proc M + (par_id-1) *X, M + par_id * X
BroadcastMsg(mq, p, msg) == 
  [i \in M+1 .. M+N*X |-> IF i \in M+(p-1)*X .. M+p*X THEN 
                            Append(mq[i], msg) 
                          ELSE mq[i]]

ProcIdToPartitionId(proc_id) == 
  (proc_id - M) \div X + 1 

PartitionsToProcIds(partitions) ==
  CHOOSE ids \in SUBSET{M+1 .. M+N*X}:
    \forall p \in M+1..M+N*X:
      \/ /\ p \in partitions
         /\ \forall x \in M+(p-1)*X..M+p*X: x \in ids
      \/ /\ p \notin partitions
         /\ \forall x \in M+(p-1)*X..M+p*X: x \notin ids        

BroadcastMsgToMultiplePartitions(mq, partitions, msg) == 
  [i \in M+1 .. M+N*X |-> IF i \in PartitionsToProcIds(partitions) THEN 
                            Append(mq[i], msg) 
                          ELSE mq[i]]                               

GetStatus(dep, tid) == (* Retrieve the status of a transaction by its id from a dep graph *)
  CHOOSE status : status = dep.node_prop[tid].status
    
UpdateStatus(dep, tid, status) == (* Update the status of a transaction to a newer status by its id *)
  IF dep.status[tid] < status THEN [dep EXCEPT !.status[tid] = status] ELSE dep
    
UpdateSubGraphStatus(G, H, status) == 
  [ G EXCEPT !.status = [m \in G.node |-> IF m \in H.node THEN 
                                            MAX(G.status[m], H.status[m]) 
                                          ELSE 
                                            G.status[m]]]

IsInvolved(dep, tid, sid) == (* Judge if a transaction involves this server *)
    IF sid \in dep.svrset[tid] THEN TRUE ELSE FALSE


AreDirectlyConnectedIn(m, n, G) == 
  \exists p \in Path(G) : (p[1] = m) /\ (p[Len(p)] = n) /\ Len(p) = 1

AreConnectedIn(m, n, G) == 
    \exists p \in Path(G) : (p[1] = m) /\ (p[Len(p)] = n)
    
AreStronglyConnectedIn(m, n, G) ==
    /\ AreConnectedIn(m, n, G)
    /\ AreConnectedIn(n, m, G)
    
IsStronglyConnected(G) == 
    \forall m, n \in G.node : AreConnectedIn(m, n, G)
    
StronglyConnectedComponent(G, node) == (* Compute the Strongly Connected Component of a node *)
  CHOOSE scc \in SubDepGraph(G) : /\ IsStronglyConnected(scc)
                                  /\ node \in scc.node
                                  /\ \forall m \in G.node : 
                                    AreStronglyConnectedIn(m, node, G) => m \in scc.node

UndecidedAncestor(G, tid) == 
  CHOOSE anc \in SubDepGraph(G) : 
    \forall m \in G.node : 
      ( /\ AreConnectedIn(m, tid, G) 
        /\ GetStatus(G, tid) < DECIDED ) 
        => m \in anc.node
                
NearestDependencies(dep, tid) == 
  CHOOSE anc \in SubDepGraph(dep) :
    /\ \forall m \in dep.node:
      AreDirectlyConnectedIn(m, tid, dep) => m \in anc.node
    /\ \forall m \in anc.node: AreDirectlyConnectedIn(m, tid, dep)  

DowngradeExcept(dep, tid) == 
  [dep EXCEPT !.status = [m \in dep.node |-> (IF m /= tid THEN UNKNOWN ELSE dep.status[m])]]
    
NearestDependenciesWithDowngrade(dep, tid) == 
  DowngradeExcept(NearestDependencies(dep, tid), tid)

AreAllAncestorsAtLeastCommitting(G, tid) ==
    \forall m \in G.node : AreConnectedIn(m, tid, G) => G.status[m] >= COMMITTING
    
AllAncestorsLowerThanCommitting(G, tid) ==
  CHOOSE anc \in SubDepGraph(G) : 
    \forall m \in G.node: 
      ( /\ AreConnectedIn(m, tid, G) 
        /\ GetStatus(G, tid) < COMMITTING ) 
        => m \in anc.node


CommittingSubGraphWithAllAnestorsAtLeastCommitting(G) == 
  CHOOSE H \in SubDepGraph(G) : /\ \forall m \in H.node : H.status[m] = COMMITTING
                                /\ \forall m \in H.node : AreAllAncestorsAtLeastCommitting(G, m)

Unfinished(finished_map, tid) == 
  finished_map[tid] /= TRUE
    
Finished(finished_map, tid) == 
  finished_map[tid] = TRUE                                         

AreSubGraphAncestorsAtLeastCommitting(G, H) == 
  \forall m \in G.node : ( /\ m \notin H.node 
                           /\ \exists n \in H.node : AreConnectedIn(m, n, G)
                         ) 
                         => G.status[m] >= COMMITTING
                            
AreSubGraphLocalAncestorsFinished(G, H, sid, finished_map) ==
  \forall m \in G.node : ( /\ m \notin H.node 
                           /\ \exists n \in H.node : AreConnectedIn(m, n, G)
                           /\ sid \in G.svrset[m]
                         ) 
                         => finished_map[sid] = TRUE
                                                                                                                                            
    
\* DecidedUnfinishedLocalSCCWithAllAncestorsCommittingAndAllLocalAncestorsFinished
ToExecuteSCC(G, sid, finished_map) == 
  CHOOSE scc \in SubDepGraph(G) : 
    /\ IsStronglyConnected(scc)
    /\ \exists tid \in scc.node : scc = StronglyConnectedComponent(G, tid)
    /\ \forall tid \in scc.node : scc.status[tid] = DECIDED
    /\ \exists tid \in scc.node : IsInvolved(scc, tid, sid) /\ Unfinished(finished_map, tid) 
    /\ AreSubGraphAncestorsAtLeastCommitting(G, scc)
    /\ AreSubGraphLocalAncestorsFinished(G, scc, sid, finished_map)



ToExecuteSCCSet(G, sid, finished_map) ==
  { scc \in SubDepGraph(G) : 
      /\ IsStronglyConnected(scc)
      /\ \exists tid \in scc.node : scc = StronglyConnectedComponent(G, tid)
      /\ \forall tid \in scc.node : scc.status[tid] = DECIDED
      /\ \exists tid \in scc.node : IsInvolved(scc, tid, sid) /\ Unfinished(finished_map, tid) 
      /\ AreSubGraphAncestorsAtLeastCommitting(G, scc)
      /\ AreSubGraphLocalAncestorsFinished(G, scc, sid, finished_map) 
  }                            

NextToExe(scc) == 
    CHOOSE t \in scc.node : \forall tid \in scc.node: tid >= t


-----------------------------------------------------
(* Offline checking *)

Conflict(p, q) == 
  \exists op1 \in p, op2 \in q: /\ op1.key = op2.key
                                /\ ( \/ op1.type /= op2.type
                                     \/ op1.type = "w" )

ConnectedS(TxnSet, p, q) ==
    \exists T \in TxnSet: /\ p \in T
                          /\ q \in T

ConnectedC(TxnSet, p, q) ==
    \exists T, K \in TxnSet: /\ T /= K
                             /\ p \in T
                             /\ q \in K
                             /\ Conflict(p, q)

ConnectedCI(TxnSet, p, q) ==
    /\ ConnectedC(TxnSet, p, q)
    /\ p.iord = "i"                         

SCIPath(TxnSet) ==
  { path \in Seq(UNION(TxnSet)): 
      /\ \forall i \in 1..Len(path): \/ ConnectedS(TxnSet, path[i], path[i+1])
                                     \/ ConnectedCI(TxnSet, path[i], path[i+1])
      /\ \exists i \in 1..Len(path): ConnectedS(TxnSet, path[i], path[i+1])
      /\ \exists i \in 1..Len(path): ConnectedCI(TxnSet, path[i], path[i+1])
  }  

ImmediacyProp(TxnSet) == 
  \forall T, K \in TxnSet: 
    \forall p \in T, q \in K: Conflict(p,q) => p.iord = q.iord

HasImmediateSCCycle(TxnSet) == 
  \exists path \in SCIPath(TxnSet): 
    /\ path[1] = path[Len(path)]
    /\ \forall i, j \in 1..Len(path)-1: i/=j => path[i] /= path[j]

OfflineCheck(TxnSet) == /\ ImmediacyProp(TxnSet)
                        /\ ~HasImmediateSCCycle(TxnSet)

-------------------------------------------------------------------------
(*
--algorithm Janus {
  variables coo_mq = [i \in 1 .. M |-> <<>>]; \* Assume there are M coordinators. 
            \* par_mq = [i \in 1 ..
            svr_mq = [i \in M .. M+N*X |-> <<>>]; \* Assume each partition has X servers, N partitions in total.
            srz;
            
  procedure AggregateGraphForFastPath(acks) {
    xxxxx: graph := {};
    yyyyy: while (acks /= {}) {
      with (a \in acks) {
        acks := acks \ {a};
        tmp_acks := a;
      };
      graph := Aggregate(graph, PickXXX(tmp_acks));
    };
    return;
  }       
  
  procedure AggregateGraphForAccept(acks) {
    xxxxx: graph := {};
    yyyyy: while (acks /= {}) {
      with (a \in acks) {
        acks := acks \ {a};
        tmp_acks := a;
      };
      zzzzz: while (tmp_acks /= <<>>) {
        with (a \in tmp_acks) {
          graph := Aggregate(graph, a.dep);
          tmp_acks := Tail(tmp_acks);         
        }
      }
    };
    return;
  }         
  
  procedure exe_pie(curr_pie, keyspace)
  {
    start_exe_pie: opset := curr_pie.opset;              
    pie_add_srz: while (opset /= {}) {
      with (next_op \in opset) {
        curr_op := next_op;
        opset := opset \ {next_op};                   
      };  
      srz := SrzAddNode(srz, curr_txn.tid);
      alogs := keyspace[curr_op.key].alogs;                       
      scan_alogs: while (alogs /= {}) {
        with (next_access \in alogs) {
          alogs := alogs \ {next_access};
          if ( \/ next_access.type /= curr_op.type 
               \/ next_access.type = "w") {
            srz := SrzAddEdge(srz, next_access.tid, curr_txn.tid);   
          };
          keyspace[curr_op.key].logs := @ \union {<<curr_txn.tid, curr_op.type>>};
        }
      };  
    };
    return;
  }  
    
  process(Coo \in 1 .. M)
  variables next_txn; 
            next_pie;
            txn_id;
            par;
            partitions; 
            n_pie; 
            graph; 
            msg_in; 
            msg_out;
            pre_accept_acks;
            accept_acks;
            committed;
            ballot;
            tmp_acks;
  {
    coo: committed := FALSE;
    graph := {};
    partitions := {};      
    next_txn := TXN[self];
    
    id_counter := id_counter + 1;
    txn_id := id_counter;
  
    n_pie := Len(next_txn);    
    pre_accept: while (Len(next_txn) > 0) {
      next_pie := Head(next_txn);
      next_txn := Tail(next_txn);
      par := Shard(next_pie);
      partitions := partitions \union {par};
      msg_out := [
                    type |-> "pre_accept", 
                    source |-> self, 
                    tid |-> txn_id, 
                    opset |-> next_pie.opset 
                 ];
      svr_mq := BroadcastMsg(svr_mq, par, msg_out);
    };
    
    \* wait for acks. 
    pre_accept_acks := {};
    pre_accept_ack: while (Len(pre_accept_acks) < N + 1) { \* this is a dead loop
      await Len(coo_mq[self]) > 0;
      msg_in := Head(coo_mq[self]); 
      coo_mq[self] := Tail(coo_mq[self]);
      if (msg_in.type = "ack_pre_accept" /\ msg_in.tid = txn_id) {
        par := ProcIdToPartitionId(msg_in.source);
        pre_accept_acks[par] := Append(pre_accept_acks[par], msg_in);
        if (FastPathPossible(pre_accept_acks, partitions)) {
          graph := AggregateGraphForFastPath(pre_accept_acks);
          goto commit_phase;
        };
        slow_path_check: if (SlowPathPossible(pre_accept_acks, partitions)) {
          call AggregateGraphForAccept(pre_accept_acks);
          dsfdsfd: goto accept_phase;
        };
        \* TODO if nothing is possible then find something to do.
      } \* else an outdated message, do nothing.            
    };
    
    \* TODO
    ballot := 0;
    accept_phase: msg_out := [
      type |-> "accept",
      ballot |-> ballot,
      source |-> self, 
      tid |-> txn_id,
      graph |-> graph
    ];
    broadcast_accept: svr_mq := BroadcastMsgToMultiplePartitions(svr_mq, partitions, msg_out);
    accept_acks := {};
    accept_ack: while(TRUE) { \* this is a dead loop
      await Len(coo_mq[self]) > 0;
      msg_in := Head(coo_mq[self]); 
      coo_mq[self] := Tail(coo_mq[self]);      
      if (msg_in.type = "ack_accept" /\ msg_in.tid = txn_id /\ msg_in.max_ballot = ballot) {
        par := ProcIdToPartitionId(msg_in.source);
        accept_acks[par] := Append(accept_acks[par], msg_in);
        if (CommitReady(accept_acks, partitions)) {
          goto commit_phase;
        }
        \* TODO if nothing is possible then find something to do.
      }
    };
    
    commit_phase: msg_out := [
      type |-> "commit",
      source |-> self, 
      tid |-> txn_id      
    ]; 
    
    broadcast_commit: svr_mq := BroadcastMsgToMultiplePartitions(svr_mq, partitions, msg_out);            
    commit_ack: while (Len(coo_mq[self]) > 0) {
      msg_in := Head(coo_mq[self]);
      coo_mq[self] := Tail(coo_mq[self]);                 
      if (msg_in.type = "commit_ack" /\ msg_in.tid = txn_id) {
        (* COMMITED *)
        committed := TRUE;
      }     
    };
  }
    
  process (Svr \in M+1 .. M+N*X) 
  variables msg_in; 
            msg_out; 
            msg; 
            keyspace; 
            dep = {};  
            ya_dep = {}; 
            finished_map; 
            asked_map; 
            pie_map; 
            last_w_tid; 
            last_r_tid; 
            scc, 
            scc_set; 
            scc_seq; 
            curr_txn;
            curr_pie;
            curr_op;            
            txn_set;
            opset; 
            next_txn;
            next_tid;
            anc; 
            tmp_set;
            alogs;
             
  {
    svr_msg_loop: await Len(svr_mq[self]) > 0;
    msg := Head(svr_mq[self]);
    svr_mq[self] := Tail(svr_mq[self]);
    ya_dep := {};
    \* curr_txn := [tid |-> msg.tid, status |-> "unknown", partitions |-> msg.partitions];        
    \* dep := DepAddNode(dep, curr_txn.tid, UNKNOWN, msg.partitions);
    curr_txn := FindOrCreateTxn(dep, msg.tid);
    if (msg.type = "pre_accept" /\ curr_txn.max_ballot = 0) {
      curr_pie := msg.pie;
      opset := curr_pie.opset;
      pie_add_dep: while (opset /= {}) {
        with (next_op \in opset) {
          opset := opset \ {next_op};
          curr_op := next_op;      
        };
        last_r_tid := keyspace[curr_op.key].last_r_tid;
        last_w_tid := keyspace[curr_op.key].last_w_tid;
        
        dep := DepAddEdge(dep, <<last_w_tid, curr_txn.tid, curr_pie.iord>>);
        if (curr_op.type = "w") {
          keyspace[curr_op.key].last_w_tid := curr_txn.tid;
          read_con: dep := DepAddEdge(dep, <<last_r_tid, curr_txn.tid, curr_pie.iord>>);
        } else {
          keyspace[curr_op.key].last_r_tid := curr_txn.tid;
        };
      };
      (* reply dependencies *)            
      reply_dep: ya_dep := NearestDependenciesWithDowngrade(dep, curr_txn.tid);
      msg_out := [type |-> "ack_pre_accept", src |-> self, dep |-> ya_dep];
      coo_mq[msg.source] := Append(coo_mq[msg.src], msg_out);                         
    } else if ( \/ msg.type = "commit" 
                \/ msg.type = "ack_inquire") {
      aggregate_graph: dep := Aggregate(dep, msg.dep);

      (* send inquire request for uninvovled & uncommitted ancestors *)            
      txn_set := AllAncestorsLowerThanCommitting(dep, msg.tid);
      inquire_if_needed: while (txn_set /= {}) {
        with (txn \in txn_set) {
          txn_set := txn_set \ {txn};
          if (self \in txn.partitions) {
            skip;
          } else {
            with (dst \in txn.partitions) {
              msg_out := [type |-> "inquire", tid |-> txn.tid];
              svr_mq := BroadcastMsg(svr_mq, dst, msg_out);
              skip;
            } 
          }                      
        }                
      };
    
      (* Trigger decision for those transactions whose status are COMMITTING 
          and their ancestors all become at least committing *)            
      choose_to_commit: txn_set := CommittingSubGraphWithAllAnestorsAtLeastCommitting(dep);
      ready_to_commit: while (txn_set /= {}) {
        with (txn \in txn_set) {
          scc := StronglyConnectedComponent(dep, txn);
          txn_set := txn_set \ txn;
          (* every txn in the scc should become DECIDED *)
          dep := UpdateSubGraphStatus(dep, scc, DECIDED);
        }            
      };            
        
      find_execute: scc_set := ToExecuteSCCSet(dep, self, finished_map);  
        
      if (scc_set /= {}) {
        next_execute: while (scc_set /= {}) {                
          with (next_scc \in scc_set) {
            scc_set := scc_set \ {next_scc};
            scc := next_scc;
          };                          

          exe_scc: while (scc.node /= {}) {
            next_tid := NextToExe(scc);
            scc.node := scc.node \ {next_tid};

            if ( /\ IsInvolved(dep, next_tid, self) 
                 /\ Unfinished(finished_map, next_tid) ) {
           
              (* execute and add into serialization graph *)
              
              exe_all_deferred_pies: while (pie_map[next_tid] /= {}) {
                  with (pie \in pie_map[next_tid]) {
                      next_pie := pie;                                    
                      pie_map[next_tid] := pie_map[next_tid] \ {next_pie};
                  };
                  call exe_pie(next_pie, keyspace);                         
              };                                                                                        
              skip;   
            }
          };
        };
        goto find_execute;
      } else {
          skip;               
      }
                    
    } else if (msg.type = "inquire") {
      await GetStatus(dep, msg.tid) >= COMMITTING;
      inquire_ack: ya_dep := NearestDependenciesWithDowngrade(dep, msg.tid);                
      msg_out := [type |-> "ack_inquire", src |-> self, tid |-> msg.tid, dep |-> ya_dep];
      svr_mq[msg.source] := Append(coo_mq[msg.source], msg_out);
    } else if (msg.type = "prepare" /\ curr_txn.max_ballot < msg.ballot) {
      dep := UpdateBallot(dep, curr_txn.tid, msg.ballot, PREPARED);
      msg_out := [type |-> "ack_prepare", src |-> self, tid |-> msg.tid, ballot |-> msg.ballot];
      xxd: svr_mq[msg.source] := Append(coo_mq[msg.source], msg_out);        
    } else if (msg.type = "accept" /\ curr_txn.max_ballot <= msg.ballot) {
      dep := UpdateBallot(dep, curr_txn.tid, msg.ballot, ACCEPTED);
      dlskf: dep := Aggregate(dep, msg.dep);
      msg_out := [type |-> "ack_accept", src |-> self, tid |-> msg.tid, ballot |-> msg.ballot];
      svr_mq[msg.source] := Append(coo_mq[msg.source], msg_out);
    }
  } 
}
*)
\* BEGIN TRANSLATION
\* Label xxxxx of procedure AggregateGraphForFastPath at line 333 col 12 changed to xxxxx_
\* Label yyyyy of procedure AggregateGraphForFastPath at line 334 col 12 changed to yyyyy_
\* Process variable next_txn of process Coo at line 386 col 13 changed to next_txn_
\* Process variable msg_in of process Coo at line 393 col 13 changed to msg_in_
\* Process variable msg_out of process Coo at line 394 col 13 changed to msg_out_
\* Process variable keyspace of process Svr at line 491 col 13 changed to keyspace_
\* Process variable curr_pie of process Svr at line 503 col 13 changed to curr_pie_
\* Parameter acks of procedure AggregateGraphForFastPath at line 332 col 39 changed to acks_
CONSTANT defaultInitValue
VARIABLES coo_mq, svr_mq, srz, pc, stack, acks_, acks, curr_pie, keyspace, 
          next_txn_, next_pie, txn_id, par, partitions, n_pie, graph, msg_in_, 
          msg_out_, pre_accept_acks, accept_acks, committed, ballot, tmp_acks, 
          msg_in, msg_out, msg, keyspace_, dep, ya_dep, finished_map, 
          asked_map, pie_map, last_w_tid, last_r_tid, scc, scc_set, scc_seq, 
          curr_txn, curr_pie_, curr_op, txn_set, opset, next_txn, next_tid, 
          anc, tmp_set, alogs

vars == << coo_mq, svr_mq, srz, pc, stack, acks_, acks, curr_pie, keyspace, 
           next_txn_, next_pie, txn_id, par, partitions, n_pie, graph, 
           msg_in_, msg_out_, pre_accept_acks, accept_acks, committed, ballot, 
           tmp_acks, msg_in, msg_out, msg, keyspace_, dep, ya_dep, 
           finished_map, asked_map, pie_map, last_w_tid, last_r_tid, scc, 
           scc_set, scc_seq, curr_txn, curr_pie_, curr_op, txn_set, opset, 
           next_txn, next_tid, anc, tmp_set, alogs >>

ProcSet == (1 .. M) \cup (M+1 .. M+N*X)

Init == (* Global variables *)
        /\ coo_mq = [i \in 1 .. M |-> <<>>]
        /\ svr_mq = [i \in M .. M+N*X |-> <<>>]
        /\ srz = defaultInitValue
        (* Procedure AggregateGraphForFastPath *)
        /\ acks_ = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure AggregateGraphForAccept *)
        /\ acks = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure exe_pie *)
        /\ curr_pie = [ self \in ProcSet |-> defaultInitValue]
        /\ keyspace = [ self \in ProcSet |-> defaultInitValue]
        (* Process Coo *)
        /\ next_txn_ = [self \in 1 .. M |-> defaultInitValue]
        /\ next_pie = [self \in 1 .. M |-> defaultInitValue]
        /\ txn_id = [self \in 1 .. M |-> defaultInitValue]
        /\ par = [self \in 1 .. M |-> defaultInitValue]
        /\ partitions = [self \in 1 .. M |-> defaultInitValue]
        /\ n_pie = [self \in 1 .. M |-> defaultInitValue]
        /\ graph = [self \in 1 .. M |-> defaultInitValue]
        /\ msg_in_ = [self \in 1 .. M |-> defaultInitValue]
        /\ msg_out_ = [self \in 1 .. M |-> defaultInitValue]
        /\ pre_accept_acks = [self \in 1 .. M |-> defaultInitValue]
        /\ accept_acks = [self \in 1 .. M |-> defaultInitValue]
        /\ committed = [self \in 1 .. M |-> defaultInitValue]
        /\ ballot = [self \in 1 .. M |-> defaultInitValue]
        /\ tmp_acks = [self \in 1 .. M |-> defaultInitValue]
        (* Process Svr *)
        /\ msg_in = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ msg_out = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ msg = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ keyspace_ = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ dep = [self \in M+1 .. M+N*X |-> {}]
        /\ ya_dep = [self \in M+1 .. M+N*X |-> {}]
        /\ finished_map = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ asked_map = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ pie_map = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ last_w_tid = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ last_r_tid = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ scc = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ scc_set = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ scc_seq = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ curr_txn = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ curr_pie_ = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ curr_op = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ txn_set = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ opset = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ next_txn = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ next_tid = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ anc = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ tmp_set = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ alogs = [self \in M+1 .. M+N*X |-> defaultInitValue]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self \in 1 .. M -> "coo"
                                        [] self \in M+1 .. M+N*X -> "svr_msg_loop"]

xxxxx_(self) == /\ pc[self] = "xxxxx_"
                /\ graph' = [graph EXCEPT ![self] = {}]
                /\ pc' = [pc EXCEPT ![self] = "yyyyy_"]
                /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                curr_pie, keyspace, next_txn_, next_pie, 
                                txn_id, par, partitions, n_pie, msg_in_, 
                                msg_out_, pre_accept_acks, accept_acks, 
                                committed, ballot, tmp_acks, msg_in, msg_out, 
                                msg, keyspace_, dep, ya_dep, finished_map, 
                                asked_map, pie_map, last_w_tid, last_r_tid, 
                                scc, scc_set, scc_seq, curr_txn, curr_pie_, 
                                curr_op, txn_set, opset, next_txn, next_tid, 
                                anc, tmp_set, alogs >>

yyyyy_(self) == /\ pc[self] = "yyyyy_"
                /\ IF acks_[self] /= {}
                      THEN /\ \E a \in acks_[self]:
                                /\ acks_' = [acks_ EXCEPT ![self] = acks_[self] \ {a}]
                                /\ tmp_acks' = [tmp_acks EXCEPT ![self] = a]
                           /\ graph' = [graph EXCEPT ![self] = Aggregate(graph[self], PickXXX(tmp_acks'[self]))]
                           /\ pc' = [pc EXCEPT ![self] = "yyyyy_"]
                           /\ stack' = stack
                      ELSE /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                           /\ acks_' = [acks_ EXCEPT ![self] = Head(stack[self]).acks_]
                           /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                           /\ UNCHANGED << graph, tmp_acks >>
                /\ UNCHANGED << coo_mq, svr_mq, srz, acks, curr_pie, keyspace, 
                                next_txn_, next_pie, txn_id, par, partitions, 
                                n_pie, msg_in_, msg_out_, pre_accept_acks, 
                                accept_acks, committed, ballot, msg_in, 
                                msg_out, msg, keyspace_, dep, ya_dep, 
                                finished_map, asked_map, pie_map, last_w_tid, 
                                last_r_tid, scc, scc_set, scc_seq, curr_txn, 
                                curr_pie_, curr_op, txn_set, opset, next_txn, 
                                next_tid, anc, tmp_set, alogs >>

AggregateGraphForFastPath(self) == xxxxx_(self) \/ yyyyy_(self)

xxxxx(self) == /\ pc[self] = "xxxxx"
               /\ graph' = [graph EXCEPT ![self] = {}]
               /\ pc' = [pc EXCEPT ![self] = "yyyyy"]
               /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                               curr_pie, keyspace, next_txn_, next_pie, txn_id, 
                               par, partitions, n_pie, msg_in_, msg_out_, 
                               pre_accept_acks, accept_acks, committed, ballot, 
                               tmp_acks, msg_in, msg_out, msg, keyspace_, dep, 
                               ya_dep, finished_map, asked_map, pie_map, 
                               last_w_tid, last_r_tid, scc, scc_set, scc_seq, 
                               curr_txn, curr_pie_, curr_op, txn_set, opset, 
                               next_txn, next_tid, anc, tmp_set, alogs >>

yyyyy(self) == /\ pc[self] = "yyyyy"
               /\ IF acks[self] /= {}
                     THEN /\ \E a \in acks[self]:
                               /\ acks' = [acks EXCEPT ![self] = acks[self] \ {a}]
                               /\ tmp_acks' = [tmp_acks EXCEPT ![self] = a]
                          /\ pc' = [pc EXCEPT ![self] = "zzzzz"]
                          /\ stack' = stack
                     ELSE /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                          /\ acks' = [acks EXCEPT ![self] = Head(stack[self]).acks]
                          /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                          /\ UNCHANGED tmp_acks
               /\ UNCHANGED << coo_mq, svr_mq, srz, acks_, curr_pie, keyspace, 
                               next_txn_, next_pie, txn_id, par, partitions, 
                               n_pie, graph, msg_in_, msg_out_, 
                               pre_accept_acks, accept_acks, committed, ballot, 
                               msg_in, msg_out, msg, keyspace_, dep, ya_dep, 
                               finished_map, asked_map, pie_map, last_w_tid, 
                               last_r_tid, scc, scc_set, scc_seq, curr_txn, 
                               curr_pie_, curr_op, txn_set, opset, next_txn, 
                               next_tid, anc, tmp_set, alogs >>

zzzzz(self) == /\ pc[self] = "zzzzz"
               /\ IF tmp_acks[self] /= <<>>
                     THEN /\ \E a \in tmp_acks[self]:
                               /\ graph' = [graph EXCEPT ![self] = Aggregate(graph[self], a.dep)]
                               /\ tmp_acks' = [tmp_acks EXCEPT ![self] = Tail(tmp_acks[self])]
                          /\ pc' = [pc EXCEPT ![self] = "zzzzz"]
                     ELSE /\ pc' = [pc EXCEPT ![self] = "yyyyy"]
                          /\ UNCHANGED << graph, tmp_acks >>
               /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                               curr_pie, keyspace, next_txn_, next_pie, txn_id, 
                               par, partitions, n_pie, msg_in_, msg_out_, 
                               pre_accept_acks, accept_acks, committed, ballot, 
                               msg_in, msg_out, msg, keyspace_, dep, ya_dep, 
                               finished_map, asked_map, pie_map, last_w_tid, 
                               last_r_tid, scc, scc_set, scc_seq, curr_txn, 
                               curr_pie_, curr_op, txn_set, opset, next_txn, 
                               next_tid, anc, tmp_set, alogs >>

AggregateGraphForAccept(self) == xxxxx(self) \/ yyyyy(self) \/ zzzzz(self)

start_exe_pie(self) == /\ pc[self] = "start_exe_pie"
                       /\ opset' = [opset EXCEPT ![self] = curr_pie[self].opset]
                       /\ pc' = [pc EXCEPT ![self] = "pie_add_srz"]
                       /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                       curr_pie, keyspace, next_txn_, next_pie, 
                                       txn_id, par, partitions, n_pie, graph, 
                                       msg_in_, msg_out_, pre_accept_acks, 
                                       accept_acks, committed, ballot, 
                                       tmp_acks, msg_in, msg_out, msg, 
                                       keyspace_, dep, ya_dep, finished_map, 
                                       asked_map, pie_map, last_w_tid, 
                                       last_r_tid, scc, scc_set, scc_seq, 
                                       curr_txn, curr_pie_, curr_op, txn_set, 
                                       next_txn, next_tid, anc, tmp_set, alogs >>

pie_add_srz(self) == /\ pc[self] = "pie_add_srz"
                     /\ IF opset[self] /= {}
                           THEN /\ \E next_op \in opset[self]:
                                     /\ curr_op' = [curr_op EXCEPT ![self] = next_op]
                                     /\ opset' = [opset EXCEPT ![self] = opset[self] \ {next_op}]
                                /\ srz' = SrzAddNode(srz, curr_txn[self].tid)
                                /\ alogs' = [alogs EXCEPT ![self] = keyspace[self][curr_op'[self].key].alogs]
                                /\ pc' = [pc EXCEPT ![self] = "scan_alogs"]
                                /\ UNCHANGED << stack, curr_pie, keyspace >>
                           ELSE /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                                /\ curr_pie' = [curr_pie EXCEPT ![self] = Head(stack[self]).curr_pie]
                                /\ keyspace' = [keyspace EXCEPT ![self] = Head(stack[self]).keyspace]
                                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                                /\ UNCHANGED << srz, curr_op, opset, alogs >>
                     /\ UNCHANGED << coo_mq, svr_mq, acks_, acks, next_txn_, 
                                     next_pie, txn_id, par, partitions, n_pie, 
                                     graph, msg_in_, msg_out_, pre_accept_acks, 
                                     accept_acks, committed, ballot, tmp_acks, 
                                     msg_in, msg_out, msg, keyspace_, dep, 
                                     ya_dep, finished_map, asked_map, pie_map, 
                                     last_w_tid, last_r_tid, scc, scc_set, 
                                     scc_seq, curr_txn, curr_pie_, txn_set, 
                                     next_txn, next_tid, anc, tmp_set >>

scan_alogs(self) == /\ pc[self] = "scan_alogs"
                    /\ IF alogs[self] /= {}
                          THEN /\ \E next_access \in alogs[self]:
                                    /\ alogs' = [alogs EXCEPT ![self] = alogs[self] \ {next_access}]
                                    /\ IF \/ next_access.type /= curr_op[self].type
                                          \/ next_access.type = "w"
                                          THEN /\ srz' = SrzAddEdge(srz, next_access.tid, curr_txn[self].tid)
                                          ELSE /\ TRUE
                                               /\ srz' = srz
                                    /\ keyspace' = [keyspace EXCEPT ![self][curr_op[self].key].logs = @ \union {<<curr_txn[self].tid, curr_op[self].type>>}]
                               /\ pc' = [pc EXCEPT ![self] = "scan_alogs"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "pie_add_srz"]
                               /\ UNCHANGED << srz, keyspace, alogs >>
                    /\ UNCHANGED << coo_mq, svr_mq, stack, acks_, acks, 
                                    curr_pie, next_txn_, next_pie, txn_id, par, 
                                    partitions, n_pie, graph, msg_in_, 
                                    msg_out_, pre_accept_acks, accept_acks, 
                                    committed, ballot, tmp_acks, msg_in, 
                                    msg_out, msg, keyspace_, dep, ya_dep, 
                                    finished_map, asked_map, pie_map, 
                                    last_w_tid, last_r_tid, scc, scc_set, 
                                    scc_seq, curr_txn, curr_pie_, curr_op, 
                                    txn_set, opset, next_txn, next_tid, anc, 
                                    tmp_set >>

exe_pie(self) == start_exe_pie(self) \/ pie_add_srz(self)
                    \/ scan_alogs(self)

coo(self) == /\ pc[self] = "coo"
             /\ committed' = [committed EXCEPT ![self] = FALSE]
             /\ graph' = [graph EXCEPT ![self] = {}]
             /\ partitions' = [partitions EXCEPT ![self] = {}]
             /\ next_txn_' = [next_txn_ EXCEPT ![self] = TXN[self]]
             /\ id_counter' = id_counter + 1
             /\ txn_id' = [txn_id EXCEPT ![self] = id_counter]
             /\ n_pie' = [n_pie EXCEPT ![self] = Len(next_txn_'[self])]
             /\ pc' = [pc EXCEPT ![self] = "pre_accept"]
             /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, curr_pie, 
                             keyspace, next_pie, par, msg_in_, msg_out_, 
                             pre_accept_acks, accept_acks, ballot, tmp_acks, 
                             msg_in, msg_out, msg, keyspace_, dep, ya_dep, 
                             finished_map, asked_map, pie_map, last_w_tid, 
                             last_r_tid, scc, scc_set, scc_seq, curr_txn, 
                             curr_pie_, curr_op, txn_set, opset, next_txn, 
                             next_tid, anc, tmp_set, alogs >>

pre_accept(self) == /\ pc[self] = "pre_accept"
                    /\ IF Len(next_txn_[self]) > 0
                          THEN /\ next_pie' = [next_pie EXCEPT ![self] = Head(next_txn_[self])]
                               /\ next_txn_' = [next_txn_ EXCEPT ![self] = Tail(next_txn_[self])]
                               /\ par' = [par EXCEPT ![self] = Shard(next_pie'[self])]
                               /\ partitions' = [partitions EXCEPT ![self] = partitions[self] \union {par'[self]}]
                               /\ msg_out_' = [msg_out_ EXCEPT ![self] = [
                                                                            type |-> "pre_accept",
                                                                            source |-> self,
                                                                            tid |-> txn_id[self],
                                                                            opset |-> next_pie'[self].opset
                                                                         ]]
                               /\ svr_mq' = BroadcastMsg(svr_mq, par'[self], msg_out_'[self])
                               /\ pc' = [pc EXCEPT ![self] = "pre_accept"]
                               /\ UNCHANGED pre_accept_acks
                          ELSE /\ pre_accept_acks' = [pre_accept_acks EXCEPT ![self] = {}]
                               /\ pc' = [pc EXCEPT ![self] = "pre_accept_ack"]
                               /\ UNCHANGED << svr_mq, next_txn_, next_pie, 
                                               par, partitions, msg_out_ >>
                    /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, curr_pie, 
                                    keyspace, txn_id, n_pie, graph, msg_in_, 
                                    accept_acks, committed, ballot, tmp_acks, 
                                    msg_in, msg_out, msg, keyspace_, dep, 
                                    ya_dep, finished_map, asked_map, pie_map, 
                                    last_w_tid, last_r_tid, scc, scc_set, 
                                    scc_seq, curr_txn, curr_pie_, curr_op, 
                                    txn_set, opset, next_txn, next_tid, anc, 
                                    tmp_set, alogs >>

pre_accept_ack(self) == /\ pc[self] = "pre_accept_ack"
                        /\ IF Len(pre_accept_acks[self]) < N + 1
                              THEN /\ Len(coo_mq[self]) > 0
                                   /\ msg_in_' = [msg_in_ EXCEPT ![self] = Head(coo_mq[self])]
                                   /\ coo_mq' = [coo_mq EXCEPT ![self] = Tail(coo_mq[self])]
                                   /\ IF msg_in_'[self].type = "ack_pre_accept" /\ msg_in_'[self].tid = txn_id[self]
                                         THEN /\ par' = [par EXCEPT ![self] = ProcIdToPartitionId(msg_in_'[self].source)]
                                              /\ pre_accept_acks' = [pre_accept_acks EXCEPT ![self][par'[self]] = Append(pre_accept_acks[self][par'[self]], msg_in_'[self])]
                                              /\ IF FastPathPossible(pre_accept_acks'[self], partitions[self])
                                                    THEN /\ graph' = [graph EXCEPT ![self] = AggregateGraphForFastPath(pre_accept_acks'[self])]
                                                         /\ pc' = [pc EXCEPT ![self] = "commit_phase"]
                                                    ELSE /\ pc' = [pc EXCEPT ![self] = "slow_path_check"]
                                                         /\ graph' = graph
                                         ELSE /\ pc' = [pc EXCEPT ![self] = "pre_accept_ack"]
                                              /\ UNCHANGED << par, graph, 
                                                              pre_accept_acks >>
                                   /\ UNCHANGED ballot
                              ELSE /\ ballot' = [ballot EXCEPT ![self] = 0]
                                   /\ pc' = [pc EXCEPT ![self] = "accept_phase"]
                                   /\ UNCHANGED << coo_mq, par, graph, msg_in_, 
                                                   pre_accept_acks >>
                        /\ UNCHANGED << svr_mq, srz, stack, acks_, acks, 
                                        curr_pie, keyspace, next_txn_, 
                                        next_pie, txn_id, partitions, n_pie, 
                                        msg_out_, accept_acks, committed, 
                                        tmp_acks, msg_in, msg_out, msg, 
                                        keyspace_, dep, ya_dep, finished_map, 
                                        asked_map, pie_map, last_w_tid, 
                                        last_r_tid, scc, scc_set, scc_seq, 
                                        curr_txn, curr_pie_, curr_op, txn_set, 
                                        opset, next_txn, next_tid, anc, 
                                        tmp_set, alogs >>

slow_path_check(self) == /\ pc[self] = "slow_path_check"
                         /\ IF SlowPathPossible(pre_accept_acks[self], partitions[self])
                               THEN /\ /\ acks' = [acks EXCEPT ![self] = pre_accept_acks[self]]
                                       /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "AggregateGraphForAccept",
                                                                                pc        |->  "dsfdsfd",
                                                                                acks      |->  acks[self] ] >>
                                                                            \o stack[self]]
                                    /\ pc' = [pc EXCEPT ![self] = "xxxxx"]
                               ELSE /\ pc' = [pc EXCEPT ![self] = "pre_accept_ack"]
                                    /\ UNCHANGED << stack, acks >>
                         /\ UNCHANGED << coo_mq, svr_mq, srz, acks_, curr_pie, 
                                         keyspace, next_txn_, next_pie, txn_id, 
                                         par, partitions, n_pie, graph, 
                                         msg_in_, msg_out_, pre_accept_acks, 
                                         accept_acks, committed, ballot, 
                                         tmp_acks, msg_in, msg_out, msg, 
                                         keyspace_, dep, ya_dep, finished_map, 
                                         asked_map, pie_map, last_w_tid, 
                                         last_r_tid, scc, scc_set, scc_seq, 
                                         curr_txn, curr_pie_, curr_op, txn_set, 
                                         opset, next_txn, next_tid, anc, 
                                         tmp_set, alogs >>

dsfdsfd(self) == /\ pc[self] = "dsfdsfd"
                 /\ pc' = [pc EXCEPT ![self] = "accept_phase"]
                 /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                 curr_pie, keyspace, next_txn_, next_pie, 
                                 txn_id, par, partitions, n_pie, graph, 
                                 msg_in_, msg_out_, pre_accept_acks, 
                                 accept_acks, committed, ballot, tmp_acks, 
                                 msg_in, msg_out, msg, keyspace_, dep, ya_dep, 
                                 finished_map, asked_map, pie_map, last_w_tid, 
                                 last_r_tid, scc, scc_set, scc_seq, curr_txn, 
                                 curr_pie_, curr_op, txn_set, opset, next_txn, 
                                 next_tid, anc, tmp_set, alogs >>

accept_phase(self) == /\ pc[self] = "accept_phase"
                      /\ msg_out_' = [msg_out_ EXCEPT ![self] =                          [
                                                                  type |-> "accept",
                                                                  ballot |-> ballot[self],
                                                                  source |-> self,
                                                                  tid |-> txn_id[self],
                                                                  graph |-> graph[self]
                                                                ]]
                      /\ pc' = [pc EXCEPT ![self] = "broadcast_accept"]
                      /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                      curr_pie, keyspace, next_txn_, next_pie, 
                                      txn_id, par, partitions, n_pie, graph, 
                                      msg_in_, pre_accept_acks, accept_acks, 
                                      committed, ballot, tmp_acks, msg_in, 
                                      msg_out, msg, keyspace_, dep, ya_dep, 
                                      finished_map, asked_map, pie_map, 
                                      last_w_tid, last_r_tid, scc, scc_set, 
                                      scc_seq, curr_txn, curr_pie_, curr_op, 
                                      txn_set, opset, next_txn, next_tid, anc, 
                                      tmp_set, alogs >>

broadcast_accept(self) == /\ pc[self] = "broadcast_accept"
                          /\ svr_mq' = BroadcastMsgToMultiplePartitions(svr_mq, partitions[self], msg_out_[self])
                          /\ accept_acks' = [accept_acks EXCEPT ![self] = {}]
                          /\ pc' = [pc EXCEPT ![self] = "accept_ack"]
                          /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, 
                                          curr_pie, keyspace, next_txn_, 
                                          next_pie, txn_id, par, partitions, 
                                          n_pie, graph, msg_in_, msg_out_, 
                                          pre_accept_acks, committed, ballot, 
                                          tmp_acks, msg_in, msg_out, msg, 
                                          keyspace_, dep, ya_dep, finished_map, 
                                          asked_map, pie_map, last_w_tid, 
                                          last_r_tid, scc, scc_set, scc_seq, 
                                          curr_txn, curr_pie_, curr_op, 
                                          txn_set, opset, next_txn, next_tid, 
                                          anc, tmp_set, alogs >>

accept_ack(self) == /\ pc[self] = "accept_ack"
                    /\ Len(coo_mq[self]) > 0
                    /\ msg_in_' = [msg_in_ EXCEPT ![self] = Head(coo_mq[self])]
                    /\ coo_mq' = [coo_mq EXCEPT ![self] = Tail(coo_mq[self])]
                    /\ IF msg_in_'[self].type = "ack_accept" /\ msg_in_'[self].tid = txn_id[self] /\ msg_in_'[self].max_ballot = ballot[self]
                          THEN /\ par' = [par EXCEPT ![self] = ProcIdToPartitionId(msg_in_'[self].source)]
                               /\ accept_acks' = [accept_acks EXCEPT ![self][par'[self]] = Append(accept_acks[self][par'[self]], msg_in_'[self])]
                               /\ IF CommitReady(accept_acks'[self], partitions[self])
                                     THEN /\ pc' = [pc EXCEPT ![self] = "commit_phase"]
                                     ELSE /\ pc' = [pc EXCEPT ![self] = "accept_ack"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "accept_ack"]
                               /\ UNCHANGED << par, accept_acks >>
                    /\ UNCHANGED << svr_mq, srz, stack, acks_, acks, curr_pie, 
                                    keyspace, next_txn_, next_pie, txn_id, 
                                    partitions, n_pie, graph, msg_out_, 
                                    pre_accept_acks, committed, ballot, 
                                    tmp_acks, msg_in, msg_out, msg, keyspace_, 
                                    dep, ya_dep, finished_map, asked_map, 
                                    pie_map, last_w_tid, last_r_tid, scc, 
                                    scc_set, scc_seq, curr_txn, curr_pie_, 
                                    curr_op, txn_set, opset, next_txn, 
                                    next_tid, anc, tmp_set, alogs >>

commit_phase(self) == /\ pc[self] = "commit_phase"
                      /\ msg_out_' = [msg_out_ EXCEPT ![self] =                          [
                                                                  type |-> "commit",
                                                                  source |-> self,
                                                                  tid |-> txn_id[self]
                                                                ]]
                      /\ pc' = [pc EXCEPT ![self] = "broadcast_commit"]
                      /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                      curr_pie, keyspace, next_txn_, next_pie, 
                                      txn_id, par, partitions, n_pie, graph, 
                                      msg_in_, pre_accept_acks, accept_acks, 
                                      committed, ballot, tmp_acks, msg_in, 
                                      msg_out, msg, keyspace_, dep, ya_dep, 
                                      finished_map, asked_map, pie_map, 
                                      last_w_tid, last_r_tid, scc, scc_set, 
                                      scc_seq, curr_txn, curr_pie_, curr_op, 
                                      txn_set, opset, next_txn, next_tid, anc, 
                                      tmp_set, alogs >>

broadcast_commit(self) == /\ pc[self] = "broadcast_commit"
                          /\ svr_mq' = BroadcastMsgToMultiplePartitions(svr_mq, partitions[self], msg_out_[self])
                          /\ pc' = [pc EXCEPT ![self] = "commit_ack"]
                          /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, 
                                          curr_pie, keyspace, next_txn_, 
                                          next_pie, txn_id, par, partitions, 
                                          n_pie, graph, msg_in_, msg_out_, 
                                          pre_accept_acks, accept_acks, 
                                          committed, ballot, tmp_acks, msg_in, 
                                          msg_out, msg, keyspace_, dep, ya_dep, 
                                          finished_map, asked_map, pie_map, 
                                          last_w_tid, last_r_tid, scc, scc_set, 
                                          scc_seq, curr_txn, curr_pie_, 
                                          curr_op, txn_set, opset, next_txn, 
                                          next_tid, anc, tmp_set, alogs >>

commit_ack(self) == /\ pc[self] = "commit_ack"
                    /\ IF Len(coo_mq[self]) > 0
                          THEN /\ msg_in_' = [msg_in_ EXCEPT ![self] = Head(coo_mq[self])]
                               /\ coo_mq' = [coo_mq EXCEPT ![self] = Tail(coo_mq[self])]
                               /\ IF msg_in_'[self].type = "commit_ack" /\ msg_in_'[self].tid = txn_id[self]
                                     THEN /\ committed' = [committed EXCEPT ![self] = TRUE]
                                     ELSE /\ TRUE
                                          /\ UNCHANGED committed
                               /\ pc' = [pc EXCEPT ![self] = "commit_ack"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                               /\ UNCHANGED << coo_mq, msg_in_, committed >>
                    /\ UNCHANGED << svr_mq, srz, stack, acks_, acks, curr_pie, 
                                    keyspace, next_txn_, next_pie, txn_id, par, 
                                    partitions, n_pie, graph, msg_out_, 
                                    pre_accept_acks, accept_acks, ballot, 
                                    tmp_acks, msg_in, msg_out, msg, keyspace_, 
                                    dep, ya_dep, finished_map, asked_map, 
                                    pie_map, last_w_tid, last_r_tid, scc, 
                                    scc_set, scc_seq, curr_txn, curr_pie_, 
                                    curr_op, txn_set, opset, next_txn, 
                                    next_tid, anc, tmp_set, alogs >>

Coo(self) == coo(self) \/ pre_accept(self) \/ pre_accept_ack(self)
                \/ slow_path_check(self) \/ dsfdsfd(self)
                \/ accept_phase(self) \/ broadcast_accept(self)
                \/ accept_ack(self) \/ commit_phase(self)
                \/ broadcast_commit(self) \/ commit_ack(self)

svr_msg_loop(self) == /\ pc[self] = "svr_msg_loop"
                      /\ Len(svr_mq[self]) > 0
                      /\ msg' = [msg EXCEPT ![self] = Head(svr_mq[self])]
                      /\ svr_mq' = [svr_mq EXCEPT ![self] = Tail(svr_mq[self])]
                      /\ ya_dep' = [ya_dep EXCEPT ![self] = {}]
                      /\ curr_txn' = [curr_txn EXCEPT ![self] = FindOrCreateTxn(dep[self], msg'[self].tid)]
                      /\ IF msg'[self].type = "pre_accept" /\ curr_txn'[self].max_ballot = 0
                            THEN /\ curr_pie_' = [curr_pie_ EXCEPT ![self] = msg'[self].pie]
                                 /\ opset' = [opset EXCEPT ![self] = curr_pie_'[self].opset]
                                 /\ pc' = [pc EXCEPT ![self] = "pie_add_dep"]
                                 /\ UNCHANGED << msg_out, dep >>
                            ELSE /\ IF \/ msg'[self].type = "commit"
                                       \/ msg'[self].type = "ack_inquire"
                                       THEN /\ pc' = [pc EXCEPT ![self] = "aggregate_graph"]
                                            /\ UNCHANGED << msg_out, dep >>
                                       ELSE /\ IF msg'[self].type = "inquire"
                                                  THEN /\ GetStatus(dep[self], msg'[self].tid) >= COMMITTING
                                                       /\ pc' = [pc EXCEPT ![self] = "inquire_ack"]
                                                       /\ UNCHANGED << msg_out, 
                                                                       dep >>
                                                  ELSE /\ IF msg'[self].type = "prepare" /\ curr_txn'[self].max_ballot < msg'[self].ballot
                                                             THEN /\ dep' = [dep EXCEPT ![self] = UpdateBallot(dep[self], curr_txn'[self].tid, msg'[self].ballot, PREPARED)]
                                                                  /\ msg_out' = [msg_out EXCEPT ![self] = [type |-> "ack_prepare", src |-> self, tid |-> msg'[self].tid, ballot |-> msg'[self].ballot]]
                                                                  /\ pc' = [pc EXCEPT ![self] = "xxd"]
                                                             ELSE /\ IF msg'[self].type = "accept" /\ curr_txn'[self].max_ballot <= msg'[self].ballot
                                                                        THEN /\ dep' = [dep EXCEPT ![self] = UpdateBallot(dep[self], curr_txn'[self].tid, msg'[self].ballot, ACCEPTED)]
                                                                             /\ pc' = [pc EXCEPT ![self] = "dlskf"]
                                                                        ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                                                                             /\ dep' = dep
                                                                  /\ UNCHANGED msg_out
                                 /\ UNCHANGED << curr_pie_, opset >>
                      /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, 
                                      curr_pie, keyspace, next_txn_, next_pie, 
                                      txn_id, par, partitions, n_pie, graph, 
                                      msg_in_, msg_out_, pre_accept_acks, 
                                      accept_acks, committed, ballot, tmp_acks, 
                                      msg_in, keyspace_, finished_map, 
                                      asked_map, pie_map, last_w_tid, 
                                      last_r_tid, scc, scc_set, scc_seq, 
                                      curr_op, txn_set, next_txn, next_tid, 
                                      anc, tmp_set, alogs >>

pie_add_dep(self) == /\ pc[self] = "pie_add_dep"
                     /\ IF opset[self] /= {}
                           THEN /\ \E next_op \in opset[self]:
                                     /\ opset' = [opset EXCEPT ![self] = opset[self] \ {next_op}]
                                     /\ curr_op' = [curr_op EXCEPT ![self] = next_op]
                                /\ last_r_tid' = [last_r_tid EXCEPT ![self] = keyspace_[self][curr_op'[self].key].last_r_tid]
                                /\ last_w_tid' = [last_w_tid EXCEPT ![self] = keyspace_[self][curr_op'[self].key].last_w_tid]
                                /\ dep' = [dep EXCEPT ![self] = DepAddEdge(dep[self], <<last_w_tid'[self], curr_txn[self].tid, curr_pie_[self].iord>>)]
                                /\ IF curr_op'[self].type = "w"
                                      THEN /\ keyspace_' = [keyspace_ EXCEPT ![self][curr_op'[self].key].last_w_tid = curr_txn[self].tid]
                                           /\ pc' = [pc EXCEPT ![self] = "read_con"]
                                      ELSE /\ keyspace_' = [keyspace_ EXCEPT ![self][curr_op'[self].key].last_r_tid = curr_txn[self].tid]
                                           /\ pc' = [pc EXCEPT ![self] = "pie_add_dep"]
                           ELSE /\ pc' = [pc EXCEPT ![self] = "reply_dep"]
                                /\ UNCHANGED << keyspace_, dep, last_w_tid, 
                                                last_r_tid, curr_op, opset >>
                     /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                     curr_pie, keyspace, next_txn_, next_pie, 
                                     txn_id, par, partitions, n_pie, graph, 
                                     msg_in_, msg_out_, pre_accept_acks, 
                                     accept_acks, committed, ballot, tmp_acks, 
                                     msg_in, msg_out, msg, ya_dep, 
                                     finished_map, asked_map, pie_map, scc, 
                                     scc_set, scc_seq, curr_txn, curr_pie_, 
                                     txn_set, next_txn, next_tid, anc, tmp_set, 
                                     alogs >>

read_con(self) == /\ pc[self] = "read_con"
                  /\ dep' = [dep EXCEPT ![self] = DepAddEdge(dep[self], <<last_r_tid[self], curr_txn[self].tid, curr_pie_[self].iord>>)]
                  /\ pc' = [pc EXCEPT ![self] = "pie_add_dep"]
                  /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                  curr_pie, keyspace, next_txn_, next_pie, 
                                  txn_id, par, partitions, n_pie, graph, 
                                  msg_in_, msg_out_, pre_accept_acks, 
                                  accept_acks, committed, ballot, tmp_acks, 
                                  msg_in, msg_out, msg, keyspace_, ya_dep, 
                                  finished_map, asked_map, pie_map, last_w_tid, 
                                  last_r_tid, scc, scc_set, scc_seq, curr_txn, 
                                  curr_pie_, curr_op, txn_set, opset, next_txn, 
                                  next_tid, anc, tmp_set, alogs >>

reply_dep(self) == /\ pc[self] = "reply_dep"
                   /\ ya_dep' = [ya_dep EXCEPT ![self] = NearestDependenciesWithDowngrade(dep[self], curr_txn[self].tid)]
                   /\ msg_out' = [msg_out EXCEPT ![self] = [type |-> "ack_pre_accept", src |-> self, dep |-> ya_dep'[self]]]
                   /\ coo_mq' = [coo_mq EXCEPT ![msg[self].source] = Append(coo_mq[msg[self].src], msg_out'[self])]
                   /\ pc' = [pc EXCEPT ![self] = "Done"]
                   /\ UNCHANGED << svr_mq, srz, stack, acks_, acks, curr_pie, 
                                   keyspace, next_txn_, next_pie, txn_id, par, 
                                   partitions, n_pie, graph, msg_in_, msg_out_, 
                                   pre_accept_acks, accept_acks, committed, 
                                   ballot, tmp_acks, msg_in, msg, keyspace_, 
                                   dep, finished_map, asked_map, pie_map, 
                                   last_w_tid, last_r_tid, scc, scc_set, 
                                   scc_seq, curr_txn, curr_pie_, curr_op, 
                                   txn_set, opset, next_txn, next_tid, anc, 
                                   tmp_set, alogs >>

aggregate_graph(self) == /\ pc[self] = "aggregate_graph"
                         /\ dep' = [dep EXCEPT ![self] = Aggregate(dep[self], msg[self].dep)]
                         /\ txn_set' = [txn_set EXCEPT ![self] = AllAncestorsLowerThanCommitting(dep'[self], msg[self].tid)]
                         /\ pc' = [pc EXCEPT ![self] = "inquire_if_needed"]
                         /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, 
                                         acks, curr_pie, keyspace, next_txn_, 
                                         next_pie, txn_id, par, partitions, 
                                         n_pie, graph, msg_in_, msg_out_, 
                                         pre_accept_acks, accept_acks, 
                                         committed, ballot, tmp_acks, msg_in, 
                                         msg_out, msg, keyspace_, ya_dep, 
                                         finished_map, asked_map, pie_map, 
                                         last_w_tid, last_r_tid, scc, scc_set, 
                                         scc_seq, curr_txn, curr_pie_, curr_op, 
                                         opset, next_txn, next_tid, anc, 
                                         tmp_set, alogs >>

inquire_if_needed(self) == /\ pc[self] = "inquire_if_needed"
                           /\ IF txn_set[self] /= {}
                                 THEN /\ \E txn \in txn_set[self]:
                                           /\ txn_set' = [txn_set EXCEPT ![self] = txn_set[self] \ {txn}]
                                           /\ IF self \in txn.partitions
                                                 THEN /\ TRUE
                                                      /\ UNCHANGED << svr_mq, 
                                                                      msg_out >>
                                                 ELSE /\ \E dst \in txn.partitions:
                                                           /\ msg_out' = [msg_out EXCEPT ![self] = [type |-> "inquire", tid |-> txn.tid]]
                                                           /\ svr_mq' = BroadcastMsg(svr_mq, dst, msg_out'[self])
                                                           /\ TRUE
                                      /\ pc' = [pc EXCEPT ![self] = "inquire_if_needed"]
                                 ELSE /\ pc' = [pc EXCEPT ![self] = "choose_to_commit"]
                                      /\ UNCHANGED << svr_mq, msg_out, txn_set >>
                           /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, 
                                           curr_pie, keyspace, next_txn_, 
                                           next_pie, txn_id, par, partitions, 
                                           n_pie, graph, msg_in_, msg_out_, 
                                           pre_accept_acks, accept_acks, 
                                           committed, ballot, tmp_acks, msg_in, 
                                           msg, keyspace_, dep, ya_dep, 
                                           finished_map, asked_map, pie_map, 
                                           last_w_tid, last_r_tid, scc, 
                                           scc_set, scc_seq, curr_txn, 
                                           curr_pie_, curr_op, opset, next_txn, 
                                           next_tid, anc, tmp_set, alogs >>

choose_to_commit(self) == /\ pc[self] = "choose_to_commit"
                          /\ txn_set' = [txn_set EXCEPT ![self] = CommittingSubGraphWithAllAnestorsAtLeastCommitting(dep[self])]
                          /\ pc' = [pc EXCEPT ![self] = "ready_to_commit"]
                          /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, 
                                          acks, curr_pie, keyspace, next_txn_, 
                                          next_pie, txn_id, par, partitions, 
                                          n_pie, graph, msg_in_, msg_out_, 
                                          pre_accept_acks, accept_acks, 
                                          committed, ballot, tmp_acks, msg_in, 
                                          msg_out, msg, keyspace_, dep, ya_dep, 
                                          finished_map, asked_map, pie_map, 
                                          last_w_tid, last_r_tid, scc, scc_set, 
                                          scc_seq, curr_txn, curr_pie_, 
                                          curr_op, opset, next_txn, next_tid, 
                                          anc, tmp_set, alogs >>

ready_to_commit(self) == /\ pc[self] = "ready_to_commit"
                         /\ IF txn_set[self] /= {}
                               THEN /\ \E txn \in txn_set[self]:
                                         /\ scc' = [scc EXCEPT ![self] = StronglyConnectedComponent(dep[self], txn)]
                                         /\ txn_set' = [txn_set EXCEPT ![self] = txn_set[self] \ txn]
                                         /\ dep' = [dep EXCEPT ![self] = UpdateSubGraphStatus(dep[self], scc'[self], DECIDED)]
                                    /\ pc' = [pc EXCEPT ![self] = "ready_to_commit"]
                               ELSE /\ pc' = [pc EXCEPT ![self] = "find_execute"]
                                    /\ UNCHANGED << dep, scc, txn_set >>
                         /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, 
                                         acks, curr_pie, keyspace, next_txn_, 
                                         next_pie, txn_id, par, partitions, 
                                         n_pie, graph, msg_in_, msg_out_, 
                                         pre_accept_acks, accept_acks, 
                                         committed, ballot, tmp_acks, msg_in, 
                                         msg_out, msg, keyspace_, ya_dep, 
                                         finished_map, asked_map, pie_map, 
                                         last_w_tid, last_r_tid, scc_set, 
                                         scc_seq, curr_txn, curr_pie_, curr_op, 
                                         opset, next_txn, next_tid, anc, 
                                         tmp_set, alogs >>

find_execute(self) == /\ pc[self] = "find_execute"
                      /\ scc_set' = [scc_set EXCEPT ![self] = ToExecuteSCCSet(dep[self], self, finished_map[self])]
                      /\ IF scc_set'[self] /= {}
                            THEN /\ pc' = [pc EXCEPT ![self] = "next_execute"]
                            ELSE /\ TRUE
                                 /\ pc' = [pc EXCEPT ![self] = "Done"]
                      /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                      curr_pie, keyspace, next_txn_, next_pie, 
                                      txn_id, par, partitions, n_pie, graph, 
                                      msg_in_, msg_out_, pre_accept_acks, 
                                      accept_acks, committed, ballot, tmp_acks, 
                                      msg_in, msg_out, msg, keyspace_, dep, 
                                      ya_dep, finished_map, asked_map, pie_map, 
                                      last_w_tid, last_r_tid, scc, scc_seq, 
                                      curr_txn, curr_pie_, curr_op, txn_set, 
                                      opset, next_txn, next_tid, anc, tmp_set, 
                                      alogs >>

next_execute(self) == /\ pc[self] = "next_execute"
                      /\ IF scc_set[self] /= {}
                            THEN /\ \E next_scc \in scc_set[self]:
                                      /\ scc_set' = [scc_set EXCEPT ![self] = scc_set[self] \ {next_scc}]
                                      /\ scc' = [scc EXCEPT ![self] = next_scc]
                                 /\ pc' = [pc EXCEPT ![self] = "exe_scc"]
                            ELSE /\ pc' = [pc EXCEPT ![self] = "find_execute"]
                                 /\ UNCHANGED << scc, scc_set >>
                      /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                      curr_pie, keyspace, next_txn_, next_pie, 
                                      txn_id, par, partitions, n_pie, graph, 
                                      msg_in_, msg_out_, pre_accept_acks, 
                                      accept_acks, committed, ballot, tmp_acks, 
                                      msg_in, msg_out, msg, keyspace_, dep, 
                                      ya_dep, finished_map, asked_map, pie_map, 
                                      last_w_tid, last_r_tid, scc_seq, 
                                      curr_txn, curr_pie_, curr_op, txn_set, 
                                      opset, next_txn, next_tid, anc, tmp_set, 
                                      alogs >>

exe_scc(self) == /\ pc[self] = "exe_scc"
                 /\ IF scc[self].node /= {}
                       THEN /\ next_tid' = [next_tid EXCEPT ![self] = NextToExe(scc[self])]
                            /\ scc' = [scc EXCEPT ![self].node = scc[self].node \ {next_tid'[self]}]
                            /\ IF /\ IsInvolved(dep[self], next_tid'[self], self)
                                  /\ Unfinished(finished_map[self], next_tid'[self])
                                  THEN /\ pc' = [pc EXCEPT ![self] = "exe_all_deferred_pies"]
                                  ELSE /\ pc' = [pc EXCEPT ![self] = "exe_scc"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "next_execute"]
                            /\ UNCHANGED << scc, next_tid >>
                 /\ UNCHANGED << coo_mq, svr_mq, srz, stack, acks_, acks, 
                                 curr_pie, keyspace, next_txn_, next_pie, 
                                 txn_id, par, partitions, n_pie, graph, 
                                 msg_in_, msg_out_, pre_accept_acks, 
                                 accept_acks, committed, ballot, tmp_acks, 
                                 msg_in, msg_out, msg, keyspace_, dep, ya_dep, 
                                 finished_map, asked_map, pie_map, last_w_tid, 
                                 last_r_tid, scc_set, scc_seq, curr_txn, 
                                 curr_pie_, curr_op, txn_set, opset, next_txn, 
                                 anc, tmp_set, alogs >>

exe_all_deferred_pies(self) == /\ pc[self] = "exe_all_deferred_pies"
                               /\ IF pie_map[self][next_tid[self]] /= {}
                                     THEN /\ \E pie \in pie_map[self][next_tid[self]]:
                                               /\ next_pie' = [next_pie EXCEPT ![self] = pie]
                                               /\ pie_map' = [pie_map EXCEPT ![self][next_tid[self]] = pie_map[self][next_tid[self]] \ {next_pie'[self]}]
                                          /\ /\ curr_pie' = [curr_pie EXCEPT ![self] = next_pie'[self]]
                                             /\ keyspace' = [keyspace EXCEPT ![self] = keyspace_[self]]
                                             /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "exe_pie",
                                                                                      pc        |->  "exe_all_deferred_pies",
                                                                                      curr_pie  |->  curr_pie[self],
                                                                                      keyspace  |->  keyspace[self] ] >>
                                                                                  \o stack[self]]
                                          /\ pc' = [pc EXCEPT ![self] = "start_exe_pie"]
                                     ELSE /\ TRUE
                                          /\ pc' = [pc EXCEPT ![self] = "exe_scc"]
                                          /\ UNCHANGED << stack, curr_pie, 
                                                          keyspace, next_pie, 
                                                          pie_map >>
                               /\ UNCHANGED << coo_mq, svr_mq, srz, acks_, 
                                               acks, next_txn_, txn_id, par, 
                                               partitions, n_pie, graph, 
                                               msg_in_, msg_out_, 
                                               pre_accept_acks, accept_acks, 
                                               committed, ballot, tmp_acks, 
                                               msg_in, msg_out, msg, keyspace_, 
                                               dep, ya_dep, finished_map, 
                                               asked_map, last_w_tid, 
                                               last_r_tid, scc, scc_set, 
                                               scc_seq, curr_txn, curr_pie_, 
                                               curr_op, txn_set, opset, 
                                               next_txn, next_tid, anc, 
                                               tmp_set, alogs >>

inquire_ack(self) == /\ pc[self] = "inquire_ack"
                     /\ ya_dep' = [ya_dep EXCEPT ![self] = NearestDependenciesWithDowngrade(dep[self], msg[self].tid)]
                     /\ msg_out' = [msg_out EXCEPT ![self] = [type |-> "ack_inquire", src |-> self, tid |-> msg[self].tid, dep |-> ya_dep'[self]]]
                     /\ svr_mq' = [svr_mq EXCEPT ![msg[self].source] = Append(coo_mq[msg[self].source], msg_out'[self])]
                     /\ pc' = [pc EXCEPT ![self] = "Done"]
                     /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, curr_pie, 
                                     keyspace, next_txn_, next_pie, txn_id, 
                                     par, partitions, n_pie, graph, msg_in_, 
                                     msg_out_, pre_accept_acks, accept_acks, 
                                     committed, ballot, tmp_acks, msg_in, msg, 
                                     keyspace_, dep, finished_map, asked_map, 
                                     pie_map, last_w_tid, last_r_tid, scc, 
                                     scc_set, scc_seq, curr_txn, curr_pie_, 
                                     curr_op, txn_set, opset, next_txn, 
                                     next_tid, anc, tmp_set, alogs >>

xxd(self) == /\ pc[self] = "xxd"
             /\ svr_mq' = [svr_mq EXCEPT ![msg[self].source] = Append(coo_mq[msg[self].source], msg_out[self])]
             /\ pc' = [pc EXCEPT ![self] = "Done"]
             /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, curr_pie, 
                             keyspace, next_txn_, next_pie, txn_id, par, 
                             partitions, n_pie, graph, msg_in_, msg_out_, 
                             pre_accept_acks, accept_acks, committed, ballot, 
                             tmp_acks, msg_in, msg_out, msg, keyspace_, dep, 
                             ya_dep, finished_map, asked_map, pie_map, 
                             last_w_tid, last_r_tid, scc, scc_set, scc_seq, 
                             curr_txn, curr_pie_, curr_op, txn_set, opset, 
                             next_txn, next_tid, anc, tmp_set, alogs >>

dlskf(self) == /\ pc[self] = "dlskf"
               /\ dep' = [dep EXCEPT ![self] = Aggregate(dep[self], msg[self].dep)]
               /\ msg_out' = [msg_out EXCEPT ![self] = [type |-> "ack_accept", src |-> self, tid |-> msg[self].tid, ballot |-> msg[self].ballot]]
               /\ svr_mq' = [svr_mq EXCEPT ![msg[self].source] = Append(coo_mq[msg[self].source], msg_out'[self])]
               /\ pc' = [pc EXCEPT ![self] = "Done"]
               /\ UNCHANGED << coo_mq, srz, stack, acks_, acks, curr_pie, 
                               keyspace, next_txn_, next_pie, txn_id, par, 
                               partitions, n_pie, graph, msg_in_, msg_out_, 
                               pre_accept_acks, accept_acks, committed, ballot, 
                               tmp_acks, msg_in, msg, keyspace_, ya_dep, 
                               finished_map, asked_map, pie_map, last_w_tid, 
                               last_r_tid, scc, scc_set, scc_seq, curr_txn, 
                               curr_pie_, curr_op, txn_set, opset, next_txn, 
                               next_tid, anc, tmp_set, alogs >>

Svr(self) == svr_msg_loop(self) \/ pie_add_dep(self) \/ read_con(self)
                \/ reply_dep(self) \/ aggregate_graph(self)
                \/ inquire_if_needed(self) \/ choose_to_commit(self)
                \/ ready_to_commit(self) \/ find_execute(self)
                \/ next_execute(self) \/ exe_scc(self)
                \/ exe_all_deferred_pies(self) \/ inquire_ack(self)
                \/ xxd(self) \/ dlskf(self)

Next == (\E self \in ProcSet:  \/ AggregateGraphForFastPath(self)
                               \/ AggregateGraphForAccept(self)
                               \/ exe_pie(self))
           \/ (\E self \in 1 .. M: Coo(self))
           \/ (\E self \in M+1 .. M+N*X: Svr(self))
           \/ (* Disjunct to prevent deadlock on termination *)
              ((\A self \in ProcSet: pc[self] = "Done") /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

-----------------------------------------------------------------------------

Serializability == []Acyclic(srz)

THEOREM Spec => Serializability

=============================================================================
\* Modification History
\* Last modified Wed Sep 07 04:08:35 EDT 2016 by shuai
\* Last modified Thu Dec 25 23:34:46 CST 2014 by Shuai
\* Created Mon Dec 15 15:44:26 CST 2014 by Shuai
