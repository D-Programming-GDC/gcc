// Copyright 2012 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// +build aix darwin dragonfly freebsd hurd linux netbsd openbsd solaris

package runtime

import (
	"runtime/internal/atomic"
	"unsafe"
)

// For gccgo's C code to call:
//go:linkname initsig
//go:linkname sigtrampgo

// sigTabT is the type of an entry in the global sigtable array.
// sigtable is inherently system dependent, and appears in OS-specific files,
// but sigTabT is the same for all Unixy systems.
// The sigtable array is indexed by a system signal number to get the flags
// and printable name of each signal.
type sigTabT struct {
	flags int32
	name  string
}

//go:linkname os_sigpipe os.sigpipe
func os_sigpipe() {
	systemstack(sigpipe)
}

func signame(sig uint32) string {
	if sig >= uint32(len(sigtable)) {
		return ""
	}
	return sigtable[sig].name
}

const (
	_SIG_DFL uintptr = 0
	_SIG_IGN uintptr = 1
)

// sigPreempt is the signal used for non-cooperative preemption.
//
// There's no good way to choose this signal, but there are some
// heuristics:
//
// 1. It should be a signal that's passed-through by debuggers by
// default. On Linux, this is SIGALRM, SIGURG, SIGCHLD, SIGIO,
// SIGVTALRM, SIGPROF, and SIGWINCH, plus some glibc-internal signals.
//
// 2. It shouldn't be used internally by libc in mixed Go/C binaries
// because libc may assume it's the only thing that can handle these
// signals. For example SIGCANCEL or SIGSETXID.
//
// 3. It should be a signal that can happen spuriously without
// consequences. For example, SIGALRM is a bad choice because the
// signal handler can't tell if it was caused by the real process
// alarm or not (arguably this means the signal is broken, but I
// digress). SIGUSR1 and SIGUSR2 are also bad because those are often
// used in meaningful ways by applications.
//
// 4. We need to deal with platforms without real-time signals (like
// macOS), so those are out.
//
// We use SIGURG because it meets all of these criteria, is extremely
// unlikely to be used by an application for its "real" meaning (both
// because out-of-band data is basically unused and because SIGURG
// doesn't report which socket has the condition, making it pretty
// useless), and even if it is, the application has to be ready for
// spurious SIGURG. SIGIO wouldn't be a bad choice either, but is more
// likely to be used for real.
const sigPreempt = _SIGURG

// Stores the signal handlers registered before Go installed its own.
// These signal handlers will be invoked in cases where Go doesn't want to
// handle a particular signal (e.g., signal occurred on a non-Go thread).
// See sigfwdgo for more information on when the signals are forwarded.
//
// This is read by the signal handler; accesses should use
// atomic.Loaduintptr and atomic.Storeuintptr.
var fwdSig [_NSIG]uintptr

// handlingSig is indexed by signal number and is non-zero if we are
// currently handling the signal. Or, to put it another way, whether
// the signal handler is currently set to the Go signal handler or not.
// This is uint32 rather than bool so that we can use atomic instructions.
var handlingSig [_NSIG]uint32

// channels for synchronizing signal mask updates with the signal mask
// thread
var (
	disableSigChan  chan uint32
	enableSigChan   chan uint32
	maskUpdatedChan chan struct{}
)

func init() {
	// _NSIG is the number of signals on this operating system.
	// sigtable should describe what to do for all the possible signals.
	if len(sigtable) != _NSIG {
		print("runtime: len(sigtable)=", len(sigtable), " _NSIG=", _NSIG, "\n")
		throw("bad sigtable len")
	}
}

var signalsOK bool

// Initialize signals.
// Called by libpreinit so runtime may not be initialized.
//go:nosplit
//go:nowritebarrierrec
func initsig(preinit bool) {
	if preinit {
		// preinit is only passed as true if isarchive should be true.
		isarchive = true
	}

	if !preinit {
		// It's now OK for signal handlers to run.
		signalsOK = true
	}

	// For c-archive/c-shared this is called by libpreinit with
	// preinit == true.
	if (isarchive || islibrary) && !preinit {
		return
	}

	for i := uint32(0); i < _NSIG; i++ {
		t := &sigtable[i]
		if t.flags == 0 || t.flags&_SigDefault != 0 {
			continue
		}

		// We don't need to use atomic operations here because
		// there shouldn't be any other goroutines running yet.
		fwdSig[i] = getsig(i)

		if !sigInstallGoHandler(i) {
			// Even if we are not installing a signal handler,
			// set SA_ONSTACK if necessary.
			if fwdSig[i] != _SIG_DFL && fwdSig[i] != _SIG_IGN {
				setsigstack(i)
			} else if fwdSig[i] == _SIG_IGN {
				sigInitIgnored(i)
			}
			continue
		}

		handlingSig[i] = 1
		setsig(i, getSigtramp())
	}
}

