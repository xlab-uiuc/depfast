
#include "commo.h"
#include "../rcc/graph.h"
#include "../rcc/graph_marshaler.h"
#include "../command.h"
#include "../procedure.h"
#include "../command_marshaler.h"
#include "../rcc_rpc.h"

namespace janus {

FpgaRaftCommo::FpgaRaftCommo(PollMgr* poll) : Communicator(poll) {
//  verify(poll != nullptr);
}

shared_ptr<FpgaRaftForwardQuorumEvent> FpgaRaftCommo::SendForward(parid_t par_id, 
                                            parid_t self_id, shared_ptr<Marshallable> cmd)
{
    int n = Config::GetConfig()->GetPartitionSize(par_id);
    auto e = Reactor::CreateSpEvent<FpgaRaftForwardQuorumEvent>(1,1);
    parid_t fid = (self_id + 1 ) % n ;
    if (fid != self_id + 1 )
    {
      // sleep for 2 seconds cos no leader
      int32_t timeout = 2*1000*1000 ;
      auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(timeout);
      sp_e->Wait(timeout);    
    }
    auto proxies = rpc_par_proxies_[par_id];
    WAN_WAIT;
    auto proxy = (FpgaRaftProxy*) proxies[fid].second ;
    FutureAttr fuattr;
    fuattr.callback = [e](Future* fu) {
      uint64_t cmt_idx = 0;
      fu->get_reply() >> cmt_idx;
      e->FeedResponse(cmt_idx);
    };    
    MarshallDeputy md(cmd);
    auto f = proxy->async_Forward(md, fuattr);
    Future::safe_release(f);
    return e;
}

void FpgaRaftCommo::BroadcastHeartbeat(parid_t par_id,
																			 uint64_t logIndex) {
  //std::lock_guard<std::recursive_mutex> lock(mtx_);
	//Log_info("heartbeat for log index: %d", logIndex);
	DepId di = { "hb", -1 };
  auto proxies = rpc_par_proxies_[par_id];
  vector<Future*> fus;
	WAN_WAIT;
  for (auto& p : proxies) {
    if (p.first == this->loc_id_)
        continue;
		auto follower_id = p.first;
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    
		fuattr.callback = [this, follower_id] (Future* fu) {
			uint64_t index = 0;
			
			fu->get_reply() >> index;
			this->matchedIndex[follower_id] = std::max(index, this->matchedIndex[follower_id]);
    };

    auto f = proxy->async_Heartbeat(logIndex, di, fuattr);
    Future::safe_release(f);
  }
}

void FpgaRaftCommo::SendHeartbeat(parid_t par_id,
																	siteid_t site_id,
																  uint64_t logIndex) {
  //std::lock_guard<std::recursive_mutex> lock(mtx_);
  auto proxies = rpc_par_proxies_[par_id];
  vector<Future*> fus;
	WAN_WAIT;
  for (auto& p : proxies) {
    if (p.first != site_id)
        continue;
		auto follower_id = p.first;
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [](Future* fu) {};
    
		DepId di = { "dep",  -1 };
		
		//Log_info("heartbeat2 for log index: %d", logIndex);
    auto f = proxy->async_Heartbeat(logIndex, di, fuattr);
    Future::safe_release(f);
  }
}

void FpgaRaftCommo::SendAppendEntriesAgain(siteid_t site_id,
																					 parid_t par_id,
																					 slotid_t slot_id,
																					 ballot_t ballot,
																					 bool isLeader,
																					 uint64_t currentTerm,
																					 uint64_t prevLogIndex,
																					 uint64_t prevLogTerm,
																					 uint64_t commitIndex,
																					 shared_ptr<Marshallable> cmd) {
  //std::lock_guard<std::recursive_mutex> lock(mtx_);
  auto proxies = rpc_par_proxies_[par_id];
  vector<Future*> fus;
	WAN_WAIT;
  for (auto& p : proxies) {
    if (p.first != site_id)
        continue;
		auto follower_id = p.first;
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [](Future* fu) {};

		MarshallDeputy md(cmd);
		verify(md.sp_data_ != nullptr);

		DepId di = { "dep", -1 };

		Log_info("heartbeat2 for log index: %d", prevLogIndex);
    auto f = proxy->async_AppendEntries(slot_id,
                                        ballot,
                                        currentTerm,
                                        prevLogIndex,
                                        prevLogTerm,
                                        commitIndex,
																				di,
                                        md, 
                                        fuattr);
    Future::safe_release(f);
  }

}

shared_ptr<FpgaRaftAppendQuorumEvent>
FpgaRaftCommo::BroadcastAppendEntries(parid_t par_id,
                                      slotid_t slot_id,
																			i64 dep_id,
                                      ballot_t ballot,
                                      bool isLeader,
                                      uint64_t currentTerm,
                                      uint64_t prevLogIndex,
                                      uint64_t prevLogTerm,
                                      uint64_t commitIndex,
                                      shared_ptr<Marshallable> cmd) {
  //std::lock_guard<std::recursive_mutex> lock(mtx_);
  int n = Config::GetConfig()->GetPartitionSize(par_id);
  auto proxies = rpc_par_proxies_[par_id];
	
	unordered_set<std::string> ip_addrs {};
	for (auto& p : proxies) {
		auto id = p.first;
    auto proxy = (FpgaRaftProxy*) p.second;

		auto cli_it = rpc_clients_.find(id);
		std::string ip = "";
		if (cli_it != rpc_clients_.end()) {
			ip = cli_it->second->host();
			//cli = cli_it->second;
		}
		ip_addrs.insert(ip);
		//clients.push_back(cli);
	}
  
	DepId di = { "dep", dep_id };
	auto e = Reactor::CreateSpEvent<FpgaRaftAppendQuorumEvent>(n, n/2 + 1, di, ip_addrs);
	//auto e = Reactor::CreateSpEvent<FpgaRaftAppendQuorumEvent>(n, n, -1, ip_addrs);

	std::vector<std::shared_ptr<rrr::Client>> clients;

  vector<Future*> fus;
  WAN_WAIT;

	e->recordHistory(ip_addrs);
	//e->clients_ = clients;
  
	for (auto& p : proxies) {	
		auto follower_id = p.first;
    auto proxy = (FpgaRaftProxy*) p.second;
    
		auto cli_it = rpc_clients_.find(follower_id);
		std::string ip = "";
		if (cli_it != rpc_clients_.end()) {
			ip = cli_it->second->host();
		}

		if (p.first == this->loc_id_) {
        // fix the 1c1s1p bug
        e->FeedResponse(true, prevLogIndex + 1, ip);
        continue;
    }
    FutureAttr fuattr;
		
		struct timespec begin;
		clock_gettime(CLOCK_MONOTONIC, &begin);

    fuattr.callback = [this, e, isLeader, currentTerm, follower_id, n, ip, begin] (Future* fu) {
			//Log_info("use_count: %d for %s and %d", e.use_count(), ip.c_str(), currentTerm);
      uint64_t accept = 0;
      uint64_t term = 0;
      uint64_t index = 0;
			
			fu->get_reply() >> accept;
      fu->get_reply() >> term;
      fu->get_reply() >> index;
			
			struct timespec end;
			//clock_gettime(CLOCK_MONOTONIC, &begin);
			//this->outbound--;
			//Log_info("reply from server: %s and is_ready: %d", ip.c_str(), e->IsReady());
			clock_gettime(CLOCK_MONOTONIC, &end);
			//Log_info("time of reply on server %d: %ld", follower_id, (end.tv_sec - begin.tv_sec)*1000000000 + end.tv_nsec - begin.tv_nsec);
			
      bool y = ((accept == 1) && (isLeader) && (currentTerm == term));
      e->FeedResponse(y, index, ip);
			//Log_info("use_count2: %d for %s and %d", e.use_count(), ip.c_str(), currentTerm);
    };	
		/*fuattr.delete_callback = [this, e] (Future* fu) {
			//Log_info("use_count final");
		};*/

    MarshallDeputy md(cmd);
		verify(md.sp_data_ != nullptr);
		//outbound++;
    auto f = proxy->async_AppendEntries(slot_id,
                                        ballot,
                                        currentTerm,
                                        prevLogIndex,
                                        prevLogTerm,
                                        commitIndex,
																				di,
                                        md, 
                                        fuattr);
    Future::safe_release(f);
  }

	verify(!e->IsReady());
  return e;
}

void FpgaRaftCommo::BroadcastAppendEntries(parid_t par_id,
                                           slotid_t slot_id,
																					 i64 dep_id,
                                           ballot_t ballot,
                                           uint64_t currentTerm,
                                           uint64_t prevLogIndex,
                                           uint64_t prevLogTerm,
                                           uint64_t commitIndex,
                                           shared_ptr<Marshallable> cmd,
                                           const function<void(Future*)>& cb) {
  verify(0); // deprecated function
  auto proxies = rpc_par_proxies_[par_id];
  vector<Future*> fus;
  for (auto& p : proxies) {
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = cb;
    MarshallDeputy md(cmd);
		DepId di = { "dep", dep_id };
    auto f = proxy->async_AppendEntries(slot_id, 
                                        ballot, 
                                        currentTerm,
                                        prevLogIndex,
                                        prevLogTerm,
                                        commitIndex,
																				di,
                                        md, 
                                        fuattr);
    Future::safe_release(f);
  }
//  verify(0);
}

void FpgaRaftCommo::BroadcastDecide(const parid_t par_id,
                                      const slotid_t slot_id,
																			const i64 dep_id,
                                      const ballot_t ballot,
                                      const shared_ptr<Marshallable> cmd) {
  //std::lock_guard<std::recursive_mutex> lock(mtx_);
  auto proxies = rpc_par_proxies_[par_id];
  vector<Future*> fus;
  for (auto& p : proxies) {
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [](Future* fu) {};
    MarshallDeputy md(cmd);
		DepId di = { "dep", dep_id };
    auto f = proxy->async_Decide(slot_id, ballot, di, md, fuattr);
    Future::safe_release(f);
  }
}

void FpgaRaftCommo::BroadcastVote(parid_t par_id,
                                        slotid_t lst_log_idx,
                                        ballot_t lst_log_term,
                                        parid_t self_id,
                                        ballot_t cur_term,
                                       const function<void(Future*)>& cb) {
  verify(0); // deprecated function
  auto proxies = rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = cb;
    Future::safe_release(proxy->async_Vote(lst_log_idx, lst_log_term, self_id,cur_term, fuattr));
  }
}

