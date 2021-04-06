// Copyright 2018 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package modfetch

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"cmd/go/internal/base"
	"cmd/go/internal/cfg"
	"cmd/go/internal/lockedfile"
	"cmd/go/internal/par"
	"cmd/go/internal/renameio"
	"cmd/go/internal/robustio"
	"cmd/go/internal/trace"

	"golang.org/x/mod/module"
	"golang.org/x/mod/sumdb/dirhash"
	modzip "golang.org/x/mod/zip"
)

var downloadCache par.Cache

// Download downloads the specific module version to the
// local download cache and returns the name of the directory
// corresponding to the root of the module's file tree.
func Download(ctx context.Context, mod module.Version) (dir string, err error) {
	if cfg.GOMODCACHE == "" {
		// modload.Init exits if GOPATH[0] is empty, and cfg.GOMODCACHE
		// is set to GOPATH[0]/pkg/mod if GOMODCACHE is empty, so this should never happen.
		base.Fatalf("go: internal error: cfg.GOMODCACHE not set")
	}

	// The par.Cache here avoids duplicate work.
	type cached struct {
		dir string
		err error
	}
	c := downloadCache.Do(mod, func() interface{} {
		dir, err := download(ctx, mod)
		if err != nil {
			return cached{"", err}
		}
		checkMod(mod)
		return cached{dir, nil}
	}).(cached)
	return c.dir, c.err
}

func download(ctx context.Context, mod module.Version) (dir string, err error) {
	ctx, span := trace.StartSpan(ctx, "modfetch.download "+mod.String())
	defer span.Done()

	dir, err = DownloadDir(mod)
	if err == nil {
		// The directory has already been completely extracted (no .partial file exists).
		return dir, nil
	} else if dir == "" || !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}

	// To avoid cluttering the cache with extraneous files,
	// DownloadZip uses the same lockfile as Download.
	// Invoke DownloadZip before locking the file.
	zipfile, err := DownloadZip(ctx, mod)
	if err != nil {
		return "", err
	}

	unlock, err := lockVersion(mod)
	if err != nil {
		return "", err
	}
	defer unlock()

	ctx, span = trace.StartSpan(ctx, "unzip "+zipfile)
	defer span.Done()

	// Check whether the directory was populated while we were waiting on the lock.
	_, dirErr := DownloadDir(mod)
	if dirErr == nil {
		return dir, nil
	}
	_, dirExists := dirErr.(*DownloadDirPartialError)

	// Clean up any remaining temporary directories created by old versions
	// (before 1.16), as well as partially extracted directories (indicated by
	// DownloadDirPartialError, usually because of a .partial file). This is only
	// safe to do because the lock file ensures that their writers are no longer
	// active.
	parentDir := filepath.Dir(dir)
	tmpPrefix := filepath.Base(dir) + ".tmp-"
	if old, err := filepath.Glob(filepath.Join(parentDir, tmpPrefix+"*")); err == nil {
		for _, path := range old {
			RemoveAll(path) // best effort
		}
	}
	if dirExists {
		if err := RemoveAll(dir); err != nil {
			return "", err
		}
	}

	partialPath, err := CachePath(mod, "partial")
	if err != nil {
		return "", err
	}

	// Extract the module zip directory at its final location.
	//
	// To prevent other processes from reading the directory if we crash,
	// create a .partial file before extracting the directory, and delete
	// the .partial file afterward (all while holding the lock).
	//
	// Before Go 1.16, we extracted to a temporary directory with a random name
	// then renamed it into place with os.Rename. On Windows, this failed with
	// ERROR_ACCESS_DENIED when another process (usually an anti-virus scanner)
	// opened files in the temporary directory.
	//
	// Go 1.14.2 and higher respect .partial files. Older versions may use
	// partially extracted directories. 'go mod verify' can detect this,
	// and 'go clean -modcache' can fix it.
	if err := os.MkdirAll(parentDir, 0777); err != nil {
		return "", err
	}
	if err := os.WriteFile(partialPath, nil, 0666); err != nil {
		return "", err
	}
	if err := modzip.Unzip(dir, mod, zipfile); err != nil {
		fmt.Fprintf(os.Stderr, "-> %s\n", err)
		if rmErr := RemoveAll(dir); rmErr == nil {
			os.Remove(partialPath)
		}
		return "", err
	}
	if err := os.Remove(partialPath); err != nil {
		return "", err
	}

	if !cfg.ModCacheRW {
		makeDirsReadOnly(dir)
	}
	return dir, nil
}