//go:nosplit
//go:nowritebarrierrec
func sigInstallGoHandler(sig uint32) bool {
	// For some signals, we respect an inherited SIG_IGN handler
	// rather than insist on installing our own default handler.
	// Even these signals can be fetched using the os/signal package.
	switch sig {
	case _SIGHUP, _SIGINT:
		if atomic.Loaduintptr(&fwdSig[sig]) == _SIG_IGN {
			return false
		}
	}

	t := &sigtable[sig]
	if t.flags&_SigSetStack != 0 {
		return false
	}

	// When built using c-archive or c-shared, only install signal
	// handlers for synchronous signals, SIGPIPE, and SIGURG.
	if (isarchive || islibrary) && t.flags&_SigPanic == 0 && sig != _SIGPIPE && sig != _SIGURG {
		return false
	}

	return true
}

// sigenable enables the Go signal handler to catch the signal sig.
// It is only called while holding the os/signal.handlers lock,
// via os/signal.enableSignal and signal_enable.
func sigenable(sig uint32) {
	if sig >= uint32(len(sigtable)) {
		return
	}

	// SIGPROF is handled specially for profiling.
	if sig == _SIGPROF {
		return
	}

	t := &sigtable[sig]
	if t.flags&_SigNotify != 0 {
		ensureSigM()
		enableSigChan <- sig
		<-maskUpdatedChan
		if atomic.Cas(&handlingSig[sig], 0, 1) {
			atomic.Storeuintptr(&fwdSig[sig], getsig(sig))
			setsig(sig, getSigtramp())
		}
	}
}

// sigdisable disables the Go signal handler for the signal sig.
// It is only called while holding the os/signal.handlers lock,
// via os/signal.disableSignal and signal_disable.
func sigdisable(sig uint32) {
	if sig >= uint32(len(sigtable)) {
		return
	}

	// SIGPROF is handled specially for profiling.
	if sig == _SIGPROF {
		return
	}

	t := &sigtable[sig]
	if t.flags&_SigNotify != 0 {
		ensureSigM()
		disableSigChan <- sig
		<-maskUpdatedChan

		// If initsig does not install a signal handler for a
		// signal, then to go back to the state before Notify
		// we should remove the one we installed.
		if !sigInstallGoHandler(sig) {
			atomic.Store(&handlingSig[sig], 0)
			setsig(sig, atomic.Loaduintptr(&fwdSig[sig]))
		}
	}
}

// sigignore ignores the signal sig.
// It is only called while holding the os/signal.handlers lock,
// via os/signal.ignoreSignal and signal_ignore.
func sigignore(sig uint32) {
	if sig >= uint32(len(sigtable)) {
		return
	}

	// SIGPROF is handled specially for profiling.
	if sig == _SIGPROF {
		return
	}

	t := &sigtable[sig]
	if t.flags&_SigNotify != 0 {
		atomic.Store(&handlingSig[sig], 0)
		setsig(sig, _SIG_IGN)
	}
}

// clearSignalHandlers clears all signal handlers that are not ignored
// back to the default. This is called by the child after a fork, so that
// we can enable the signal mask for the exec without worrying about
// running a signal handler in the child.
//go:nosplit
//go:nowritebarrierrec
func clearSignalHandlers() {
	for i := uint32(0); i < _NSIG; i++ {
		if atomic.Load(&handlingSig[i]) != 0 {
			setsig(i, _SIG_DFL)
		}
	}
}

// setProcessCPUProfiler is called when the profiling timer changes.
// It is called with prof.lock held. hz is the new timer, and is 0 if
// profiling is being disabled. Enable or disable the signal as
// required for -buildmode=c-archive.
func setProcessCPUProfiler(hz int32) {
	if hz != 0 {
		// Enable the Go signal handler if not enabled.
		if atomic.Cas(&handlingSig[_SIGPROF], 0, 1) {
			atomic.Storeuintptr(&fwdSig[_SIGPROF], getsig(_SIGPROF))
			setsig(_SIGPROF, getSigtramp())
		}

		var it _itimerval
		it.it_interval.tv_sec = 0
		it.it_interval.set_usec(1000000 / hz)
		it.it_value = it.it_interval
		setitimer(_ITIMER_PROF, &it, nil)
	} else {
		// If the Go signal handler should be disabled by default,
		// switch back to the signal handler that was installed
		// when we enabled profiling. We don't try to handle the case
		// of a program that changes the SIGPROF handler while Go
		// profiling is enabled.
		//
		// If no signal handler was installed before, then start
		// ignoring SIGPROF signals. We do this, rather than change
		// to SIG_DFL, because there may be a pending SIGPROF
		// signal that has not yet been delivered to some other thread.
		// If we change to SIG_DFL here, the program will crash
		// when that SIGPROF is delivered. We assume that programs
		// that use profiling don't want to crash on a stray SIGPROF.
		// See issue 19320.
		if !sigInstallGoHandler(_SIGPROF) {
			if atomic.Cas(&handlingSig[_SIGPROF], 1, 0) {
				h := atomic.Loaduintptr(&fwdSig[_SIGPROF])
				if h == _SIG_DFL {
					h = _SIG_IGN
				}
				setsig(_SIGPROF, h)
			}
		}

		setitimer(_ITIMER_PROF, &_itimerval{}, nil)
	}
}

