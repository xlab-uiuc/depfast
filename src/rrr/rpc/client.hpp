#pragma once

#include <unordered_map>
#include <chrono>

#include "misc/marshal.hpp"
#include "reactor/epoll_wrapper.h"
#include "reactor/reactor.h"

namespace rrr {

class Future;
class Client;

struct FutureAttr {
    FutureAttr(const std::function<void(Future*)>& cb = std::function<void(Future*)>()) : callback(cb) { }

    // callback should be fast, otherwise it hurts rpc performance
    std::function<void(Future*)> callback;
		std::function<void(Future*)> delete_callback;
};

class Future: public RefCounted {
    friend class Client;

    i64 xid_;
    i32 error_code_;

    FutureAttr attr_;
    Marshal reply_;

    bool ready_;
    bool timed_out_;
    pthread_cond_t ready_cond_;
    pthread_mutex_t ready_m_;

    void notify_ready();
    void notify_delete();

protected:

    // protected destructor as required by RefCounted.
    ~Future() {
        Pthread_mutex_destroy(&ready_m_);
        Pthread_cond_destroy(&ready_cond_);
    }

public:

    Future(i64 xid, const FutureAttr& attr = FutureAttr())
            : xid_(xid), error_code_(0), attr_(attr), ready_(false), timed_out_(false) {
        Pthread_mutex_init(&ready_m_, nullptr);
        Pthread_cond_init(&ready_cond_, nullptr);
    }

    bool ready() {
        Pthread_mutex_lock(&ready_m_);
        bool r = ready_;
        Pthread_mutex_unlock(&ready_m_);
        return r;
    }

    // wait till reply done
    void wait();

    void timed_wait(double sec);

    Marshal& get_reply() {
        wait();
        return reply_;
    }

    i32 get_error_code() {
        wait();
        return error_code_;
    }

    static inline void safe_release(Future* fu) {
        if (fu != nullptr) {
            fu->release();
        }
    }
};

class FutureGroup {
private:
    std::vector<Future*> futures_;

public:
    void add(Future* f) {
        if (f == nullptr) {
            Log_error("Invalid Future object passed to FutureGroup!");
            return;
        }
        futures_.push_back(f);
    }

    void wait_all() {
        for (auto& f : futures_) {
            f->wait();
        }
    }

    ~FutureGroup() {
        wait_all();
        for (auto& f : futures_) {
            f->release();
        }
    }
};

 class Client: public Pollable {
    Marshal in_, out_;

    /**
     * NOT a refcopy! This is intended to avoid circular reference, which prevents everything from being released correctly.
     */
    PollMgr* pollmgr_;
    
    std::string host_;
    int sock_;
		long times[100];
		long total_time;
		int index = 0;
		int count_ = 0;
		int begin_time = 0;
		int pending_begin_time = 0;
		bool first_print = true;
    enum {
        NEW, CONNECTED, CLOSED
    } status_;
		
		uint64_t packets;
		bool clean;
    Marshal::bookmark* bmark_;

    Counter xid_counter_;
    std::unordered_map<i64, Future*> pending_fu_;
		std::unordered_map<i64, struct timespec> rpc_starts;

    SpinLock pending_fu_l_;
		SpinLock read_l_;
    SpinLock out_l_;

    // reentrant, could be called multiple times before releasing
    void close();

    void invalidate_pending_futures();


public:
	 bool client_;
	 long time_;
	 int count;
	 int out_count;
	 int read_count;
	 int write_count;
	 i32 rpc_id_;

   virtual ~Client() {
     invalidate_pending_futures();
   }

   Client(PollMgr* pollmgr): pollmgr_(pollmgr), sock_(-1), status_(NEW), bmark_(nullptr) { }

    /**
     * Start a new request. Must be paired with end_request(), even if nullptr returned.
     *
     * The request packet format is: <size> <xid> <rpc_id> <arg1> <arg2> ... <argN>
     */
    Future* begin_request(i32 rpc_id, const FutureAttr& attr = FutureAttr());

    void end_request();

    template<class T>
    Client& operator <<(const T& v) {
	//auto start = std::chrono::steady_clock::now();
				int before_size = out_.content_size();
        if (status_ == CONNECTED) {
            this->out_ << v;
        }
				int after_size = out_.content_size();
				out_count += (after_size - before_size);
	//auto end = std::chrono::steady_clock::now();
	//auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end-start).count();
	//Log_info("Time of << is: %d", duration);
        return *this;
    }

    // NOTE: this function is used *internally* by Python extension
    Client& operator <<(Marshal& m) {
        if (status_ == CONNECTED) {
            this->out_.read_from_marshal(m, m.content_size());
        }
        return *this;
    }

		void set_valid(bool valid);
    int connect(const char* addr, bool client = true);

    void close_and_release() {
        close();
    }

    int fd() {
        return sock_;
    }

		std::string host() {
			return host_;
		}

    int poll_mode();
    size_t content_size();
    //void handle_read_one();
    bool handle_read_two();
    bool handle_read();
    void handle_write();
    void handle_error();
		void handle_free();

};

class ClientPool: public NoCopy {
    rrr::Rand rand_;

    // refcopy
    rrr::PollMgr* pollmgr_;

    // guard cache_
    SpinLock l_;
    std::map<std::string, rrr::Client**> cache_;
    int parallel_connections_;

public:

    ClientPool(rrr::PollMgr* pollmgr = nullptr, int parallel_connections = 1);
    ~ClientPool();

    // return cached client connection
    // on error, return nullptr
    rrr::Client* get_client(const std::string& addr);

};

}