var downloadZipCache par.Cache

// DownloadZip downloads the specific module version to the
// local zip cache and returns the name of the zip file.
func DownloadZip(ctx context.Context, mod module.Version) (zipfile string, err error) {
	// The par.Cache here avoids duplicate work.
	type cached struct {
		zipfile string
		err     error
	}
	c := downloadZipCache.Do(mod, func() interface{} {
		zipfile, err := CachePath(mod, "zip")
		if err != nil {
			return cached{"", err}
		}

		// Skip locking if the zipfile already exists.
		if _, err := os.Stat(zipfile); err == nil {
			return cached{zipfile, nil}
		}

		// The zip file does not exist. Acquire the lock and create it.
		if cfg.CmdName != "mod download" {
			fmt.Fprintf(os.Stderr, "go: downloading %s %s\n", mod.Path, mod.Version)
		}
		unlock, err := lockVersion(mod)
		if err != nil {
			return cached{"", err}
		}
		defer unlock()

		// Double-check that the zipfile was not created while we were waiting for
		// the lock.
		if _, err := os.Stat(zipfile); err == nil {
			return cached{zipfile, nil}
		}
		if err := os.MkdirAll(filepath.Dir(zipfile), 0777); err != nil {
			return cached{"", err}
		}
		if err := downloadZip(ctx, mod, zipfile); err != nil {
			return cached{"", err}
		}
		return cached{zipfile, nil}
	}).(cached)
	return c.zipfile, c.err
}

func downloadZip(ctx context.Context, mod module.Version, zipfile string) (err error) {
	ctx, span := trace.StartSpan(ctx, "modfetch.downloadZip "+zipfile)
	defer span.Done()

	// Clean up any remaining tempfiles from previous runs.
	// This is only safe to do because the lock file ensures that their
	// writers are no longer active.
	for _, base := range []string{zipfile, zipfile + "hash"} {
		if old, err := filepath.Glob(renameio.Pattern(base)); err == nil {
			for _, path := range old {
				os.Remove(path) // best effort
			}
		}
	}

	// From here to the os.Rename call below is functionally almost equivalent to
	// renameio.WriteToFile, with one key difference: we want to validate the
	// contents of the file (by hashing it) before we commit it. Because the file
	// is zip-compressed, we need an actual file — or at least an io.ReaderAt — to
	// validate it: we can't just tee the stream as we write it.
	f, err := os.CreateTemp(filepath.Dir(zipfile), filepath.Base(renameio.Pattern(zipfile)))
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			f.Close()
			os.Remove(f.Name())
		}
	}()

	var unrecoverableErr error
	err = TryProxies(func(proxy string) error {
		if unrecoverableErr != nil {
			return unrecoverableErr
		}
		repo := Lookup(proxy, mod.Path)
		err := repo.Zip(f, mod.Version)
		if err != nil {
			// Zip may have partially written to f before failing.
			// (Perhaps the server crashed while sending the file?)
			// Since we allow fallback on error in some cases, we need to fix up the
			// file to be empty again for the next attempt.
			if _, err := f.Seek(0, io.SeekStart); err != nil {
				unrecoverableErr = err
				return err
			}
			if err := f.Truncate(0); err != nil {
				unrecoverableErr = err
				return err
			}
		}
		return err
	})
	if err != nil {
		return err
	}

	// Double-check that the paths within the zip file are well-formed.
	//
	// TODO(bcmills): There is a similar check within the Unzip function. Can we eliminate one?
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	z, err := zip.NewReader(f, fi.Size())
	if err != nil {
		return err
	}
	prefix := mod.Path + "@" + mod.Version + "/"
	for _, f := range z.File {
		if !strings.HasPrefix(f.Name, prefix) {
			return fmt.Errorf("zip for %s has unexpected file %s", prefix[:len(prefix)-1], f.Name)
		}
	}

	// Sync the file before renaming it: otherwise, after a crash the reader may
	// observe a 0-length file instead of the actual contents.
	// See https://golang.org/issue/22397#issuecomment-380831736.
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}

	// Hash the zip file and check the sum before renaming to the final location.
	hash, err := dirhash.HashZip(f.Name(), dirhash.DefaultHash)
	if err != nil {
		return err
	}
	if err := checkModSum(mod, hash); err != nil {
		return err
	}

	if err := renameio.WriteFile(zipfile+"hash", []byte(hash), 0666); err != nil {
		return err
	}
	if err := os.Rename(f.Name(), zipfile); err != nil {
		return err
	}

	// TODO(bcmills): Should we make the .zip and .ziphash files read-only to discourage tampering?

	return nil
}

