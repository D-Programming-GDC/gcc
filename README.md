## The GDC D Compiler [![Build Status](https://semaphoreci.com/api/v1/jpf91/gcc-2/branches/trunk/badge.svg)](https://semaphoreci.com/jpf91/gcc-2) [![Build status](https://badge.buildkite.com/58fd9d7cf59f6c774888051edb0e037fad6d97bcf04e53ac4f.svg?branch=trunk)](https://buildkite.com/d-programming-gdc/gcc)

GDC is the GCC-based [D language][dlang] compiler, integrating the open source [DMDFE D][dmd] front end
with [GCC][gcc] as the backend. The GNU D Compiler (GDC) project was originally started by David Friedman
in 2004 until early 2007 when he disappeared from the D scene, and was no longer able to maintain GDC.
Following a revival attempt in 2008, GDC is now under the lead of Iain Buclaw who has been steering the
project since 2009 with the assistance of its contributors, without them the project would not have been
nearly as successful as it has been.

Documentation on GDC is available from [the wiki][wiki]. Any bugs or issues found with using GDC should
be reported at [the GCC bugzilla site][bugs] with the bug component set to `d`. For help with GDC, the
[D.gnu][maillist] mailing list is the place to go with questions or problems. There's also a GDC IRC
channel at #d.gdc on FreeNode. Any questions which are related to the D language, but not directly to
the GDC compiler, can be asked in the [D forums][dforum]. You can find more information about D, including
example code, API documentation, tutorials and these forums at the [main D website][dlang].

### Building GDC

Stable GDC releases for production usage should be obtained by downloading stable GCC sources
from the [GCC downloads][gcc-download] site.
For the latest experimental development version, simply download a [GCC snapshot][gcc-snapshot] or
checkout the GCC SVN or git mirror repository. Most GDC development directly targets the GCC SVN repository,
so the latest GDC version is always available in the GCC SVN.
Do not use the `trunk` branch in this repository, as it is rebased regularly and contains exclusively
CI related changes.

During certain development phases (e.g. when GCC is in a feature freeze) larger GDC changes may be staged
to the `gdc-next` branch. This branch is rebased irregularly, do not rely on the commit ids to be
stable.

If you need to clone this repo for some reason, you may want to do a shallow clone using the
`--depth 1 --no-single-branch` git options, as this repository is large. To compile GDC, add `--enable-languages=d` to the GCC configure flags and [start building][gdc-build]. 

### Using GDC

Usage information can be found at ...

### Contributing to GDC

Starting with GCC 9.0.0, GDC has been merged into upstream GCC and all GDC development now follows the usual
GCC development process. Changes to GDC and related code can therefore be submitted
to the [gcc-patches mailing list][patches-ml] for review.

It is possible to directly post patches to the [mailing list][patches-ml] and not to use this repository at all.
We however recommend using this repository to make use of the CI checks and the github review workflow.

#### Submitting Changes

To submit changes to GDC, simply fork this repository, create a new feature branch based on the `trunk` branch
and open a pull request for that branch. We recommend using full clones for development, allthough using shallow
clones should also be possible. In code:

```bash
# Initial one time setup:
# For repository on github, then clone your fork
git clone git@github.com:[you]/gcc.git
cd gcc
# Add the gdc repository as a remote
git remote add gdc git@github.com:D-Programming-GDC/gcc.git

# Do this for every patch:
# Fetch latest upstream changes
git remote update
# Base a new branch on gdc/trunk
git checkout gdc/trunk
git checkout -b pr12345
# Make changes, commit
git commit [...]
git push origin pr12345:pr12345
# Open a pull request on github
```
Opening a pull request will automatically trigger our CI and test your changes on various machines.

#### Changelogs
The GCC project requires keeping changes in the `Changelog` files. GCC ships a script which can generate
Changelog templates for us if we feed it a diff:
```bash
git diff gdc/trunk | ./contrib/mklog
```
*Note:* The above command generates the diff between `gdc/trunk` and your local branch. If `gdc/trunk` was
updated and you did a `git remote update`, `gdc/trunk` may have changes which are not yet in your branch.
In that case, rebase onto `gdc/trunk` first.

The command outputs something like this:
```
ChangeLog:

2019-02-03  Johannes Pfau  <johannespfau@example.com>

	* test.d: New file.

gcc/d/ChangeLog:

2019-02-03  Johannes Pfau  <johannespfau@example.com>

	* dfile.txt: New file.

libphobos/ChangeLog:

2019-02-03  Johannes Pfau  <johannespfau@example.com>

	* phobosfile.txt: New file.

```

The `ChangeLog:`, `libphobos/ChangeLog:` part gives the file into which the following changes need to be added.
Complete the changelog text and use the existing entries in the files for reference or see
the [GCC][changelog-doc] and [GNU][changelog-doc2] documentation. Also make sure to adhere to the line length limit of 80 characters. Then make the changelog somehow available for review:
Either commit the files, or preferable, just copy and paste the edited text output of `mklog` into your
pull request description.


### Getting Changes Into GCC SVN

After changes have been reviewed on github, they have to be pushed into the GCC SVN. Pull requests will
not get merged into this repository. The following steps can be handled by GDC maintainers, although it is
possible to perform these by yourself as well.

##### Sumbitting to the gcc-patches Mailing List

Once the review and CI have passed on the github pull request page, the changes need to be submitted to the
`gcc-patches` mailing list. This can easily be done using [git send-email][git-send-email]:

1. You might want to squash the commits. Each commit will become one email/patch so it might make sense
   to combine commits here.