// setThreadCPUProfiler makes any thread-specific changes required to
// implement profiling at a rate of hz.
// No changes required on Unix systems.
func setThreadCPUProfiler(hz int32) {
	getg().m.profilehz = hz
}

func sigpipe() {
	if signal_ignored(_SIGPIPE) || sigsend(_SIGPIPE) {
		return
	}
	dieFromSignal(_SIGPIPE)
}

// doSigPreempt handles a preemption signal on gp.
func doSigPreempt(gp *g, ctxt *sigctxt, sigpc uintptr) {
	// Check if this G wants to be preempted and is safe to
	// preempt.
	if wantAsyncPreempt(gp) {
		if ok, newpc := isAsyncSafePoint(gp, sigpc); ok {
			// Adjust the PC and inject a call to asyncPreempt.
			// ctxt.pushCall(funcPC(asyncPreempt), newpc)
			throw("pushCall not implemented")
			_ = newpc
		}
	}

	// Acknowledge the preemption.
	atomic.Xadd(&gp.m.preemptGen, 1)
	atomic.Store(&gp.m.signalPending, 0)

	if GOOS == "darwin" || GOOS == "ios" {
		atomic.Xadd(&pendingPreemptSignals, -1)
	}
}

// This is false for gccgo.
const preemptMSupported = false

// preemptM sends a preemption request to mp. This request may be
// handled asynchronously and may be coalesced with other requests to
// the M. When the request is received, if the running G or P are
// marked for preemption and the goroutine is at an asynchronous
// safe-point, it will preempt the goroutine. It always atomically
// increments mp.preemptGen after handling a preemption request.
func preemptM(mp *m) {
	// On Darwin, don't try to preempt threads during exec.
	// Issue #41702.
	if GOOS == "darwin" || GOOS == "ios" {
		execLock.rlock()
	}

	if atomic.Cas(&mp.signalPending, 0, 1) {
		if GOOS == "darwin" || GOOS == "ios" {
			atomic.Xadd(&pendingPreemptSignals, 1)
		}

		// If multiple threads are preempting the same M, it may send many
		// signals to the same M such that it hardly make progress, causing
		// live-lock problem. Apparently this could happen on darwin. See
		// issue #37741.
		// Only send a signal if there isn't already one pending.
		// signalM(mp, sigPreempt)
		throw("signalM not implemented")
	}

	if GOOS == "darwin" || GOOS == "ios" {
		execLock.runlock()
	}
}

// sigtrampgo is called from the signal handler function, sigtramp,
// written in assembly code.
// This is called by the signal handler, and the world may be stopped.
//
// It must be nosplit because getg() is still the G that was running
// (if any) when the signal was delivered, but it's (usually) called
// on the gsignal stack. Until this switches the G to gsignal, the
// stack bounds check won't work.
//
//go:nosplit
//go:nowritebarrierrec
func sigtrampgo(sig uint32, info *_siginfo_t, ctx unsafe.Pointer) {
	if sigfwdgo(sig, info, ctx) {
		return
	}
	g := getg()
	if g == nil {
		c := sigctxt{info, ctx}
		if sig == _SIGPROF {
			_, pc := getSiginfo(info, ctx)
			sigprofNonGo(pc)
			return
		}
		if sig == sigPreempt && preemptMSupported && debug.asyncpreemptoff == 0 {
			// This is probably a signal from preemptM sent
			// while executing Go code but received while
			// executing non-Go code.
			// We got past sigfwdgo, so we know that there is
			// no non-Go signal handler for sigPreempt.
			// The default behavior for sigPreempt is to ignore
			// the signal, so badsignal will be a no-op anyway.
			if GOOS == "darwin" || GOOS == "ios" {
				atomic.Xadd(&pendingPreemptSignals, -1)
			}
			return
		}
		badsignal(uintptr(sig), &c)
		return
	}

	setg(g.m.gsignal)
	sighandler(sig, info, ctx, g)
	setg(g)
}