// makeDirsReadOnly makes a best-effort attempt to remove write permissions for dir
// and its transitive contents.
func makeDirsReadOnly(dir string) {
	type pathMode struct {
		path string
		mode fs.FileMode
	}
	var dirs []pathMode // in lexical order
	filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			info, err := d.Info()
			if err == nil && info.Mode()&0222 != 0 {
				dirs = append(dirs, pathMode{path, info.Mode()})
			}
		}
		return nil
	})

	// Run over list backward to chmod children before parents.
	for i := len(dirs) - 1; i >= 0; i-- {
		os.Chmod(dirs[i].path, dirs[i].mode&^0222)
	}
}

// RemoveAll removes a directory written by Download or Unzip, first applying
// any permission changes needed to do so.
func RemoveAll(dir string) error {
	// Module cache has 0555 directories; make them writable in order to remove content.
	filepath.WalkDir(dir, func(path string, info fs.DirEntry, err error) error {
		if err != nil {
			return nil // ignore errors walking in file system
		}
		if info.IsDir() {
			os.Chmod(path, 0777)
		}
		return nil
	})
	return robustio.RemoveAll(dir)
}

var GoSumFile string // path to go.sum; set by package modload

type modSum struct {
	mod module.Version
	sum string
}

var goSum struct {
	mu        sync.Mutex
	m         map[module.Version][]string // content of go.sum file
	status    map[modSum]modSumStatus     // state of sums in m
	overwrite bool                        // if true, overwrite go.sum without incorporating its contents
	enabled   bool                        // whether to use go.sum at all
}

type modSumStatus struct {
	used, dirty bool
}

// initGoSum initializes the go.sum data.
// The boolean it returns reports whether the
// use of go.sum is now enabled.
// The goSum lock must be held.
func initGoSum() (bool, error) {
	if GoSumFile == "" {
		return false, nil
	}
	if goSum.m != nil {
		return true, nil
	}

	goSum.m = make(map[module.Version][]string)
	goSum.status = make(map[modSum]modSumStatus)
	data, err := lockedfile.Read(GoSumFile)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	goSum.enabled = true
	readGoSum(goSum.m, GoSumFile, data)

	return true, nil
}

// emptyGoModHash is the hash of a 1-file tree containing a 0-length go.mod.
// A bug caused us to write these into go.sum files for non-modules.
// We detect and remove them.
const emptyGoModHash = "h1:G7mAYYxgmS0lVkHyy2hEOLQCFB0DlQFTMLWggykrydY="

// readGoSum parses data, which is the content of file,
// and adds it to goSum.m. The goSum lock must be held.
func readGoSum(dst map[module.Version][]string, file string, data []byte) error {
	lineno := 0
	for len(data) > 0 {
		var line []byte
		lineno++
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			line, data = data, nil
		} else {
			line, data = data[:i], data[i+1:]
		}
		f := strings.Fields(string(line))
		if len(f) == 0 {
			// blank line; skip it
			continue
		}
		if len(f) != 3 {
			return fmt.Errorf("malformed go.sum:\n%s:%d: wrong number of fields %v", file, lineno, len(f))
		}
		if f[2] == emptyGoModHash {
			// Old bug; drop it.
			continue
		}
		mod := module.Version{Path: f[0], Version: f[1]}
		dst[mod] = append(dst[mod], f[2])
	}
	return nil
}

