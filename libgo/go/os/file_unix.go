// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// +build aix darwin dragonfly freebsd hurd js,wasm linux netbsd openbsd solaris

package os

import (
	"internal/poll"
	"internal/syscall/unix"
	"runtime"
	"syscall"
)

// fixLongPath is a noop on non-Windows platforms.
func fixLongPath(path string) string {
	return path
}

func rename(oldname, newname string) error {
	fi, err := Lstat(newname)
	if err == nil && fi.IsDir() {
		// There are two independent errors this function can return:
		// one for a bad oldname, and one for a bad newname.
		// At this point we've determined the newname is bad.
		// But just in case oldname is also bad, prioritize returning
		// the oldname error because that's what we did historically.
		// However, if the old name and new name are not the same, yet
		// they refer to the same file, it implies a case-only
		// rename on a case-insensitive filesystem, which is ok.
		if ofi, err := Lstat(oldname); err != nil {
			if pe, ok := err.(*PathError); ok {
				err = pe.Err
			}
			return &LinkError{"rename", oldname, newname, err}
		} else if newname == oldname || !SameFile(fi, ofi) {
			return &LinkError{"rename", oldname, newname, syscall.EEXIST}
		}
	}
	err = ignoringEINTR(func() error {
		return syscall.Rename(oldname, newname)
	})
	if err != nil {
		return &LinkError{"rename", oldname, newname, err}
	}
	return nil
}

// file is the real representation of *File.
// The extra level of indirection ensures that no clients of os
// can overwrite this data, which could cause the finalizer
// to close the wrong file descriptor.
type file struct {
	pfd         poll.FD
	name        string
	dirinfo     *dirInfo // nil unless directory being read
	nonblock    bool     // whether we set nonblocking mode
	stdoutOrErr bool     // whether this is stdout or stderr
	appendMode  bool     // whether file is opened for appending
}

// Fd returns the integer Unix file descriptor referencing the open file.
// If f is closed, the file descriptor becomes invalid.
// If f is garbage collected, a finalizer may close the file descriptor,
// making it invalid; see runtime.SetFinalizer for more information on when
// a finalizer might be run. On Unix systems this will cause the SetDeadline
// methods to stop working.
// Because file descriptors can be reused, the returned file descriptor may
// only be closed through the Close method of f, or by its finalizer during
// garbage collection. Otherwise, during garbage collection the finalizer
// may close an unrelated file descriptor with the same (reused) number.
//
// As an alternative, see the f.SyscallConn method.
func (f *File) Fd() uintptr {
	if f == nil {
		return ^(uintptr(0))
	}

	// If we put the file descriptor into nonblocking mode,
	// then set it to blocking mode before we return it,
	// because historically we have always returned a descriptor
	// opened in blocking mode. The File will continue to work,
	// but any blocking operation will tie up a thread.
	if f.nonblock {
		f.pfd.SetBlocking()
	}

	return uintptr(f.pfd.Sysfd)
}

// NewFile returns a new File with the given file descriptor and
// name. The returned value will be nil if fd is not a valid file
// descriptor. On Unix systems, if the file descriptor is in
// non-blocking mode, NewFile will attempt to return a pollable File
// (one for which the SetDeadline methods work).
//
// After passing it to NewFile, fd may become invalid under the same
// conditions described in the comments of the Fd method, and the same
// constraints apply.
func NewFile(fd uintptr, name string) *File {
	kind := kindNewFile
	if nb, err := unix.IsNonblock(int(fd)); err == nil && nb {
		kind = kindNonBlock
	}
	return newFile(fd, name, kind)
}

// newFileKind describes the kind of file to newFile.
type newFileKind int

const (
	kindNewFile newFileKind = iota
	kindOpenFile
	kindPipe
	kindNonBlock
)