shared_ptr<FpgaRaftVoteQuorumEvent>
FpgaRaftCommo::BroadcastVote(parid_t par_id,
                                    slotid_t lst_log_idx,
                                    ballot_t lst_log_term,
                                    parid_t self_id,
                                    ballot_t cur_term ) {
  int n = Config::GetConfig()->GetPartitionSize(par_id);
  auto e = Reactor::CreateSpEvent<FpgaRaftVoteQuorumEvent>(n, n/2);
  auto proxies = rpc_par_proxies_[par_id];
  WAN_WAIT;
  for (auto& p : proxies) {
    if (p.first == this->loc_id_)
        continue;
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [e](Future* fu) {
      ballot_t term = 0;
      bool_t vote = false ;
      fu->get_reply() >> term;
      fu->get_reply() >> vote ;
      e->FeedResponse(vote, term);
      // TODO add max accepted value.
    };
    Future::safe_release(proxy->async_Vote(lst_log_idx, lst_log_term, self_id, cur_term, fuattr));
  }
  return e;
}

void FpgaRaftCommo::BroadcastVote2FPGA(parid_t par_id,
                                        slotid_t lst_log_idx,
                                        ballot_t lst_log_term,
                                        parid_t self_id,
                                        ballot_t cur_term,
                                       const function<void(Future*)>& cb) {
  verify(0); // deprecated function
  auto proxies = rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = cb;
    Future::safe_release(proxy->async_Vote(lst_log_idx, lst_log_term, self_id,cur_term, fuattr));
  }
}

shared_ptr<FpgaRaftVote2FPGAQuorumEvent>
FpgaRaftCommo::BroadcastVote2FPGA(parid_t par_id,
                                    slotid_t lst_log_idx,
                                    ballot_t lst_log_term,
                                    parid_t self_id,
                                    ballot_t cur_term ) {
  int n = Config::GetConfig()->GetPartitionSize(par_id);
  auto e = Reactor::CreateSpEvent<FpgaRaftVote2FPGAQuorumEvent>(n, n/2);
  auto proxies = rpc_par_proxies_[par_id];
  WAN_WAIT;
  for (auto& p : proxies) {
    if (p.first == this->loc_id_)
        continue;
    auto proxy = (FpgaRaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [e](Future* fu) {
      ballot_t term = 0;
      bool_t vote = false ;
      fu->get_reply() >> term;
      fu->get_reply() >> vote ;
      e->FeedResponse(vote, term);
    };
    Future::safe_release(proxy->async_Vote(lst_log_idx, lst_log_term, self_id, cur_term, fuattr));
  }
  return e;
}



} // namespace janus