// crashing is the number of m's we have waited for when implementing
// GOTRACEBACK=crash when a signal is received.
var crashing int32

// testSigtrap and testSigusr1 are used by the runtime tests. If
// non-nil, it is called on SIGTRAP/SIGUSR1. If it returns true, the
// normal behavior on this signal is suppressed.
var testSigtrap func(info *_siginfo_t, ctxt *sigctxt, gp *g) bool
var testSigusr1 func(gp *g) bool

// sighandler is invoked when a signal occurs. The global g will be
// set to a gsignal goroutine and we will be running on the alternate
// signal stack. The parameter g will be the value of the global g
// when the signal occurred. The sig, info, and ctxt parameters are
// from the system signal handler: they are the parameters passed when
// the SA is passed to the sigaction system call.
//
// The garbage collector may have stopped the world, so write barriers
// are not allowed.
//
//go:nowritebarrierrec
func sighandler(sig uint32, info *_siginfo_t, ctxt unsafe.Pointer, gp *g) {
	_g_ := getg()
	c := &sigctxt{info, ctxt}

	sigfault, sigpc := getSiginfo(info, ctxt)

	if sig == _SIGURG && usestackmaps {
		// We may be signaled to do a stack scan.
		// The signal delivery races with enter/exitsyscall.
		// We may be on g0 stack now. gp.m.curg is the g we
		// want to scan.
		// If we're not on g stack, give up. The sender will
		// try again later.
		// If we're not stopped at a safepoint (doscanstack will
		// return false), also give up.
		if s := readgstatus(gp.m.curg); s == _Gscansyscall {
			if gp == gp.m.curg {
				if doscanstack(gp, (*gcWork)(unsafe.Pointer(gp.scangcw))) {
					gp.gcScannedSyscallStack = true
				}
			}
			gp.m.curg.scangcw = 0
			notewakeup(&gp.m.scannote)
			return
		}
	}

	if sig == _SIGPROF {
		sigprof(sigpc, gp, _g_.m)
		return
	}

	if sig == _SIGTRAP && testSigtrap != nil && testSigtrap(info, (*sigctxt)(noescape(unsafe.Pointer(c))), gp) {
		return
	}

	if sig == _SIGUSR1 && testSigusr1 != nil && testSigusr1(gp) {
		return
	}

	if sig == sigPreempt && debug.asyncpreemptoff == 0 {
		// Might be a preemption signal.
		doSigPreempt(gp, c, sigpc)
		// Even if this was definitely a preemption signal, it
		// may have been coalesced with another signal, so we
		// still let it through to the application.
	}

	flags := int32(_SigThrow)
	if sig < uint32(len(sigtable)) {
		flags = sigtable[sig].flags
	}
	if c.sigcode() != _SI_USER && flags&_SigPanic != 0 && gp.throwsplit {
		// We can't safely sigpanic because it may grow the
		// stack. Abort in the signal handler instead.
		flags = _SigThrow
	}
	if isAbortPC(sigpc) {
		// On many architectures, the abort function just
		// causes a memory fault. Don't turn that into a panic.
		flags = _SigThrow
	}
	if c.sigcode() != _SI_USER && flags&_SigPanic != 0 {
		// Emulate gc by passing arguments out of band,
		// although we don't really have to.
		gp.sig = sig
		gp.sigcode0 = uintptr(c.sigcode())
		gp.sigcode1 = sigfault
		gp.sigpc = sigpc

		setg(gp)

		// All signals were blocked due to the sigaction mask;
		// unblock them.
		var set sigset
		sigfillset(&set)
		sigprocmask(_SIG_UNBLOCK, &set, nil)

		sigpanic()
		throw("sigpanic returned")
	}

	if c.sigcode() == _SI_USER || flags&_SigNotify != 0 {
		if sigsend(sig) {
			return
		}
	}

	if c.sigcode() == _SI_USER && signal_ignored(sig) {
		return
	}

	if flags&_SigKill != 0 {
		dieFromSignal(sig)
	}

	// _SigThrow means that we should exit now.
	// If we get here with _SigPanic, it means that the signal
	// was sent to us by a program (c.sigcode() == _SI_USER);
	// in that case, if we didn't handle it in sigsend, we exit now.
	if flags&(_SigThrow|_SigPanic) == 0 {
		return
	}

	_g_.m.throwing = 1
	_g_.m.caughtsig.set(gp)

	if crashing == 0 {
		startpanic_m()
	}

	if sig < uint32(len(sigtable)) {
		print(sigtable[sig].name, "\n")
	} else {
		print("Signal ", sig, "\n")
	}

	print("PC=", hex(sigpc), " m=", _g_.m.id, " sigcode=", c.sigcode(), "\n")
	if _g_.m.lockedg != 0 && _g_.m.ncgo > 0 && gp == _g_.m.g0 {
		print("signal arrived during cgo execution\n")
		gp = _g_.m.lockedg.ptr()
	}
	if sig == _SIGILL || sig == _SIGFPE {
		// It would be nice to know how long the instruction is.
		// Unfortunately, that's complicated to do in general (mostly for x86
		// and s930x, but other archs have non-standard instruction lengths also).
		// Opt to print 16 bytes, which covers most instructions.
		const maxN = 16
		n := uintptr(maxN)
		// We have to be careful, though. If we're near the end of
		// a page and the following page isn't mapped, we could
		// segfault. So make sure we don't straddle a page (even though
		// that could lead to printing an incomplete instruction).
		// We're assuming here we can read at least the page containing the PC.
		// I suppose it is possible that the page is mapped executable but not readable?
		pc := sigpc
		if n > physPageSize-pc%physPageSize {
			n = physPageSize - pc%physPageSize
		}
		print("instruction bytes:")
		b := (*[maxN]byte)(unsafe.Pointer(pc))
		for i := uintptr(0); i < n; i++ {
			print(" ", hex(b[i]))
		}
		println()
	}
	print("\n")

	level, _, docrash := gotraceback()
	if level > 0 {
		goroutineheader(gp)
		traceback(0)
		if crashing == 0 {
			tracebackothers(gp)
			print("\n")
		}
		dumpregs(info, ctxt)
	}

	if docrash {
		crashing++
		if crashing < mcount()-int32(extraMCount) {
			// There are other m's that need to dump their stacks.
			// Relay SIGQUIT to the next m by sending it to the current process.
			// All m's that have already received SIGQUIT have signal masks blocking
			// receipt of any signals, so the SIGQUIT will go to an m that hasn't seen it yet.
			// When the last m receives the SIGQUIT, it will fall through to the call to
			// crash below. Just in case the relaying gets botched, each m involved in
			// the relay sleeps for 5 seconds and then does the crash/exit itself.
			// In expected operation, the last m has received the SIGQUIT and run
			// crash/exit and the process is gone, all long before any of the
			// 5-second sleeps have finished.
			print("\n-----\n\n")
			raiseproc(_SIGQUIT)
			usleep(5 * 1000 * 1000)
		}
		crash()
	}

	printDebugLog()

	exit(2)
}

