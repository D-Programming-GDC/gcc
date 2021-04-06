// Copyright 2018 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package modload

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	pathpkg "path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"cmd/go/internal/cfg"
	"cmd/go/internal/imports"
	"cmd/go/internal/modfetch"
	"cmd/go/internal/search"
	"cmd/go/internal/str"
	"cmd/go/internal/trace"

	"golang.org/x/mod/module"
	"golang.org/x/mod/semver"
)

// Query looks up a revision of a given module given a version query string.
// The module must be a complete module path.
// The version must take one of the following forms:
//
// - the literal string "latest", denoting the latest available, allowed
//   tagged version, with non-prereleases preferred over prereleases.
//   If there are no tagged versions in the repo, latest returns the most
//   recent commit.
// - the literal string "upgrade", equivalent to "latest" except that if
//   current is a newer version, current will be returned (see below).
// - the literal string "patch", denoting the latest available tagged version
//   with the same major and minor number as current (see below).
// - v1, denoting the latest available tagged version v1.x.x.
// - v1.2, denoting the latest available tagged version v1.2.x.
// - v1.2.3, a semantic version string denoting that tagged version.
// - <v1.2.3, <=v1.2.3, >v1.2.3, >=v1.2.3,
//   denoting the version closest to the target and satisfying the given operator,
//   with non-prereleases preferred over prereleases.
// - a repository commit identifier or tag, denoting that commit.
//
// current denotes the currently-selected version of the module; it may be
// "none" if no version is currently selected, or "" if the currently-selected
// version is unknown or should not be considered. If query is
// "upgrade" or "patch", current will be returned if it is a newer
// semantic version or a chronologically later pseudo-version than the
// version that would otherwise be chosen. This prevents accidental downgrades
// from newer pre-release or development versions.
//
// The allowed function (which may be nil) is used to filter out unsuitable
// versions (see AllowedFunc documentation for details). If the query refers to
// a specific revision (for example, "master"; see IsRevisionQuery), and the
// revision is disallowed by allowed, Query returns the error. If the query
// does not refer to a specific revision (for example, "latest"), Query
// acts as if versions disallowed by allowed do not exist.
//
// If path is the path of the main module and the query is "latest",
// Query returns Target.Version as the version.
func Query(ctx context.Context, path, query, current string, allowed AllowedFunc) (*modfetch.RevInfo, error) {
	var info *modfetch.RevInfo
	err := modfetch.TryProxies(func(proxy string) (err error) {
		info, err = queryProxy(ctx, proxy, path, query, current, allowed)
		return err
	})
	return info, err
}

// AllowedFunc is used by Query and other functions to filter out unsuitable
// versions, for example, those listed in exclude directives in the main
// module's go.mod file.
//
// An AllowedFunc returns an error equivalent to ErrDisallowed for an unsuitable
// version. Any other error indicates the function was unable to determine
// whether the version should be allowed, for example, the function was unable
// to fetch or parse a go.mod file containing retractions. Typically, errors
// other than ErrDisallowd may be ignored.
type AllowedFunc func(context.Context, module.Version) error

var errQueryDisabled error = queryDisabledError{}

type queryDisabledError struct{}

func (queryDisabledError) Error() string {
	if cfg.BuildModReason == "" {
		return fmt.Sprintf("cannot query module due to -mod=%s", cfg.BuildMod)
	}
	return fmt.Sprintf("cannot query module due to -mod=%s\n\t(%s)", cfg.BuildMod, cfg.BuildModReason)
}