// HaveSum returns true if the go.sum file contains an entry for mod.
// The entry's hash must be generated with a known hash algorithm.
// mod.Version may have a "/go.mod" suffix to distinguish sums for
// .mod and .zip files.
func HaveSum(mod module.Version) bool {
	goSum.mu.Lock()
	defer goSum.mu.Unlock()
	inited, err := initGoSum()
	if err != nil || !inited {
		return false
	}
	for _, h := range goSum.m[mod] {
		if !strings.HasPrefix(h, "h1:") {
			continue
		}
		if !goSum.status[modSum{mod, h}].dirty {
			return true
		}
	}
	return false
}

// checkMod checks the given module's checksum.
func checkMod(mod module.Version) {
	if cfg.GOMODCACHE == "" {
		// Do not use current directory.
		return
	}

	// Do the file I/O before acquiring the go.sum lock.
	ziphash, err := CachePath(mod, "ziphash")
	if err != nil {
		base.Fatalf("verifying %v", module.VersionError(mod, err))
	}
	data, err := renameio.ReadFile(ziphash)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			// This can happen if someone does rm -rf GOPATH/src/cache/download. So it goes.
			return
		}
		base.Fatalf("verifying %v", module.VersionError(mod, err))
	}
	h := strings.TrimSpace(string(data))
	if !strings.HasPrefix(h, "h1:") {
		base.Fatalf("verifying %v", module.VersionError(mod, fmt.Errorf("unexpected ziphash: %q", h)))
	}

	if err := checkModSum(mod, h); err != nil {
		base.Fatalf("%s", err)
	}
}

// goModSum returns the checksum for the go.mod contents.
func goModSum(data []byte) (string, error) {
	return dirhash.Hash1([]string{"go.mod"}, func(string) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(data)), nil
	})
}

// checkGoMod checks the given module's go.mod checksum;
// data is the go.mod content.
func checkGoMod(path, version string, data []byte) error {
	h, err := goModSum(data)
	if err != nil {
		return &module.ModuleError{Path: path, Version: version, Err: fmt.Errorf("verifying go.mod: %v", err)}
	}

	return checkModSum(module.Version{Path: path, Version: version + "/go.mod"}, h)
}

// checkModSum checks that the recorded checksum for mod is h.
//
// mod.Version may have the additional suffix "/go.mod" to request the checksum
// for the module's go.mod file only.
func checkModSum(mod module.Version, h string) error {
	// We lock goSum when manipulating it,
	// but we arrange to release the lock when calling checkSumDB,
	// so that parallel calls to checkModHash can execute parallel calls
	// to checkSumDB.

	// Check whether mod+h is listed in go.sum already. If so, we're done.
	goSum.mu.Lock()
	inited, err := initGoSum()
	if err != nil {
		goSum.mu.Unlock()
		return err
	}
	done := inited && haveModSumLocked(mod, h)
	if inited {
		st := goSum.status[modSum{mod, h}]
		st.used = true
		goSum.status[modSum{mod, h}] = st
	}
	goSum.mu.Unlock()

	if done {
		return nil
	}

	// Not listed, so we want to add them.
	// Consult checksum database if appropriate.
	if useSumDB(mod) {
		// Calls base.Fatalf if mismatch detected.
		if err := checkSumDB(mod, h); err != nil {
			return err
		}
	}

	// Add mod+h to go.sum, if it hasn't appeared already.
	if inited {
		goSum.mu.Lock()
		addModSumLocked(mod, h)
		st := goSum.status[modSum{mod, h}]
		st.dirty = true
		goSum.status[modSum{mod, h}] = st
		goSum.mu.Unlock()
	}
	return nil
}

// haveModSumLocked reports whether the pair mod,h is already listed in go.sum.
// If it finds a conflicting pair instead, it calls base.Fatalf.
// goSum.mu must be locked.
func haveModSumLocked(mod module.Version, h string) bool {
	for _, vh := range goSum.m[mod] {
		if h == vh {
			return true
		}
		if strings.HasPrefix(vh, "h1:") {
			base.Fatalf("verifying %s@%s: checksum mismatch\n\tdownloaded: %v\n\tgo.sum:     %v"+goSumMismatch, mod.Path, mod.Version, h, vh)
		}
	}
	return false
}