// sigpanic turns a synchronous signal into a run-time panic.
// If the signal handler sees a synchronous panic, it arranges the
// stack to look like the function where the signal occurred called
// sigpanic, sets the signal's PC value to sigpanic, and returns from
// the signal handler. The effect is that the program will act as
// though the function that got the signal simply called sigpanic
// instead.
//
// This must NOT be nosplit because the linker doesn't know where
// sigpanic calls can be injected.
//
// The signal handler must not inject a call to sigpanic if
// getg().throwsplit, since sigpanic may need to grow the stack.
//
// This is exported via linkname to assembly in runtime/cgo.
//go:linkname sigpanic
func sigpanic() {
	g := getg()
	if !canpanic(g) {
		throw("unexpected signal during runtime execution")
	}

	switch g.sig {
	case _SIGBUS:
		if g.sigcode0 == _BUS_ADRERR && g.sigcode1 < 0x1000 {
			panicmem()
		}
		// Support runtime/debug.SetPanicOnFault.
		if g.paniconfault {
			panicmemAddr(g.sigcode1)
		}
		print("unexpected fault address ", hex(g.sigcode1), "\n")
		throw("fault")
	case _SIGSEGV:
		if (g.sigcode0 == 0 || g.sigcode0 == _SEGV_MAPERR || g.sigcode0 == _SEGV_ACCERR) && g.sigcode1 < 0x1000 {
			panicmem()
		}
		// Support runtime/debug.SetPanicOnFault.
		if g.paniconfault {
			panicmemAddr(g.sigcode1)
		}
		print("unexpected fault address ", hex(g.sigcode1), "\n")
		throw("fault")
	case _SIGFPE:
		switch g.sigcode0 {
		case _FPE_INTDIV:
			panicdivide()
		case _FPE_INTOVF:
			panicoverflow()
		}
		panicfloat()
	}

	if g.sig >= uint32(len(sigtable)) {
		// can't happen: we looked up g.sig in sigtable to decide to call sigpanic
		throw("unexpected signal value")
	}
	panic(errorString(sigtable[g.sig].name))
}

