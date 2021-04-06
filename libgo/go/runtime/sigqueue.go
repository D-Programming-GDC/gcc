// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// This file implements runtime support for signal handling.
//
// Most synchronization primitives are not available from
// the signal handler (it cannot block, allocate memory, or use locks)
// so the handler communicates with a processing goroutine
// via struct sig, below.
//
// sigsend is called by the signal handler to queue a new signal.
// signal_recv is called by the Go program to receive a newly queued signal.
// Synchronization between sigsend and signal_recv is based on the sig.state
// variable. It can be in 4 states: sigIdle, sigReceiving, sigSending and sigFixup.
// sigReceiving means that signal_recv is blocked on sig.Note and there are no
// new pending signals.
// sigSending means that sig.mask *may* contain new pending signals,
// signal_recv can't be blocked in this state.
// sigIdle means that there are no new pending signals and signal_recv is not blocked.
// sigFixup is a transient state that can only exist as a short
// transition from sigReceiving and then on to sigIdle: it is
// used to ensure the AllThreadsSyscall()'s mDoFixup() operation
// occurs on the sleeping m, waiting to receive a signal.
// Transitions between states are done atomically with CAS.
// When signal_recv is unblocked, it resets sig.Note and rechecks sig.mask.
// If several sigsends and signal_recv execute concurrently, it can lead to
// unnecessary rechecks of sig.mask, but it cannot lead to missed signals
// nor deadlocks.

// +build !plan9

package runtime

import (
	"runtime/internal/atomic"
	_ "unsafe" // for go:linkname
)

// sig handles communication between the signal handler and os/signal.
// Other than the inuse and recv fields, the fields are accessed atomically.
//
// The wanted and ignored fields are only written by one goroutine at
// a time; access is controlled by the handlers Mutex in os/signal.
// The fields are only read by that one goroutine and by the signal handler.
// We access them atomically to minimize the race between setting them
// in the goroutine calling os/signal and the signal handler,
// which may be running in a different thread. That race is unavoidable,
// as there is no connection between handling a signal and receiving one,
// but atomic instructions should minimize it.
var sig struct {
	note       note
	mask       [(_NSIG + 31) / 32]uint32
	wanted     [(_NSIG + 31) / 32]uint32
	ignored    [(_NSIG + 31) / 32]uint32
	recv       [(_NSIG + 31) / 32]uint32
	state      uint32
	delivering uint32
	inuse      bool
}

const (
	sigIdle = iota
	sigReceiving
	sigSending
	sigFixup
)

// sigsend delivers a signal from sighandler to the internal signal delivery queue.
// It reports whether the signal was sent. If not, the caller typically crashes the program.
// It runs from the signal handler, so it's limited in what it can do.
func sigsend(s uint32) bool {
	bit := uint32(1) << uint(s&31)
	if !sig.inuse || s >= uint32(32*len(sig.wanted)) {
		return false
	}

	atomic.Xadd(&sig.delivering, 1)
	// We are running in the signal handler; defer is not available.

	if w := atomic.Load(&sig.wanted[s/32]); w&bit == 0 {
		atomic.Xadd(&sig.delivering, -1)
		return false
	}

	// Add signal to outgoing queue.
	for {
		mask := sig.mask[s/32]
		if mask&bit != 0 {
			atomic.Xadd(&sig.delivering, -1)
			return true // signal already in queue
		}
		if atomic.Cas(&sig.mask[s/32], mask, mask|bit) {
			break
		}
	}

	// Notify receiver that queue has new bit.
Send:
	for {
		switch atomic.Load(&sig.state) {
		default:
			throw("sigsend: inconsistent state")
		case sigIdle:
			if atomic.Cas(&sig.state, sigIdle, sigSending) {
				break Send
			}
		case sigSending:
			// notification already pending
			break Send
		case sigReceiving:
			if atomic.Cas(&sig.state, sigReceiving, sigIdle) {
				if GOOS == "darwin" || GOOS == "ios" {
					sigNoteWakeup(&sig.note)
					break Send
				}
				notewakeup(&sig.note)
				break Send
			}
		case sigFixup:
			// nothing to do - we need to wait for sigIdle.
			osyield()
		}
	}

	atomic.Xadd(&sig.delivering, -1)
	return true
}

// sigRecvPrepareForFixup is used to temporarily wake up the
// signal_recv() running thread while it is blocked waiting for the
// arrival of a signal. If it causes the thread to wake up, the
// sig.state travels through this sequence: sigReceiving -> sigFixup
// -> sigIdle -> sigReceiving and resumes. (This is only called while
// GC is disabled.)
//go:nosplit
func sigRecvPrepareForFixup() {
	if atomic.Cas(&sig.state, sigReceiving, sigFixup) {
		notewakeup(&sig.note)
	}
}

