#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../scheduler.h"

namespace janus {
class Command;
class CmdData;

#define INVALID_PARID  ((parid_t)-1)

struct FpgaRaftData {
  ballot_t max_ballot_seen_ = 0;
  ballot_t max_ballot_accepted_ = 0;
  shared_ptr<Marshallable> accepted_cmd_{nullptr};
  shared_ptr<Marshallable> committed_cmd_{nullptr};

  ballot_t term;
  slotid_t idx ;
  shared_ptr<Marshallable> log_{nullptr};
};

class FpgaRaftServer : public TxLogServer {
 private:
   std::vector<std::thread> timer_threads_ = {};
  void timer_thread(bool *vote) ;
  Timer *timer_;
  bool stop_ = false ;
  parid_t vote_for_ = INVALID_PARID ;
  bool end_ = false ;
  bool init_ = false ;
  bool is_leader_ = false ;
  slotid_t snapidx_ = 0 ;
  ballot_t snapterm_ = 0 ;
  int32_t wait_int_ = 1 * 1000 * 1000 ; // 1s

  void RequestVote() ;
  void doVote(const slotid_t& lst_log_idx,
                            const ballot_t& lst_log_term,
                            const parid_t& can_id,
                            const ballot_t& can_term,
                            ballot_t *reply_term,
                            bool_t *vote_granted,
                            bool_t vote,
                            const function<void()> &cb) {
        *vote_granted = vote ;
        *reply_term = currentTerm ;
        if( can_term > currentTerm)
        {
            is_leader_ = false ;
            currentTerm = can_term ;
        }

        if(vote)
        {
            Log_debug("vote for can_id %d canterm %d curterm %d isleader %d", can_id, can_term, currentTerm, is_leader_);
            vote_for_ = can_id ;
            //reset timeout
            timer_->start() ;
        }
        n_vote_++ ;
        cb() ;
    }

  void resetTimer()
  {
      timer_->start() ;
  }

  int32_t randDuration() 
  {
    return 2 + RandomGenerator::rand(0, 4) ;
  }
  
 public:
  slotid_t min_active_slot_ = 0; // anything before (lt) this slot is freed
  slotid_t max_executed_slot_ = 0;
  slotid_t max_committed_slot_ = 0;
  map<slotid_t, shared_ptr<FpgaRaftData>> logs_{};
  int n_vote_ = 0;
  int n_prepare_ = 0;
  int n_accept_ = 0;
  int n_commit_ = 0;

  /* NOTE: I think I should move these to the FpgaRaftData class */
  /* TODO: talk to Shuai about it */
  uint64_t lastLogIndex = 0;
  uint64_t currentTerm = 0;
  uint64_t commitIndex = 0;
  uint64_t executeIndex = 0;
//  map<slotid_t, shared_ptr<FpgaRaftData>> raft_logs_{};
  vector<shared_ptr<FpgaRaftData>> raft_logs_{};

  void StartTimer() ;

  bool IsLeader()
  {
    return is_leader_ ;
  }

  shared_ptr<FpgaRaftData> GetInstance(slotid_t id) {
    verify(id >= min_active_slot_);
    auto& sp_instance = logs_[id];
    if(!sp_instance)
      sp_instance = std::make_shared<FpgaRaftData>();
    return sp_instance;
  }

  shared_ptr<FpgaRaftData> GetFpgaRaftInstance(slotid_t id) {
    if ( id <= raft_logs_.size() )
    {
        return raft_logs_[id-1] ;
    }
    auto sp_instance = std::make_shared<FpgaRaftData>();
    raft_logs_.push_back(sp_instance) ;
    return sp_instance;
  }

  FpgaRaftServer(Frame *frame) ;
  ~FpgaRaftServer() ;

  void OnVote(const slotid_t& lst_log_idx,
                      const ballot_t& lst_log_term,
                      const parid_t& can_id,
                      const ballot_t& can_term,
                      ballot_t *reply_term,
                      bool_t *vote_granted,
                      const function<void()> &cb) ;

  void OnAppendEntries(const slotid_t slot_id,
                       const ballot_t ballot,
                       const uint64_t leaderCurrentTerm,
                       const uint64_t leaderPrevLogIndex,
                       const uint64_t leaderPrevLogTerm,
                       const uint64_t leaderCommitIndex,
                       shared_ptr<Marshallable> &cmd,
                       uint64_t *followerAppendOK,
                       uint64_t *followerCurrentTerm,
                       uint64_t *followerLastLogIndex,
                       const function<void()> &cb);

  void OnCommit(const slotid_t slot_id,
                const ballot_t ballot,
                shared_ptr<Marshallable> &cmd);

  void OnForward(shared_ptr<Marshallable> &cmd, 
                          uint64_t *cmt_idx,
                          const function<void()> &cb) ;

  void SpCommit(const uint64_t cmt_idx) ;

  virtual bool HandleConflicts(Tx& dtxn,
                               innid_t inn_id,
                               vector<string>& conflicts) {
    verify(0);
  };
};
} // namespace janus