// dieFromSignal kills the program with a signal.
// This provides the expected exit status for the shell.
// This is only called with fatal signals expected to kill the process.
//go:nosplit
//go:nowritebarrierrec
func dieFromSignal(sig uint32) {
	unblocksig(sig)
	// Mark the signal as unhandled to ensure it is forwarded.
	atomic.Store(&handlingSig[sig], 0)
	raise(sig)

	// That should have killed us. On some systems, though, raise
	// sends the signal to the whole process rather than to just
	// the current thread, which means that the signal may not yet
	// have been delivered. Give other threads a chance to run and
	// pick up the signal.
	osyield()
	osyield()
	osyield()

	// If that didn't work, try _SIG_DFL.
	setsig(sig, _SIG_DFL)
	raise(sig)

	osyield()
	osyield()
	osyield()

	// If we are still somehow running, just exit with the wrong status.
	exit(2)
}

// raisebadsignal is called when a signal is received on a non-Go
// thread, and the Go program does not want to handle it (that is, the
// program has not called os/signal.Notify for the signal).
func raisebadsignal(sig uint32, c *sigctxt) {
	if sig == _SIGPROF {
		// Ignore profiling signals that arrive on non-Go threads.
		return
	}

	var handler uintptr
	if sig >= _NSIG {
		handler = _SIG_DFL
	} else {
		handler = atomic.Loaduintptr(&fwdSig[sig])
	}

	// Reset the signal handler and raise the signal.
	// We are currently running inside a signal handler, so the
	// signal is blocked. We need to unblock it before raising the
	// signal, or the signal we raise will be ignored until we return
	// from the signal handler. We know that the signal was unblocked
	// before entering the handler, or else we would not have received
	// it. That means that we don't have to worry about blocking it
	// again.
	unblocksig(sig)
	setsig(sig, handler)

	// If we're linked into a non-Go program we want to try to
	// avoid modifying the original context in which the signal
	// was raised. If the handler is the default, we know it
	// is non-recoverable, so we don't have to worry about
	// re-installing sighandler. At this point we can just
	// return and the signal will be re-raised and caught by
	// the default handler with the correct context.
	//
	// On FreeBSD, the libthr sigaction code prevents
	// this from working so we fall through to raise.
	//
	// The argument above doesn't hold for SIGPIPE, which won't
	// necessarily be re-raised if we return.
	if GOOS != "freebsd" && (isarchive || islibrary) && handler == _SIG_DFL && c.sigcode() != _SI_USER && sig != _SIGPIPE {
		return
	}

	raise(sig)

	// Give the signal a chance to be delivered.
	// In almost all real cases the program is about to crash,
	// so sleeping here is not a waste of time.
	usleep(1000)

	// If the signal didn't cause the program to exit, restore the
	// Go signal handler and carry on.
	//
	// We may receive another instance of the signal before we
	// restore the Go handler, but that is not so bad: we know
	// that the Go program has been ignoring the signal.
	setsig(sig, getSigtramp())
}

//go:nosplit
func crash() {
	// OS X core dumps are linear dumps of the mapped memory,
	// from the first virtual byte to the last, with zeros in the gaps.
	// Because of the way we arrange the address space on 64-bit systems,
	// this means the OS X core file will be >128 GB and even on a zippy
	// workstation can take OS X well over an hour to write (uninterruptible).
	// Save users from making that mistake.
	if GOOS == "darwin" && GOARCH == "amd64" {
		return
	}

	dieFromSignal(_SIGABRT)
}

// ensureSigM starts one global, sleeping thread to make sure at least one thread
// is available to catch signals enabled for os/signal.
func ensureSigM() {
	if maskUpdatedChan != nil {
		return
	}
	maskUpdatedChan = make(chan struct{})
	disableSigChan = make(chan uint32)
	enableSigChan = make(chan uint32)
	go func() {
		// Signal masks are per-thread, so make sure this goroutine stays on one
		// thread.
		LockOSThread()
		defer UnlockOSThread()
		// The sigBlocked mask contains the signals not active for os/signal,
		// initially all signals except the essential. When signal.Notify()/Stop is called,
		// sigenable/sigdisable in turn notify this thread to update its signal
		// mask accordingly.
		var sigBlocked sigset
		sigfillset(&sigBlocked)
		for i := range sigtable {
			if !blockableSig(uint32(i)) {
				sigdelset(&sigBlocked, i)
			}
		}
		sigprocmask(_SIG_SETMASK, &sigBlocked, nil)
		for {
			select {
			case sig := <-enableSigChan:
				if sig > 0 {
					sigdelset(&sigBlocked, int(sig))
				}
			case sig := <-disableSigChan:
				if sig > 0 && blockableSig(sig) {
					sigaddset(&sigBlocked, int(sig))
				}
			}
			sigprocmask(_SIG_SETMASK, &sigBlocked, nil)
			maskUpdatedChan <- struct{}{}
		}
	}()
}