// newFile is like NewFile, but if called from OpenFile or Pipe
// (as passed in the kind parameter) it tries to add the file to
// the runtime poller.
func newFile(fd uintptr, name string, kind newFileKind) *File {
	fdi := int(fd)
	if fdi < 0 {
		return nil
	}
	f := &File{&file{
		pfd: poll.FD{
			Sysfd:         fdi,
			IsStream:      true,
			ZeroReadIsEOF: true,
		},
		name:        name,
		stdoutOrErr: fdi == 1 || fdi == 2,
	}}

	pollable := kind == kindOpenFile || kind == kindPipe || kind == kindNonBlock

	// If the caller passed a non-blocking filedes (kindNonBlock),
	// we assume they know what they are doing so we allow it to be
	// used with kqueue.
	if kind == kindOpenFile {
		switch runtime.GOOS {
		case "darwin", "ios", "dragonfly", "freebsd", "netbsd", "openbsd":
			var st syscall.Stat_t
			err := ignoringEINTR(func() error {
				return syscall.Fstat(fdi, &st)
			})
			typ := st.Mode & syscall.S_IFMT
			// Don't try to use kqueue with regular files on *BSDs.
			// On FreeBSD a regular file is always
			// reported as ready for writing.
			// On Dragonfly, NetBSD and OpenBSD the fd is signaled
			// only once as ready (both read and write).
			// Issue 19093.
			// Also don't add directories to the netpoller.
			if err == nil && (typ == syscall.S_IFREG || typ == syscall.S_IFDIR) {
				pollable = false
			}

			// In addition to the behavior described above for regular files,
			// on Darwin, kqueue does not work properly with fifos:
			// closing the last writer does not cause a kqueue event
			// for any readers. See issue #24164.
			if (runtime.GOOS == "darwin" || runtime.GOOS == "ios") && typ == syscall.S_IFIFO {
				pollable = false
			}
		}
	}

	if err := f.pfd.Init("file", pollable); err != nil {
		// An error here indicates a failure to register
		// with the netpoll system. That can happen for
		// a file descriptor that is not supported by
		// epoll/kqueue; for example, disk files on
		// GNU/Linux systems. We assume that any real error
		// will show up in later I/O.
	} else if pollable {
		// We successfully registered with netpoll, so put
		// the file into nonblocking mode.
		if err := syscall.SetNonblock(fdi, true); err == nil {
			f.nonblock = true
		}
	}

	runtime.SetFinalizer(f.file, (*file).close)
	return f
}

// Auxiliary information if the File describes a directory
type dirInfo struct {
	dir *syscall.DIR // from opendir
}

func (d *dirInfo) close() {
	if d.dir != nil {
		syscall.Entersyscall()
		libc_closedir(d.dir)
		syscall.Exitsyscall()
		d.dir = nil
	}
}

// epipecheck raises SIGPIPE if we get an EPIPE error on standard
// output or standard error. See the SIGPIPE docs in os/signal, and
// issue 11845.
func epipecheck(file *File, e error) {
	if e == syscall.EPIPE && file.stdoutOrErr {
		sigpipe()
	}
}

// DevNull is the name of the operating system's ``null device.''
// On Unix-like systems, it is "/dev/null"; on Windows, "NUL".
const DevNull = "/dev/null"

// openFileNolog is the Unix implementation of OpenFile.
// Changes here should be reflected in openFdAt, if relevant.
func openFileNolog(name string, flag int, perm FileMode) (*File, error) {
	setSticky := false
	if !supportsCreateWithStickyBit && flag&O_CREATE != 0 && perm&ModeSticky != 0 {
		if _, err := Stat(name); IsNotExist(err) {
			setSticky = true
		}
	}

	var r int
	for {
		var e error
		r, e = syscall.Open(name, flag|syscall.O_CLOEXEC, syscallMode(perm))
		if e == nil {
			break
		}

		// We have to check EINTR here, per issues 11180 and 39237.
		if e == syscall.EINTR {
			continue
		}

		return nil, &PathError{Op: "open", Path: name, Err: e}
	}

	// open(2) itself won't handle the sticky bit on *BSD and Solaris
	if setSticky {
		setStickyBit(name)
	}

	// There's a race here with fork/exec, which we are
	// content to live with. See ../syscall/exec_unix.go.
	if !supportsCloseOnExec {
		syscall.CloseOnExec(r)
	}

	return newFile(uintptr(r), name, kindOpenFile), nil
}

func (file *file) close() error {
	if file == nil {
		return syscall.EINVAL
	}
	var err error
	if file.dirinfo != nil {
		file.dirinfo.close()
	}
	if e := file.pfd.Close(); e != nil {
		if e == poll.ErrFileClosing {
			e = ErrClosed
		}
		err = &PathError{Op: "close", Path: file.name, Err: e}
	}

	// no need for a finalizer anymore
	runtime.SetFinalizer(file, nil)
	return err
}