// addModSumLocked adds the pair mod,h to go.sum.
// goSum.mu must be locked.
func addModSumLocked(mod module.Version, h string) {
	if haveModSumLocked(mod, h) {
		return
	}
	if len(goSum.m[mod]) > 0 {
		fmt.Fprintf(os.Stderr, "warning: verifying %s@%s: unknown hashes in go.sum: %v; adding %v"+hashVersionMismatch, mod.Path, mod.Version, strings.Join(goSum.m[mod], ", "), h)
	}
	goSum.m[mod] = append(goSum.m[mod], h)
}

// checkSumDB checks the mod, h pair against the Go checksum database.
// It calls base.Fatalf if the hash is to be rejected.
func checkSumDB(mod module.Version, h string) error {
	modWithoutSuffix := mod
	noun := "module"
	if strings.HasSuffix(mod.Version, "/go.mod") {
		noun = "go.mod"
		modWithoutSuffix.Version = strings.TrimSuffix(mod.Version, "/go.mod")
	}

	db, lines, err := lookupSumDB(mod)
	if err != nil {
		return module.VersionError(modWithoutSuffix, fmt.Errorf("verifying %s: %v", noun, err))
	}

	have := mod.Path + " " + mod.Version + " " + h
	prefix := mod.Path + " " + mod.Version + " h1:"
	for _, line := range lines {
		if line == have {
			return nil
		}
		if strings.HasPrefix(line, prefix) {
			return module.VersionError(modWithoutSuffix, fmt.Errorf("verifying %s: checksum mismatch\n\tdownloaded: %v\n\t%s: %v"+sumdbMismatch, noun, h, db, line[len(prefix)-len("h1:"):]))
		}
	}
	return nil
}