2. The changelog should preferrably be pasted into the email text, so do not include
   commits modifying the changelog files.
3. If you had to regenerate any autogenerated files (e.g. configure from configure.ac)
   you may keep these changes out of the patch for simplified review. The generated files
   should still be present in the changelog.

You'll have to configure `git send-email` once after you checked out the repository:
```bash
git config sendemail.to gcc-patches@gcc.gnu.org
```
If you never used `git send-email` before, you'll also have to setup the SMTP settings once.
See [here][git-send-email] for details.

Now to send the patches:
```bash
# Check which commits will be sent:
git log gdc/trunk..
# Check the complete diff which will be sent:
git diff gdc/trunk..
# Dry run to verify everything again
git send-email gdc/trunk --annotate --dry-run
# Send the patches
git send-email gdc/trunk --annotate
```

If you send multiple patches and want to write an introduction email, use the `--compose` argument for
`git send-email`. You can also generate patch files like this:
```bash
git format-patch gdc/trunk..
# Edit the *.patch files, add messages etc.
# Now send the patches
git send-email *.patch --dry-run
git send-email *.patch
```

##### Pushing Changes to SVN

This section is only relevant for GDC maintainers with GCC SVN write access. There are certain rules when
pushing to SVN, usually you're only allowed to push **after** the patches have been reviewed on the mailing list.
Refer to the [GCC documentation][gcc-SVN] for details.

```
# We need the full repository for SVN integration
git remote add gcc git://gcc.gnu.org/git/gcc.git
git config --add remote.gcc.fetch 'refs/remotes/*:refs/remotes/SVN/*'
git remote update
git SVN init -s --prefix=SVN/ SVN+ssh://username@gcc.gnu.org/SVN/gcc
# Update trunk branch to latest SVN commit
git checkout -b trunk SVN/trunk
git fetch
git SVN rebase

git checkout myfix
# Rebase myfix branch to get rid of CI commits
git rebase gdc/trunk --onto trunk
# And merge
git checkout trunk
git merge --ff-only myfix
# See commits we're going to commit
git log -p @{u}..

# And finally commit
git SVN dcommit
```

### Repository Information

This repository is a fork of the [GCC git mirror][gcc-git]. As the GCC main version control system is
currently still using SVN, all GIT repositories are `git-SVN` bridges. This needs some special attention when
performing some git operations.

#### Directory Structure

All code branches contain the complete GCC tree. D sources are in `gcc/d` for the compiler
and in `libphobos` for the runtime library. Changes to files in `gcc/d/dmd` or `libphobos`
should be submitted to the [upstream dlang repositories][dlang-github] first if possible.
Refer to [gcc/d/README.gcc][gcc-d-readme] for more details.

#### Branches

Branches in this repository are organized in the following way:

* CI branches: The `trunk` branch and release branches `gcc-*-branch` are based on the same
  branches in the upstream GCC git repository. The only changes compared to the upstream branches
  are CI-related setup commits. CI branches are updated automatically to be kept in sync with
  upstream and are rebased onto the upstream changes. These branches are effectively readonly:
  We never merge into the branches in this repository. The CI related changes make it possible
  to run CI based tests for any PR based on these branches, which is their sole purpose.
* The `gdc-next` branch: If GCC is in a late [development stage][gcc-stage] this branch can accumulate
  changes for the GCC release after the next one. It is essentially used to allow periodic merges from
  [upstream DMD][dlang-github] when GCC development is frozen. Changes in the GCC `trunk` branch
  are manually merged into this branch. When GCC enters stage 1 development again, this branch will be
  rebased and pushed to upstream `trunk`. After that, the branch in this repository will be **rebased**
  to trunk.
* Backport branches: The `gcc-*-bp` branches contain D frontend and library feature updates for released GCC versions.
  Regression fixes should target the main `gcc-*-branch` branches instead, according to GCC rules.



[home]: https://gdcproject.org
[dlang]: https://dlang.org
[gcc]: https://gcc.gnu.org
[dforum]: https://forum.dlang.org
[dmd]: https://github.com/dlang/dmd
[wiki]: https://wiki.dlang.org/GDC
[bugs]: https://gcc.gnu.org/bugzilla
[maillist]: https://forum.dlang.org/group/D.gnu
[email]: mailto:ibuclaw@gdcproject.org
[gcc-devel]: https://gcc.gnu.org/git/?p=gcc.git;a=shortlog
[patches-ml]: https://gcc.gnu.org/lists.html
[gcc-github]: https://github.com/gcc-mirror/gcc
[gcc-git]: https://gcc.gnu.org/wiki/GitMirror
[gcc-stage]: https://www.gnu.org/software/gcc/develop.html
[dlang-github]: https://github.com/dlang
[gdc-build]: https://wiki.dlang.org/GDC/Installation/Generic
[changelog-doc]: https://www.gnu.org/software/gcc/codingconventions.html#ChangeLogs
[changelog-doc2]: https://www.gnu.org/prep/standards/standards.html#Change-Logs
[git-send-email]: https://www.freedesktop.org/wiki/Software/PulseAudio/HowToUseGitSendEmail/
[gcc-download]: https://www.gnu.org/software/gcc/releases.html
[gcc-SVN]: https://gcc.gnu.org/SVNwrite.html
[gcc-d-readme]: https://github.com/jpf91/gcc/blob/trunk/gcc/d/README.gcc
[gcc-snapshot]: https://www.gnu.org/software/gcc/snapshots.html
