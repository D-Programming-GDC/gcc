// Copyright 2020 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package poll

import (
	"internal/syscall/unix"
	"sync/atomic"
	"syscall"
)

var copyFileRangeSupported int32 = -1 // accessed atomically

const maxCopyFileRangeRound = 1 << 30

func kernelVersion() (major int, minor int) {
	var uname syscall.Utsname
	if err := syscall.Uname(&uname); err != nil {
		return
	}

	rl := uname.Release
	var values [2]int
	vi := 0
	value := 0
	for _, c := range rl {
		if '0' <= c && c <= '9' {
			value = (value * 10) + int(c-'0')
		} else {
			// Note that we're assuming N.N.N here.  If we see anything else we are likely to
			// mis-parse it.
			values[vi] = value
			vi++
			if vi >= len(values) {
				break
			}
			value = 0
		}
	}
	switch vi {
	case 0:
		return 0, 0
	case 1:
		return values[0], 0
	case 2:
		return values[0], values[1]
	}
	return
}

// CopyFileRange copies at most remain bytes of data from src to dst, using
// the copy_file_range system call. dst and src must refer to regular files.
func CopyFileRange(dst, src *FD, remain int64) (written int64, handled bool, err error) {
	if supported := atomic.LoadInt32(&copyFileRangeSupported); supported == 0 {
		return 0, false, nil
	} else if supported == -1 {
		major, minor := kernelVersion()
		if major > 5 || (major == 5 && minor >= 3) {
			atomic.StoreInt32(&copyFileRangeSupported, 1)
		} else {
			// copy_file_range(2) is broken in various ways on kernels older than 5.3,
			// see issue #42400 and
			// https://man7.org/linux/man-pages/man2/copy_file_range.2.html#VERSIONS
			atomic.StoreInt32(&copyFileRangeSupported, 0)
			return 0, false, nil
		}
	}
	for remain > 0 {
		max := remain
		if max > maxCopyFileRangeRound {
			max = maxCopyFileRangeRound
		}
		n, err := copyFileRange(dst, src, int(max))
		switch err {
		case syscall.ENOSYS:
			// copy_file_range(2) was introduced in Linux 4.5.
			// Go supports Linux >= 2.6.33, so the system call
			// may not be present.
			//
			// If we see ENOSYS, we have certainly not transfered
			// any data, so we can tell the caller that we
			// couldn't handle the transfer and let them fall
			// back to more generic code.
			//
			// Seeing ENOSYS also means that we will not try to
			// use copy_file_range(2) again.
			atomic.StoreInt32(&copyFileRangeSupported, 0)
			return 0, false, nil
		case syscall.EXDEV, syscall.EINVAL, syscall.EIO, syscall.EOPNOTSUPP, syscall.EPERM:
			// Prior to Linux 5.3, it was not possible to
			// copy_file_range across file systems. Similarly to
			// the ENOSYS case above, if we see EXDEV, we have
			// not transfered any data, and we can let the caller
			// fall back to generic code.
			//
			// As for EINVAL, that is what we see if, for example,
			// dst or src refer to a pipe rather than a regular
			// file. This is another case where no data has been
			// transfered, so we consider it unhandled.
			//
			// If src and dst are on CIFS, we can see EIO.
			// See issue #42334.
			//
			// If the file is on NFS, we can see EOPNOTSUPP.
			// See issue #40731.
			//
			// If the process is running inside a Docker container,
			// we might see EPERM instead of ENOSYS. See issue
			// #40893. Since EPERM might also be a legitimate error,
			// don't mark copy_file_range(2) as unsupported.
			return 0, false, nil
		case nil:
			if n == 0 {
				// If we did not read any bytes at all,
				// then this file may be in a file system
				// where copy_file_range silently fails.
				// https://lore.kernel.org/linux-fsdevel/20210126233840.GG4626@dread.disaster.area/T/#m05753578c7f7882f6e9ffe01f981bc223edef2b0
				if written == 0 {
					return 0, false, nil
				}
				// Otherwise src is at EOF, which means
				// we are done.
				return written, true, nil
			}
			remain -= n
			written += n
		default:
			return written, true, err
		}
	}
	return written, true, nil
}

// copyFileRange performs one round of copy_file_range(2).
func copyFileRange(dst, src *FD, max int) (written int64, err error) {
	// The signature of copy_file_range(2) is:
	//
	// ssize_t copy_file_range(int fd_in, loff_t *off_in,
	//                         int fd_out, loff_t *off_out,
	//                         size_t len, unsigned int flags);
	//
	// Note that in the call to unix.CopyFileRange below, we use nil
	// values for off_in and off_out. For the system call, this means
	// "use and update the file offsets". That is why we must acquire
	// locks for both file descriptors (and why this whole machinery is
	// in the internal/poll package to begin with).
	if err := dst.writeLock(); err != nil {
		return 0, err
	}
	defer dst.writeUnlock()
	if err := src.readLock(); err != nil {
		return 0, err
	}
	defer src.readUnlock()
	var n int
	for {
		n, err = unix.CopyFileRange(src.Sysfd, nil, dst.Sysfd, nil, max, 0)
		if err != syscall.EINTR {
			break
		}
	}
	return int64(n), err
}