// Sum returns the checksum for the downloaded copy of the given module,
// if present in the download cache.
func Sum(mod module.Version) string {
	if cfg.GOMODCACHE == "" {
		// Do not use current directory.
		return ""
	}

	ziphash, err := CachePath(mod, "ziphash")
	if err != nil {
		return ""
	}
	data, err := renameio.ReadFile(ziphash)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// WriteGoSum writes the go.sum file if it needs to be updated.
//
// keep is used to check whether a newly added sum should be saved in go.sum.
// It should have entries for both module content sums and go.mod sums
// (version ends with "/go.mod"). Existing sums will be preserved unless they
// have been marked for deletion with TrimGoSum.
func WriteGoSum(keep map[module.Version]bool) {
	goSum.mu.Lock()
	defer goSum.mu.Unlock()

	// If we haven't read the go.sum file yet, don't bother writing it.
	if !goSum.enabled {
		return
	}

	// Check whether we need to add sums for which keep[m] is true or remove
	// unused sums marked with TrimGoSum. If there are no changes to make,
	// just return without opening go.sum.
	dirty := false
Outer:
	for m, hs := range goSum.m {
		for _, h := range hs {
			st := goSum.status[modSum{m, h}]
			if st.dirty && (!st.used || keep[m]) {
				dirty = true
				break Outer
			}
		}
	}
	if !dirty {
		return
	}
	if cfg.BuildMod == "readonly" {
		base.Fatalf("go: updates to go.sum needed, disabled by -mod=readonly")
	}

	// Make a best-effort attempt to acquire the side lock, only to exclude
	// previous versions of the 'go' command from making simultaneous edits.
	if unlock, err := SideLock(); err == nil {
		defer unlock()
	}

	err := lockedfile.Transform(GoSumFile, func(data []byte) ([]byte, error) {
		if !goSum.overwrite {
			// Incorporate any sums added by other processes in the meantime.
			// Add only the sums that we actually checked: the user may have edited or
			// truncated the file to remove erroneous hashes, and we shouldn't restore
			// them without good reason.
			goSum.m = make(map[module.Version][]string, len(goSum.m))
			readGoSum(goSum.m, GoSumFile, data)
			for ms, st := range goSum.status {
				if st.used {
					addModSumLocked(ms.mod, ms.sum)
				}
			}
		}

		var mods []module.Version
		for m := range goSum.m {
			mods = append(mods, m)
		}
		module.Sort(mods)

		var buf bytes.Buffer
		for _, m := range mods {
			list := goSum.m[m]
			sort.Strings(list)
			for _, h := range list {
				st := goSum.status[modSum{m, h}]
				if !st.dirty || (st.used && keep[m]) {
					fmt.Fprintf(&buf, "%s %s %s\n", m.Path, m.Version, h)
				}
			}
		}
		return buf.Bytes(), nil
	})

	if err != nil {
		base.Fatalf("go: updating go.sum: %v", err)
	}

	goSum.status = make(map[modSum]modSumStatus)
	goSum.overwrite = false
}

// TrimGoSum trims go.sum to contain only the modules needed for reproducible
// builds.
//
// keep is used to check whether a sum should be retained in go.mod. It should
// have entries for both module content sums and go.mod sums (version ends
// with "/go.mod").
func TrimGoSum(keep map[module.Version]bool) {
	goSum.mu.Lock()
	defer goSum.mu.Unlock()
	inited, err := initGoSum()
	if err != nil {
		base.Fatalf("%s", err)
	}
	if !inited {
		return
	}

	for m, hs := range goSum.m {
		if !keep[m] {
			for _, h := range hs {
				goSum.status[modSum{m, h}] = modSumStatus{used: false, dirty: true}
			}
			goSum.overwrite = true
		}
	}
}

const goSumMismatch = `

SECURITY ERROR
This download does NOT match an earlier download recorded in go.sum.
The bits may have been replaced on the origin server, or an attacker may
have intercepted the download attempt.

For more information, see 'go help module-auth'.
`

const sumdbMismatch = `

SECURITY ERROR
This download does NOT match the one reported by the checksum server.
The bits may have been replaced on the origin server, or an attacker may
have intercepted the download attempt.

For more information, see 'go help module-auth'.
`

const hashVersionMismatch = `

SECURITY WARNING
This download is listed in go.sum, but using an unknown hash algorithm.
The download cannot be verified.

For more information, see 'go help module-auth'.

`

var HelpModuleAuth = &base.Command{
	UsageLine: "module-auth",
	Short:     "module authentication using go.sum",
	Long: `
When the go command downloads a module zip file or go.mod file into the
module cache, it computes a cryptographic hash and compares it with a known
value to verify the file hasn't changed since it was first downloaded. Known
hashes are stored in a file in the module root directory named go.sum. Hashes
may also be downloaded from the checksum database depending on the values of
GOSUMDB, GOPRIVATE, and GONOSUMDB.

For details, see https://golang.org/ref/mod#authenticating.
`,
}

var HelpPrivate = &base.Command{
	UsageLine: "private",
	Short:     "configuration for downloading non-public code",
	Long: `
The go command defaults to downloading modules from the public Go module
mirror at proxy.golang.org. It also defaults to validating downloaded modules,
regardless of source, against the public Go checksum database at sum.golang.org.
These defaults work well for publicly available source code.

The GOPRIVATE environment variable controls which modules the go command
considers to be private (not available publicly) and should therefore not use
the proxy or checksum database. The variable is a comma-separated list of
glob patterns (in the syntax of Go's path.Match) of module path prefixes.
For example,

	GOPRIVATE=*.corp.example.com,rsc.io/private

causes the go command to treat as private any module with a path prefix
matching either pattern, including git.corp.example.com/xyzzy, rsc.io/private,
and rsc.io/private/quux.

For fine-grained control over module download and validation, the GONOPROXY
and GONOSUMDB environment variables accept the same kind of glob list
and override GOPRIVATE for the specific decision of whether to use the proxy
and checksum database, respectively.

For example, if a company ran a module proxy serving private modules,
users would configure go using:

	GOPRIVATE=*.corp.example.com
	GOPROXY=proxy.example.com
	GONOPROXY=none

The GOPRIVATE variable is also used to define the "public" and "private"
patterns for the GOVCS variable; see 'go help vcs'. For that usage,
GOPRIVATE applies even in GOPATH mode. In that case, it matches import paths
instead of module paths.

The 'go env -w' command (see 'go help env') can be used to set these variables
for future go command invocations.

For more details, see https://golang.org/ref/mod#private-modules.
`,
}