// This is called when we receive a signal when there is no signal stack.
// This can only happen if non-Go code calls sigaltstack to disable the
// signal stack.
func noSignalStack(sig uint32) {
	println("signal", sig, "received on thread with no signal stack")
	throw("non-Go code disabled sigaltstack")
}

// This is called if we receive a signal when there is a signal stack
// but we are not on it. This can only happen if non-Go code called
// sigaction without setting the SS_ONSTACK flag.
func sigNotOnStack(sig uint32) {
	println("signal", sig, "received but handler not on signal stack")
	throw("non-Go code set up signal handler without SA_ONSTACK flag")
}

// signalDuringFork is called if we receive a signal while doing a fork.
// We do not want signals at that time, as a signal sent to the process
// group may be delivered to the child process, causing confusion.
// This should never be called, because we block signals across the fork;
// this function is just a safety check. See issue 18600 for background.
func signalDuringFork(sig uint32) {
	println("signal", sig, "received during fork")
	throw("signal received during fork")
}

var badginsignalMsg = "fatal: bad g in signal handler\n"

// This runs on a foreign stack, without an m or a g. No stack split.
//go:nosplit
//go:norace
//go:nowritebarrierrec
func badsignal(sig uintptr, c *sigctxt) {
	if !iscgo && !cgoHasExtraM {
		// There is no extra M. needm will not be able to grab
		// an M. Instead of hanging, just crash.
		// Cannot call split-stack function as there is no G.
		s := stringStructOf(&badginsignalMsg)
		write(2, s.str, int32(s.len))
		exit(2)
		*(*uintptr)(unsafe.Pointer(uintptr(123))) = 2
	}
	needm()
	if !sigsend(uint32(sig)) {
		// A foreign thread received the signal sig, and the
		// Go code does not want to handle it.
		raisebadsignal(uint32(sig), c)
	}
	dropm()
}

// Determines if the signal should be handled by Go and if not, forwards the
// signal to the handler that was installed before Go's. Returns whether the
// signal was forwarded.
// This is called by the signal handler, and the world may be stopped.
//go:nosplit
//go:nowritebarrierrec
func sigfwdgo(sig uint32, info *_siginfo_t, ctx unsafe.Pointer) bool {
	if sig >= uint32(len(sigtable)) {
		return false
	}
	fwdFn := atomic.Loaduintptr(&fwdSig[sig])
	flags := sigtable[sig].flags

	// If we aren't handling the signal, forward it.
	if atomic.Load(&handlingSig[sig]) == 0 || !signalsOK {
		// If the signal is ignored, doing nothing is the same as forwarding.
		if fwdFn == _SIG_IGN || (fwdFn == _SIG_DFL && flags&_SigIgn != 0) {
			return true
		}
		// We are not handling the signal and there is no other handler to forward to.
		// Crash with the default behavior.
		if fwdFn == _SIG_DFL {
			setsig(sig, _SIG_DFL)
			dieFromSignal(sig)
			return false
		}

		sigfwd(fwdFn, sig, info, ctx)
		return true
	}

	// This function and its caller sigtrampgo assumes SIGPIPE is delivered on the
	// originating thread. This property does not hold on macOS (golang.org/issue/33384),
	// so we have no choice but to ignore SIGPIPE.
	if (GOOS == "darwin" || GOOS == "ios") && sig == _SIGPIPE {
		return true
	}

	// If there is no handler to forward to, no need to forward.
	if fwdFn == _SIG_DFL {
		return false
	}

	c := sigctxt{info, ctx}
	// Only forward synchronous signals and SIGPIPE.
	// Unfortunately, user generated SIGPIPEs will also be forwarded, because si_code
	// is set to _SI_USER even for a SIGPIPE raised from a write to a closed socket
	// or pipe.
	if (c.sigcode() == _SI_USER || flags&_SigPanic == 0) && sig != _SIGPIPE {
		return false
	}
	// Determine if the signal occurred inside Go code. We test that:
	//   (1) we weren't in VDSO page,
	//   (2) we were in a goroutine (i.e., m.curg != nil), and
	//   (3) we weren't in CGO.
	g := getg()
	if g != nil && g.m != nil && g.m.curg != nil && !g.m.incgo {
		return false
	}

	// Signal not handled by Go, forward it.
	if fwdFn != _SIG_IGN {
		sigfwd(fwdFn, sig, info, ctx)
	}

	return true
}