// Called to receive the next queued signal.
// Must only be called from a single goroutine at a time.
//go:linkname signal_recv os_1signal.signal__recv
func signal_recv() uint32 {
	for {
		// Serve any signals from local copy.
		for i := uint32(0); i < _NSIG; i++ {
			if sig.recv[i/32]&(1<<(i&31)) != 0 {
				sig.recv[i/32] &^= 1 << (i & 31)
				return i
			}
		}

		// Wait for updates to be available from signal sender.
	Receive:
		for {
			switch atomic.Load(&sig.state) {
			default:
				throw("signal_recv: inconsistent state")
			case sigIdle:
				if atomic.Cas(&sig.state, sigIdle, sigReceiving) {
					if GOOS == "darwin" || GOOS == "ios" {
						sigNoteSleep(&sig.note)
						break Receive
					}
					notetsleepg(&sig.note, -1)
					noteclear(&sig.note)
					if !atomic.Cas(&sig.state, sigFixup, sigIdle) {
						break Receive
					}
					// Getting here, the code will
					// loop around again to sleep
					// in state sigReceiving. This
					// path is taken when
					// sigRecvPrepareForFixup()
					// has been called by another
					// thread.
				}
			case sigSending:
				if atomic.Cas(&sig.state, sigSending, sigIdle) {
					break Receive
				}
			}
		}

		// Incorporate updates from sender into local copy.
		for i := range sig.mask {
			sig.recv[i] = atomic.Xchg(&sig.mask[i], 0)
		}
	}
}

// signalWaitUntilIdle waits until the signal delivery mechanism is idle.
// This is used to ensure that we do not drop a signal notification due
// to a race between disabling a signal and receiving a signal.
// This assumes that signal delivery has already been disabled for
// the signal(s) in question, and here we are just waiting to make sure
// that all the signals have been delivered to the user channels
// by the os/signal package.
//go:linkname signalWaitUntilIdle os_1signal.signalWaitUntilIdle
func signalWaitUntilIdle() {
	// Although the signals we care about have been removed from
	// sig.wanted, it is possible that another thread has received
	// a signal, has read from sig.wanted, is now updating sig.mask,
	// and has not yet woken up the processor thread. We need to wait
	// until all current signal deliveries have completed.
	for atomic.Load(&sig.delivering) != 0 {
		Gosched()
	}

	// Although WaitUntilIdle seems like the right name for this
	// function, the state we are looking for is sigReceiving, not
	// sigIdle.  The sigIdle state is really more like sigProcessing.
	for atomic.Load(&sig.state) != sigReceiving {
		Gosched()
	}
}

// Must only be called from a single goroutine at a time.
//go:linkname signal_enable os_1signal.signal__enable
func signal_enable(s uint32) {
	if !sig.inuse {
		// This is the first call to signal_enable. Initialize.
		sig.inuse = true // enable reception of signals; cannot disable
		if GOOS == "darwin" || GOOS == "ios" {
			sigNoteSetup(&sig.note)
		} else {
			noteclear(&sig.note)
		}
	}

	if s >= uint32(len(sig.wanted)*32) {
		return
	}

	w := sig.wanted[s/32]
	w |= 1 << (s & 31)
	atomic.Store(&sig.wanted[s/32], w)

	i := sig.ignored[s/32]
	i &^= 1 << (s & 31)
	atomic.Store(&sig.ignored[s/32], i)

	sigenable(s)
}

// Must only be called from a single goroutine at a time.
//go:linkname signal_disable os_1signal.signal__disable
func signal_disable(s uint32) {
	if s >= uint32(len(sig.wanted)*32) {
		return
	}
	sigdisable(s)

	w := sig.wanted[s/32]
	w &^= 1 << (s & 31)
	atomic.Store(&sig.wanted[s/32], w)
}

// Must only be called from a single goroutine at a time.
//go:linkname signal_ignore os_1signal.signal__ignore
func signal_ignore(s uint32) {
	if s >= uint32(len(sig.wanted)*32) {
		return
	}
	sigignore(s)

	w := sig.wanted[s/32]
	w &^= 1 << (s & 31)
	atomic.Store(&sig.wanted[s/32], w)

	i := sig.ignored[s/32]
	i |= 1 << (s & 31)
	atomic.Store(&sig.ignored[s/32], i)
}

// sigInitIgnored marks the signal as already ignored. This is called at
// program start by initsig. In a shared library initsig is called by
// libpreinit, so the runtime may not be initialized yet.
//go:nosplit
func sigInitIgnored(s uint32) {
	i := sig.ignored[s/32]
	i |= 1 << (s & 31)
	atomic.Store(&sig.ignored[s/32], i)
}

// Checked by signal handlers.
//go:linkname signal_ignored os_1signal.signal__ignored
func signal_ignored(s uint32) bool {
	i := atomic.Load(&sig.ignored[s/32])
	return i&(1<<(s&31)) != 0
}