func queryProxy(ctx context.Context, proxy, path, query, current string, allowed AllowedFunc) (*modfetch.RevInfo, error) {
	ctx, span := trace.StartSpan(ctx, "modload.queryProxy "+path+" "+query)
	defer span.Done()

	if current != "" && current != "none" && !semver.IsValid(current) {
		return nil, fmt.Errorf("invalid previous version %q", current)
	}
	if cfg.BuildMod == "vendor" {
		return nil, errQueryDisabled
	}
	if allowed == nil {
		allowed = func(context.Context, module.Version) error { return nil }
	}

	if path == Target.Path && (query == "upgrade" || query == "patch") {
		if err := allowed(ctx, Target); err != nil {
			return nil, fmt.Errorf("internal error: main module version is not allowed: %w", err)
		}
		return &modfetch.RevInfo{Version: Target.Version}, nil
	}

	if path == "std" || path == "cmd" {
		return nil, fmt.Errorf("can't query specific version (%q) of standard-library module %q", query, path)
	}

	repo, err := lookupRepo(proxy, path)
	if err != nil {
		return nil, err
	}

	// Parse query to detect parse errors (and possibly handle query)
	// before any network I/O.
	qm, err := newQueryMatcher(path, query, current, allowed)
	if (err == nil && qm.canStat) || err == errRevQuery {
		// Direct lookup of a commit identifier or complete (non-prefix) semantic
		// version.

		// If the identifier is not a canonical semver tag — including if it's a
		// semver tag with a +metadata suffix — then modfetch.Stat will populate
		// info.Version with a suitable pseudo-version.
		info, err := repo.Stat(query)
		if err != nil {
			queryErr := err
			// The full query doesn't correspond to a tag. If it is a semantic version
			// with a +metadata suffix, see if there is a tag without that suffix:
			// semantic versioning defines them to be equivalent.
			canonicalQuery := module.CanonicalVersion(query)
			if canonicalQuery != "" && query != canonicalQuery {
				info, err = repo.Stat(canonicalQuery)
				if err != nil && !errors.Is(err, fs.ErrNotExist) {
					return info, err
				}
			}
			if err != nil {
				return nil, queryErr
			}
		}
		if err := allowed(ctx, module.Version{Path: path, Version: info.Version}); errors.Is(err, ErrDisallowed) {
			return nil, err
		}
		return info, nil
	} else if err != nil {
		return nil, err
	}

	// Load versions and execute query.
	versions, err := repo.Versions(qm.prefix)
	if err != nil {
		return nil, err
	}
	releases, prereleases, err := qm.filterVersions(ctx, versions)
	if err != nil {
		return nil, err
	}

	lookup := func(v string) (*modfetch.RevInfo, error) {
		rev, err := repo.Stat(v)
		if err != nil {
			return nil, err
		}

		if (query == "upgrade" || query == "patch") && modfetch.IsPseudoVersion(current) && !rev.Time.IsZero() {
			// Don't allow "upgrade" or "patch" to move from a pseudo-version
			// to a chronologically older version or pseudo-version.
			//
			// If the current version is a pseudo-version from an untagged branch, it
			// may be semantically lower than the "latest" release or the latest
			// pseudo-version on the main branch. A user on such a version is unlikely
			// to intend to “upgrade” to a version that already existed at that point
			// in time.
			//
			// We do this only if the current version is a pseudo-version: if the
			// version is tagged, the author of the dependency module has given us
			// explicit information about their intended precedence of this version
			// relative to other versions, and we shouldn't contradict that
			// information. (For example, v1.0.1 might be a backport of a fix already
			// incorporated into v1.1.0, in which case v1.0.1 would be chronologically
			// newer but v1.1.0 is still an “upgrade”; or v1.0.2 might be a revert of
			// an unsuccessful fix in v1.0.1, in which case the v1.0.2 commit may be
			// older than the v1.0.1 commit despite the tag itself being newer.)
			currentTime, err := modfetch.PseudoVersionTime(current)
			if err == nil && rev.Time.Before(currentTime) {
				if err := allowed(ctx, module.Version{Path: path, Version: current}); errors.Is(err, ErrDisallowed) {
					return nil, err
				}
				return repo.Stat(current)
			}
		}

		return rev, nil
	}

	if qm.preferLower {
		if len(releases) > 0 {
			return lookup(releases[0])
		}
		if len(prereleases) > 0 {
			return lookup(prereleases[0])
		}
	} else {
		if len(releases) > 0 {
			return lookup(releases[len(releases)-1])
		}
		if len(prereleases) > 0 {
			return lookup(prereleases[len(prereleases)-1])
		}
	}

	if qm.mayUseLatest {
		latest, err := repo.Latest()
		if err == nil {
			if qm.allowsVersion(ctx, latest.Version) {
				return lookup(latest.Version)
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
	}

	if (query == "upgrade" || query == "patch") && current != "" && current != "none" {
		// "upgrade" and "patch" may stay on the current version if allowed.
		if err := allowed(ctx, module.Version{Path: path, Version: current}); errors.Is(err, ErrDisallowed) {
			return nil, err
		}
		return lookup(current)
	}

	return nil, &NoMatchingVersionError{query: query, current: current}
}

// IsRevisionQuery returns true if vers is a version query that may refer to
// a particular version or revision in a repository like "v1.0.0", "master",
// or "0123abcd". IsRevisionQuery returns false if vers is a query that
// chooses from among available versions like "latest" or ">v1.0.0".
func IsRevisionQuery(vers string) bool {
	if vers == "latest" ||
		vers == "upgrade" ||
		vers == "patch" ||
		strings.HasPrefix(vers, "<") ||
		strings.HasPrefix(vers, ">") ||
		(semver.IsValid(vers) && isSemverPrefix(vers)) {
		return false
	}
	return true
}

// isSemverPrefix reports whether v is a semantic version prefix: v1 or v1.2 (not v1.2.3).
// The caller is assumed to have checked that semver.IsValid(v) is true.
func isSemverPrefix(v string) bool {
	dots := 0
	for i := 0; i < len(v); i++ {
		switch v[i] {
		case '-', '+':
			return false
		case '.':
			dots++
			if dots >= 2 {
				return false
			}
		}
	}
	return true
}

type queryMatcher struct {
	path               string
	prefix             string
	filter             func(version string) bool
	allowed            AllowedFunc
	canStat            bool // if true, the query can be resolved by repo.Stat
	preferLower        bool // if true, choose the lowest matching version
	mayUseLatest       bool
	preferIncompatible bool
}

var errRevQuery = errors.New("query refers to a non-semver revision")

// newQueryMatcher returns a new queryMatcher that matches the versions
// specified by the given query on the module with the given path.
//
// If the query can only be resolved by statting a non-SemVer revision,
// newQueryMatcher returns errRevQuery.
func newQueryMatcher(path string, query, current string, allowed AllowedFunc) (*queryMatcher, error) {
	badVersion := func(v string) (*queryMatcher, error) {
		return nil, fmt.Errorf("invalid semantic version %q in range %q", v, query)
	}

	matchesMajor := func(v string) bool {
		_, pathMajor, ok := module.SplitPathVersion(path)
		if !ok {
			return false
		}
		return module.CheckPathMajor(v, pathMajor) == nil
	}

	qm := &queryMatcher{
		path:               path,
		allowed:            allowed,
		preferIncompatible: strings.HasSuffix(current, "+incompatible"),
	}

	switch {
	case query == "latest":
		qm.mayUseLatest = true

	case query == "upgrade":
		if current == "" || current == "none" {
			qm.mayUseLatest = true
		} else {
			qm.mayUseLatest = modfetch.IsPseudoVersion(current)
			qm.filter = func(mv string) bool { return semver.Compare(mv, current) >= 0 }
		}

	case query == "patch":
		if current == "none" {
			return nil, &NoPatchBaseError{path}
		}
		if current == "" {
			qm.mayUseLatest = true
		} else {
			qm.mayUseLatest = modfetch.IsPseudoVersion(current)
			qm.prefix = semver.MajorMinor(current) + "."
			qm.filter = func(mv string) bool { return semver.Compare(mv, current) >= 0 }
		}

	case strings.HasPrefix(query, "<="):
		v := query[len("<="):]
		if !semver.IsValid(v) {
			return badVersion(v)
		}
		if isSemverPrefix(v) {
			// Refuse to say whether <=v1.2 allows v1.2.3 (remember, @v1.2 might mean v1.2.3).
			return nil, fmt.Errorf("ambiguous semantic version %q in range %q", v, query)
		}
		qm.filter = func(mv string) bool { return semver.Compare(mv, v) <= 0 }
		if !matchesMajor(v) {
			qm.preferIncompatible = true
		}

	case strings.HasPrefix(query, "<"):
		v := query[len("<"):]
		if !semver.IsValid(v) {
			return badVersion(v)
		}
		qm.filter = func(mv string) bool { return semver.Compare(mv, v) < 0 }
		if !matchesMajor(v) {
			qm.preferIncompatible = true
		}

	case strings.HasPrefix(query, ">="):
		v := query[len(">="):]
		if !semver.IsValid(v) {
			return badVersion(v)
		}
		qm.filter = func(mv string) bool { return semver.Compare(mv, v) >= 0 }
		qm.preferLower = true
		if !matchesMajor(v) {
			qm.preferIncompatible = true
		}

	case strings.HasPrefix(query, ">"):
		v := query[len(">"):]
		if !semver.IsValid(v) {
			return badVersion(v)
		}
		if isSemverPrefix(v) {
			// Refuse to say whether >v1.2 allows v1.2.3 (remember, @v1.2 might mean v1.2.3).
			return nil, fmt.Errorf("ambiguous semantic version %q in range %q", v, query)
		}
		qm.filter = func(mv string) bool { return semver.Compare(mv, v) > 0 }
		qm.preferLower = true
		if !matchesMajor(v) {
			qm.preferIncompatible = true
		}

	case semver.IsValid(query):
		if isSemverPrefix(query) {
			qm.prefix = query + "."
			// Do not allow the query "v1.2" to match versions lower than "v1.2.0",
			// such as prereleases for that version. (https://golang.org/issue/31972)
			qm.filter = func(mv string) bool { return semver.Compare(mv, query) >= 0 }
		} else {
			qm.canStat = true
			qm.filter = func(mv string) bool { return semver.Compare(mv, query) == 0 }
			qm.prefix = semver.Canonical(query)
		}
		if !matchesMajor(query) {
			qm.preferIncompatible = true
		}

	default:
		return nil, errRevQuery
	}

	return qm, nil
}

// allowsVersion reports whether version v is allowed by the prefix, filter, and
// AllowedFunc of qm.
func (qm *queryMatcher) allowsVersion(ctx context.Context, v string) bool {
	if qm.prefix != "" && !strings.HasPrefix(v, qm.prefix) {
		return false
	}
	if qm.filter != nil && !qm.filter(v) {
		return false
	}
	if qm.allowed != nil {
		if err := qm.allowed(ctx, module.Version{Path: qm.path, Version: v}); errors.Is(err, ErrDisallowed) {
			return false
		}
	}
	return true
}

// filterVersions classifies versions into releases and pre-releases, filtering
// out:
// 	1. versions that do not satisfy the 'allowed' predicate, and
// 	2. "+incompatible" versions, if a compatible one satisfies the predicate
// 	   and the incompatible version is not preferred.
//
// If the allowed predicate returns an error not equivalent to ErrDisallowed,
// filterVersions returns that error.
func (qm *queryMatcher) filterVersions(ctx context.Context, versions []string) (releases, prereleases []string, err error) {
	needIncompatible := qm.preferIncompatible

	var lastCompatible string
	for _, v := range versions {
		if !qm.allowsVersion(ctx, v) {
			continue
		}

		if !needIncompatible {
			// We're not yet sure whether we need to include +incomptaible versions.
			// Keep track of the last compatible version we've seen, and use the
			// presence (or absence) of a go.mod file in that version to decide: a
			// go.mod file implies that the module author is supporting modules at a
			// compatible version (and we should ignore +incompatible versions unless
			// requested explicitly), while a lack of go.mod file implies the
			// potential for legacy (pre-modules) versioning without semantic import
			// paths (and thus *with* +incompatible versions).
			//
			// This isn't strictly accurate if the latest compatible version has been
			// replaced by a local file path, because we do not allow file-path
			// replacements without a go.mod file: the user would have needed to add
			// one. However, replacing the last compatible version while
			// simultaneously expecting to upgrade implicitly to a +incompatible
			// version seems like an extreme enough corner case to ignore for now.

			if !strings.HasSuffix(v, "+incompatible") {
				lastCompatible = v
			} else if lastCompatible != "" {
				// If the latest compatible version is allowed and has a go.mod file,
				// ignore any version with a higher (+incompatible) major version. (See
				// https://golang.org/issue/34165.) Note that we even prefer a
				// compatible pre-release over an incompatible release.
				ok, err := versionHasGoMod(ctx, module.Version{Path: qm.path, Version: lastCompatible})
				if err != nil {
					return nil, nil, err
				}
				if ok {
					// The last compatible version has a go.mod file, so that's the
					// highest version we're willing to consider. Don't bother even
					// looking at higher versions, because they're all +incompatible from
					// here onward.
					break
				}

				// No acceptable compatible release has a go.mod file, so the versioning
				// for the module might not be module-aware, and we should respect
				// legacy major-version tags.
				needIncompatible = true
			}
		}

		if semver.Prerelease(v) != "" {
			prereleases = append(prereleases, v)
		} else {
			releases = append(releases, v)
		}
	}

	return releases, prereleases, nil
}

type QueryResult struct {
	Mod      module.Version
	Rev      *modfetch.RevInfo
	Packages []string
}

// QueryPackages is like QueryPattern, but requires that the pattern match at
// least one package and omits the non-package result (if any).
func QueryPackages(ctx context.Context, pattern, query string, current func(string) string, allowed AllowedFunc) ([]QueryResult, error) {
	pkgMods, modOnly, err := QueryPattern(ctx, pattern, query, current, allowed)

	if len(pkgMods) == 0 && err == nil {
		return nil, &PackageNotInModuleError{
			Mod:         modOnly.Mod,
			Replacement: Replacement(modOnly.Mod),
			Query:       query,
			Pattern:     pattern,
		}
	}

	return pkgMods, err
}

// QueryPattern looks up the module(s) containing at least one package matching
// the given pattern at the given version. The results are sorted by module path
// length in descending order. If any proxy provides a non-empty set of candidate
// modules, no further proxies are tried.
//
// For wildcard patterns, QueryPattern looks in modules with package paths up to
// the first "..." in the pattern. For the pattern "example.com/a/b.../c",
// QueryPattern would consider prefixes of "example.com/a".
//
// If any matching package is in the main module, QueryPattern considers only
// the main module and only the version "latest", without checking for other
// possible modules.
//
// QueryPattern always returns at least one QueryResult (which may be only
// modOnly) or a non-nil error.
func QueryPattern(ctx context.Context, pattern, query string, current func(string) string, allowed AllowedFunc) (pkgMods []QueryResult, modOnly *QueryResult, err error) {
	ctx, span := trace.StartSpan(ctx, "modload.QueryPattern "+pattern+" "+query)
	defer span.Done()

	base := pattern

	firstError := func(m *search.Match) error {
		if len(m.Errs) == 0 {
			return nil
		}
		return m.Errs[0]
	}

	var match func(mod module.Version, root string, isLocal bool) *search.Match
	matchPattern := search.MatchPattern(pattern)

	if i := strings.Index(pattern, "..."); i >= 0 {
		base = pathpkg.Dir(pattern[:i+3])
		if base == "." {
			return nil, nil, &WildcardInFirstElementError{Pattern: pattern, Query: query}
		}
		match = func(mod module.Version, root string, isLocal bool) *search.Match {
			m := search.NewMatch(pattern)
			matchPackages(ctx, m, imports.AnyTags(), omitStd, []module.Version{mod})
			return m
		}
	} else {
		match = func(mod module.Version, root string, isLocal bool) *search.Match {
			m := search.NewMatch(pattern)
			prefix := mod.Path
			if mod == Target {
				prefix = targetPrefix
			}
			if _, ok, err := dirInModule(pattern, prefix, root, isLocal); err != nil {
				m.AddError(err)
			} else if ok {
				m.Pkgs = []string{pattern}
			}
			return m
		}
	}

	var queryMatchesMainModule bool
	if HasModRoot() {
		m := match(Target, modRoot, true)
		if len(m.Pkgs) > 0 {
			if query != "upgrade" && query != "patch" {
				return nil, nil, &QueryMatchesPackagesInMainModuleError{
					Pattern:  pattern,
					Query:    query,
					Packages: m.Pkgs,
				}
			}
			if err := allowed(ctx, Target); err != nil {
				return nil, nil, fmt.Errorf("internal error: package %s is in the main module (%s), but version is not allowed: %w", pattern, Target.Path, err)
			}
			return []QueryResult{{
				Mod:      Target,
				Rev:      &modfetch.RevInfo{Version: Target.Version},
				Packages: m.Pkgs,
			}}, nil, nil
		}
		if err := firstError(m); err != nil {
			return nil, nil, err
		}

		if matchPattern(Target.Path) {
			queryMatchesMainModule = true
		}

		if (query == "upgrade" || query == "patch") && queryMatchesMainModule {
			if err := allowed(ctx, Target); err == nil {
				modOnly = &QueryResult{
					Mod: Target,
					Rev: &modfetch.RevInfo{Version: Target.Version},
				}
			}
		}
	}

	var (
		results          []QueryResult
		candidateModules = modulePrefixesExcludingTarget(base)
	)
	if len(candidateModules) == 0 {
		if modOnly != nil {
			return nil, modOnly, nil
		} else if queryMatchesMainModule {
			return nil, nil, &QueryMatchesMainModuleError{
				Pattern: pattern,
				Query:   query,
			}
		} else {
			return nil, nil, &PackageNotInModuleError{
				Mod:     Target,
				Query:   query,
				Pattern: pattern,
			}
		}
	}

	err = modfetch.TryProxies(func(proxy string) error {
		queryModule := func(ctx context.Context, path string) (r QueryResult, err error) {
			ctx, span := trace.StartSpan(ctx, "modload.QueryPattern.queryModule ["+proxy+"] "+path)
			defer span.Done()

			pathCurrent := current(path)
			r.Mod.Path = path
			r.Rev, err = queryProxy(ctx, proxy, path, query, pathCurrent, allowed)
			if err != nil {
				return r, err
			}
			r.Mod.Version = r.Rev.Version
			needSum := true
			root, isLocal, err := fetch(ctx, r.Mod, needSum)
			if err != nil {
				return r, err
			}
			m := match(r.Mod, root, isLocal)
			r.Packages = m.Pkgs
			if len(r.Packages) == 0 && !matchPattern(path) {
				if err := firstError(m); err != nil {
					return r, err
				}
				return r, &PackageNotInModuleError{
					Mod:         r.Mod,
					Replacement: Replacement(r.Mod),
					Query:       query,
					Pattern:     pattern,
				}
			}
			return r, nil
		}

		allResults, err := queryPrefixModules(ctx, candidateModules, queryModule)
		results = allResults[:0]
		for _, r := range allResults {
			if len(r.Packages) == 0 {
				modOnly = &r
			} else {
				results = append(results, r)
			}
		}
		return err
	})

	if queryMatchesMainModule && len(results) == 0 && modOnly == nil && errors.Is(err, fs.ErrNotExist) {
		return nil, nil, &QueryMatchesMainModuleError{
			Pattern: pattern,
			Query:   query,
		}
	}
	return results[:len(results):len(results)], modOnly, err
}

// modulePrefixesExcludingTarget returns all prefixes of path that may plausibly
// exist as a module, excluding targetPrefix but otherwise including path
// itself, sorted by descending length.
func modulePrefixesExcludingTarget(path string) []string {
	prefixes := make([]string, 0, strings.Count(path, "/")+1)

	for {
		if path != targetPrefix {
			if _, _, ok := module.SplitPathVersion(path); ok {
				prefixes = append(prefixes, path)
			}
		}

		j := strings.LastIndexByte(path, '/')
		if j < 0 {
			break
		}
		path = path[:j]
	}

	return prefixes
}

func queryPrefixModules(ctx context.Context, candidateModules []string, queryModule func(ctx context.Context, path string) (QueryResult, error)) (found []QueryResult, err error) {
	ctx, span := trace.StartSpan(ctx, "modload.queryPrefixModules")
	defer span.Done()

	// If the path we're attempting is not in the module cache and we don't have a
	// fetch result cached either, we'll end up making a (potentially slow)
	// request to the proxy or (often even slower) the origin server.
	// To minimize latency, execute all of those requests in parallel.
	type result struct {
		QueryResult
		err error
	}
	results := make([]result, len(candidateModules))
	var wg sync.WaitGroup
	wg.Add(len(candidateModules))
	for i, p := range candidateModules {
		ctx := trace.StartGoroutine(ctx)
		go func(p string, r *result) {
			r.QueryResult, r.err = queryModule(ctx, p)
			wg.Done()
		}(p, &results[i])
	}
	wg.Wait()

	// Classify the results. In case of failure, identify the error that the user
	// is most likely to find helpful: the most useful class of error at the
	// longest matching path.
	var (
		noPackage   *PackageNotInModuleError
		noVersion   *NoMatchingVersionError
		noPatchBase *NoPatchBaseError
		notExistErr error
	)
	for _, r := range results {
		switch rErr := r.err.(type) {
		case nil:
			found = append(found, r.QueryResult)
		case *PackageNotInModuleError:
			// Given the option, prefer to attribute “package not in module”
			// to modules other than the main one.
			if noPackage == nil || noPackage.Mod == Target {
				noPackage = rErr
			}
		case *NoMatchingVersionError:
			if noVersion == nil {
				noVersion = rErr
			}
		case *NoPatchBaseError:
			if noPatchBase == nil {
				noPatchBase = rErr
			}
		default:
			if errors.Is(rErr, fs.ErrNotExist) {
				if notExistErr == nil {
					notExistErr = rErr
				}
			} else if err == nil {
				if len(found) > 0 || noPackage != nil {
					// golang.org/issue/34094: If we have already found a module that
					// could potentially contain the target package, ignore unclassified
					// errors for modules with shorter paths.

					// golang.org/issue/34383 is a special case of this: if we have
					// already found example.com/foo/v2@v2.0.0 with a matching go.mod
					// file, ignore the error from example.com/foo@v2.0.0.
				} else {
					err = r.err
				}
			}
		}
	}

	// TODO(#26232): If len(found) == 0 and some of the errors are 4xx HTTP
	// codes, have the auth package recheck the failed paths.
	// If we obtain new credentials for any of them, re-run the above loop.

	if len(found) == 0 && err == nil {
		switch {
		case noPackage != nil:
			err = noPackage
		case noVersion != nil:
			err = noVersion
		case noPatchBase != nil:
			err = noPatchBase
		case notExistErr != nil:
			err = notExistErr
		default:
			panic("queryPrefixModules: no modules found, but no error detected")
		}
	}

	return found, err
}

// A NoMatchingVersionError indicates that Query found a module at the requested
// path, but not at any versions satisfying the query string and allow-function.
//
// NOTE: NoMatchingVersionError MUST NOT implement Is(fs.ErrNotExist).
//
// If the module came from a proxy, that proxy had to return a successful status
// code for the versions it knows about, and thus did not have the opportunity
// to return a non-400 status code to suppress fallback.
type NoMatchingVersionError struct {
	query, current string
}

func (e *NoMatchingVersionError) Error() string {
	currentSuffix := ""
	if (e.query == "upgrade" || e.query == "patch") && e.current != "" && e.current != "none" {
		currentSuffix = fmt.Sprintf(" (current version is %s)", e.current)
	}
	return fmt.Sprintf("no matching versions for query %q", e.query) + currentSuffix
}

// A NoPatchBaseError indicates that Query was called with the query "patch"
// but with a current version of "" or "none".
type NoPatchBaseError struct {
	path string
}

func (e *NoPatchBaseError) Error() string {
	return fmt.Sprintf(`can't query version "patch" of module %s: no existing version is required`, e.path)
}

// A WildcardInFirstElementError indicates that a pattern passed to QueryPattern
// had a wildcard in its first path element, and therefore had no pattern-prefix
// modules to search in.
type WildcardInFirstElementError struct {
	Pattern string
	Query   string
}

func (e *WildcardInFirstElementError) Error() string {
	return fmt.Sprintf("no modules to query for %s@%s because first path element contains a wildcard", e.Pattern, e.Query)
}

// A PackageNotInModuleError indicates that QueryPattern found a candidate
// module at the requested version, but that module did not contain any packages
// matching the requested pattern.
//
// NOTE: PackageNotInModuleError MUST NOT implement Is(fs.ErrNotExist).
//
// If the module came from a proxy, that proxy had to return a successful status
// code for the versions it knows about, and thus did not have the opportunity
// to return a non-400 status code to suppress fallback.
type PackageNotInModuleError struct {
	Mod         module.Version
	Replacement module.Version
	Query       string
	Pattern     string
}

func (e *PackageNotInModuleError) Error() string {
	if e.Mod == Target {
		if strings.Contains(e.Pattern, "...") {
			return fmt.Sprintf("main module (%s) does not contain packages matching %s", Target.Path, e.Pattern)
		}
		return fmt.Sprintf("main module (%s) does not contain package %s", Target.Path, e.Pattern)
	}

	found := ""
	if r := e.Replacement; r.Path != "" {
		replacement := r.Path
		if r.Version != "" {
			replacement = fmt.Sprintf("%s@%s", r.Path, r.Version)
		}
		if e.Query == e.Mod.Version {
			found = fmt.Sprintf(" (replaced by %s)", replacement)
		} else {
			found = fmt.Sprintf(" (%s, replaced by %s)", e.Mod.Version, replacement)
		}
	} else if e.Query != e.Mod.Version {
		found = fmt.Sprintf(" (%s)", e.Mod.Version)
	}

	if strings.Contains(e.Pattern, "...") {
		return fmt.Sprintf("module %s@%s found%s, but does not contain packages matching %s", e.Mod.Path, e.Query, found, e.Pattern)
	}
	return fmt.Sprintf("module %s@%s found%s, but does not contain package %s", e.Mod.Path, e.Query, found, e.Pattern)
}

func (e *PackageNotInModuleError) ImportPath() string {
	if !strings.Contains(e.Pattern, "...") {
		return e.Pattern
	}
	return ""
}

// ModuleHasRootPackage returns whether module m contains a package m.Path.
func ModuleHasRootPackage(ctx context.Context, m module.Version) (bool, error) {
	needSum := false
	root, isLocal, err := fetch(ctx, m, needSum)
	if err != nil {
		return false, err
	}
	_, ok, err := dirInModule(m.Path, m.Path, root, isLocal)
	return ok, err
}

func versionHasGoMod(ctx context.Context, m module.Version) (bool, error) {
	needSum := false
	root, _, err := fetch(ctx, m, needSum)
	if err != nil {
		return false, err
	}
	fi, err := os.Stat(filepath.Join(root, "go.mod"))
	return err == nil && !fi.IsDir(), nil
}

// A versionRepo is a subset of modfetch.Repo that can report information about
// available versions, but cannot fetch specific source files.
type versionRepo interface {
	ModulePath() string
	Versions(prefix string) ([]string, error)
	Stat(rev string) (*modfetch.RevInfo, error)
	Latest() (*modfetch.RevInfo, error)
}

var _ versionRepo = modfetch.Repo(nil)

func lookupRepo(proxy, path string) (repo versionRepo, err error) {
	err = module.CheckPath(path)
	if err == nil {
		repo = modfetch.Lookup(proxy, path)
	} else {
		repo = emptyRepo{path: path, err: err}
	}

	if index == nil {
		return repo, err
	}
	if _, ok := index.highestReplaced[path]; !ok {
		return repo, err
	}

	return &replacementRepo{repo: repo}, nil
}

// An emptyRepo is a versionRepo that contains no versions.
type emptyRepo struct {
	path string
	err  error
}

var _ versionRepo = emptyRepo{}

func (er emptyRepo) ModulePath() string                         { return er.path }
func (er emptyRepo) Versions(prefix string) ([]string, error)   { return nil, nil }
func (er emptyRepo) Stat(rev string) (*modfetch.RevInfo, error) { return nil, er.err }
func (er emptyRepo) Latest() (*modfetch.RevInfo, error)         { return nil, er.err }

// A replacementRepo augments a versionRepo to include the replacement versions
// (if any) found in the main module's go.mod file.
//
// A replacementRepo suppresses "not found" errors for otherwise-nonexistent
// modules, so a replacementRepo should only be constructed for a module that
// actually has one or more valid replacements.
type replacementRepo struct {
	repo versionRepo
}

var _ versionRepo = (*replacementRepo)(nil)

func (rr *replacementRepo) ModulePath() string { return rr.repo.ModulePath() }

// Versions returns the versions from rr.repo augmented with any matching
// replacement versions.
func (rr *replacementRepo) Versions(prefix string) ([]string, error) {
	repoVersions, err := rr.repo.Versions(prefix)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	versions := repoVersions
	if index != nil && len(index.replace) > 0 {
		path := rr.ModulePath()
		for m, _ := range index.replace {
			if m.Path == path && strings.HasPrefix(m.Version, prefix) && m.Version != "" && !modfetch.IsPseudoVersion(m.Version) {
				versions = append(versions, m.Version)
			}
		}
	}

	if len(versions) == len(repoVersions) { // No replacement versions added.
		return versions, nil
	}

	sort.Slice(versions, func(i, j int) bool {
		return semver.Compare(versions[i], versions[j]) < 0
	})
	str.Uniq(&versions)
	return versions, nil
}

func (rr *replacementRepo) Stat(rev string) (*modfetch.RevInfo, error) {
	info, err := rr.repo.Stat(rev)
	if err == nil || index == nil || len(index.replace) == 0 {
		return info, err
	}

	v := module.CanonicalVersion(rev)
	if v != rev {
		// The replacements in the go.mod file list only canonical semantic versions,
		// so a non-canonical version can't possibly have a replacement.
		return info, err
	}

	path := rr.ModulePath()
	_, pathMajor, ok := module.SplitPathVersion(path)
	if ok && pathMajor == "" {
		if err := module.CheckPathMajor(v, pathMajor); err != nil && semver.Build(v) == "" {
			v += "+incompatible"
		}
	}

	if r := Replacement(module.Version{Path: path, Version: v}); r.Path == "" {
		return info, err
	}
	return rr.replacementStat(v)
}

func (rr *replacementRepo) Latest() (*modfetch.RevInfo, error) {
	info, err := rr.repo.Latest()

	if index != nil {
		path := rr.ModulePath()
		if v, ok := index.highestReplaced[path]; ok {
			if v == "" {
				// The only replacement is a wildcard that doesn't specify a version, so
				// synthesize a pseudo-version with an appropriate major version and a
				// timestamp below any real timestamp. That way, if the main module is
				// used from within some other module, the user will be able to upgrade
				// the requirement to any real version they choose.
				if _, pathMajor, ok := module.SplitPathVersion(path); ok && len(pathMajor) > 0 {
					v = modfetch.PseudoVersion(pathMajor[1:], "", time.Time{}, "000000000000")
				} else {
					v = modfetch.PseudoVersion("v0", "", time.Time{}, "000000000000")
				}
			}

			if err != nil || semver.Compare(v, info.Version) > 0 {
				return rr.replacementStat(v)
			}
		}
	}

	return info, err
}

func (rr *replacementRepo) replacementStat(v string) (*modfetch.RevInfo, error) {
	rev := &modfetch.RevInfo{Version: v}
	if modfetch.IsPseudoVersion(v) {
		rev.Time, _ = modfetch.PseudoVersionTime(v)
		rev.Short, _ = modfetch.PseudoVersionRev(v)
	}
	return rev, nil
}

// A QueryMatchesMainModuleError indicates that a query requests
// a version of the main module that cannot be satisfied.
// (The main module's version cannot be changed.)
type QueryMatchesMainModuleError struct {
	Pattern string
	Query   string
}

func (e *QueryMatchesMainModuleError) Error() string {
	if e.Pattern == Target.Path {
		return fmt.Sprintf("can't request version %q of the main module (%s)", e.Query, e.Pattern)
	}

	return fmt.Sprintf("can't request version %q of pattern %q that includes the main module (%s)", e.Query, e.Pattern, Target.Path)
}

// A QueryMatchesPackagesInMainModuleError indicates that a query cannot be
// satisfied because it matches one or more packages found in the main module.
type QueryMatchesPackagesInMainModuleError struct {
	Pattern  string
	Query    string
	Packages []string
}

func (e *QueryMatchesPackagesInMainModuleError) Error() string {
	if len(e.Packages) > 1 {
		return fmt.Sprintf("pattern %s matches %d packages in the main module, so can't request version %s", e.Pattern, len(e.Packages), e.Query)
	}

	if search.IsMetaPackage(e.Pattern) || strings.Contains(e.Pattern, "...") {
		return fmt.Sprintf("pattern %s matches package %s in the main module, so can't request version %s", e.Pattern, e.Packages[0], e.Query)
	}

	return fmt.Sprintf("package %s is in the main module, so can't request version %s", e.Packages[0], e.Query)
}