// seek sets the offset for the next Read or Write on file to offset, interpreted
// according to whence: 0 means relative to the origin of the file, 1 means
// relative to the current offset, and 2 means relative to the end.
// It returns the new offset and an error, if any.
func (f *File) seek(offset int64, whence int) (ret int64, err error) {
	if f.dirinfo != nil {
		// Free cached dirinfo, so we allocate a new one if we
		// access this file as a directory again. See #35767 and #37161.
		f.dirinfo.close()
		f.dirinfo = nil
	}
	ret, err = f.pfd.Seek(offset, whence)
	runtime.KeepAlive(f)
	return ret, err
}

// Truncate changes the size of the named file.
// If the file is a symbolic link, it changes the size of the link's target.
// If there is an error, it will be of type *PathError.
func Truncate(name string, size int64) error {
	e := ignoringEINTR(func() error {
		return syscall.Truncate(name, size)
	})
	if e != nil {
		return &PathError{Op: "truncate", Path: name, Err: e}
	}
	return nil
}

// Remove removes the named file or (empty) directory.
// If there is an error, it will be of type *PathError.
func Remove(name string) error {
	// System call interface forces us to know
	// whether name is a file or directory.
	// Try both: it is cheaper on average than
	// doing a Stat plus the right one.
	e := ignoringEINTR(func() error {
		return syscall.Unlink(name)
	})
	if e == nil {
		return nil
	}
	e1 := ignoringEINTR(func() error {
		return syscall.Rmdir(name)
	})
	if e1 == nil {
		return nil
	}

	// Both failed: figure out which error to return.
	// OS X and Linux differ on whether unlink(dir)
	// returns EISDIR, so can't use that. However,
	// both agree that rmdir(file) returns ENOTDIR,
	// so we can use that to decide which error is real.
	// Rmdir might also return ENOTDIR if given a bad
	// file path, like /etc/passwd/foo, but in that case,
	// both errors will be ENOTDIR, so it's okay to
	// use the error from unlink.
	if e1 != syscall.ENOTDIR {
		e = e1
	}
	return &PathError{Op: "remove", Path: name, Err: e}
}

func tempDir() string {
	dir := Getenv("TMPDIR")
	if dir == "" {
		if runtime.GOOS == "android" {
			dir = "/data/local/tmp"
		} else {
			dir = "/tmp"
		}
	}
	return dir
}

// Link creates newname as a hard link to the oldname file.
// If there is an error, it will be of type *LinkError.
func Link(oldname, newname string) error {
	e := ignoringEINTR(func() error {
		return syscall.Link(oldname, newname)
	})
	if e != nil {
		return &LinkError{"link", oldname, newname, e}
	}
	return nil
}

// Symlink creates newname as a symbolic link to oldname.
// If there is an error, it will be of type *LinkError.
func Symlink(oldname, newname string) error {
	e := ignoringEINTR(func() error {
		return syscall.Symlink(oldname, newname)
	})
	if e != nil {
		return &LinkError{"symlink", oldname, newname, e}
	}
	return nil
}

// Readlink returns the destination of the named symbolic link.
// If there is an error, it will be of type *PathError.
func Readlink(name string) (string, error) {
	for len := 128; ; len *= 2 {
		b := make([]byte, len)
		var (
			n int
			e error
		)
		for {
			n, e = fixCount(syscall.Readlink(name, b))
			if e != syscall.EINTR {
				break
			}
		}
		// buffer too small
		if runtime.GOOS == "aix" && e == syscall.ERANGE {
			continue
		}
		if e != nil {
			return "", &PathError{Op: "readlink", Path: name, Err: e}
		}
		if n < len {
			return string(b[0:n]), nil
		}
	}
}

type unixDirent struct {
	parent string
	name   string
	typ    FileMode
	info   FileInfo
}

func (d *unixDirent) Name() string   { return d.name }
func (d *unixDirent) IsDir() bool    { return d.typ.IsDir() }
func (d *unixDirent) Type() FileMode { return d.typ }

func (d *unixDirent) Info() (FileInfo, error) {
	if d.info != nil {
		return d.info, nil
	}
	return lstat(d.parent + "/" + d.name)
}

func newUnixDirent(parent, name string, typ FileMode) (DirEntry, error) {
	ude := &unixDirent{
		parent: parent,
		name:   name,
		typ:    typ,
	}
	if typ != ^FileMode(0) && !testingForceReadDirLstat {
		return ude, nil
	}

	info, err := lstat(parent + "/" + name)
	if err != nil {
		return nil, err
	}

	ude.typ = info.Mode().Type()
	ude.info = info
	return ude, nil
}