// sigsave saves the current thread's signal mask into *p.
// This is used to preserve the non-Go signal mask when a non-Go
// thread calls a Go function.
// This is nosplit and nowritebarrierrec because it is called by needm
// which may be called on a non-Go thread with no g available.
//go:nosplit
//go:nowritebarrierrec
func sigsave(p *sigset) {
	sigprocmask(_SIG_SETMASK, nil, p)
}

// msigrestore sets the current thread's signal mask to sigmask.
// This is used to restore the non-Go signal mask when a non-Go thread
// calls a Go function.
// This is nosplit and nowritebarrierrec because it is called by dropm
// after g has been cleared.
//go:nosplit
//go:nowritebarrierrec
func msigrestore(sigmask sigset) {
	sigprocmask(_SIG_SETMASK, &sigmask, nil)
}

// sigblock blocks signals in the current thread's signal mask.
// This is used to block signals while setting up and tearing down g
// when a non-Go thread calls a Go function. When a thread is exiting
// we use the sigsetAllExiting value, otherwise the OS specific
// definition of sigset_all is used.
// This is nosplit and nowritebarrierrec because it is called by needm
// which may be called on a non-Go thread with no g available.
//go:nosplit
//go:nowritebarrierrec
func sigblock(exiting bool) {
	var set sigset
	sigfillset(&set)
	sigprocmask(_SIG_SETMASK, &set, nil)
}

// unblocksig removes sig from the current thread's signal mask.
// This is nosplit and nowritebarrierrec because it is called from
// dieFromSignal, which can be called by sigfwdgo while running in the
// signal handler, on the signal stack, with no g available.
//go:nosplit
//go:nowritebarrierrec
func unblocksig(sig uint32) {
	var set sigset
	sigemptyset(&set)
	sigaddset(&set, int(sig))
	sigprocmask(_SIG_UNBLOCK, &set, nil)
}

// minitSignals is called when initializing a new m to set the
// thread's alternate signal stack and signal mask.
func minitSignals() {
	minitSignalStack()
	minitSignalMask()
}

// minitSignalStack is called when initializing a new m to set the
// alternate signal stack. If the alternate signal stack is not set
// for the thread (the normal case) then set the alternate signal
// stack to the gsignal stack. If the alternate signal stack is set
// for the thread (the case when a non-Go thread sets the alternate
// signal stack and then calls a Go function) then set the gsignal
// stack to the alternate signal stack. We also set the alternate
// signal stack to the gsignal stack if cgo is not used (regardless
// of whether it is already set). Record which choice was made in
// newSigstack, so that it can be undone in unminit.
func minitSignalStack() {
	_g_ := getg()
	var st _stack_t
	sigaltstack(nil, &st)
	if st.ss_flags&_SS_DISABLE != 0 || !iscgo {
		signalstack(_g_.m.gsignalstack, _g_.m.gsignalstacksize)
		_g_.m.newSigstack = true
	} else {
		_g_.m.newSigstack = false
	}
}

// minitSignalMask is called when initializing a new m to set the
// thread's signal mask. When this is called all signals have been
// blocked for the thread.  This starts with m.sigmask, which was set
// either from initSigmask for a newly created thread or by calling
// sigsave if this is a non-Go thread calling a Go function. It
// removes all essential signals from the mask, thus causing those
// signals to not be blocked. Then it sets the thread's signal mask.
// After this is called the thread can receive signals.
func minitSignalMask() {
	nmask := getg().m.sigmask
	for i := range sigtable {
		if !blockableSig(uint32(i)) {
			sigdelset(&nmask, i)
		}
	}
	sigprocmask(_SIG_SETMASK, &nmask, nil)
}

// unminitSignals is called from dropm, via unminit, to undo the
// effect of calling minit on a non-Go thread.
//go:nosplit
//go:nowritebarrierrec
func unminitSignals() {
	if getg().m.newSigstack {
		signalstack(nil, 0)
	}
}

// blockableSig reports whether sig may be blocked by the signal mask.
// We never want to block the signals marked _SigUnblock;
// these are the synchronous signals that turn into a Go panic.
// In a Go program--not a c-archive/c-shared--we never want to block
// the signals marked _SigKill or _SigThrow, as otherwise it's possible
// for all running threads to block them and delay their delivery until
// we start a new thread. When linked into a C program we let the C code
// decide on the disposition of those signals.
func blockableSig(sig uint32) bool {
	flags := sigtable[sig].flags
	if flags&_SigUnblock != 0 {
		return false
	}
	if isarchive || islibrary {
		return true
	}
	return flags&(_SigKill|_SigThrow) == 0
}
