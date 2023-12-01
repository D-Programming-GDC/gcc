#!/bin/bash
# This script is intended to be ran on platform on GitHub Action
# Other CI platforms in this script are legacy and only kept around to keep
# the configuration parts of it modularish.
#
# Following environmental variables are assume to be exported on GitHub Actions.
#
# - RUNNER_TOOL_CACHE
# - RUNNER_OS
# - GCC_CI_TARGET
# - GCC_CI_BOOTSTRAP
#
# See https://docs.github.com/en/actions/learn-github-actions/variables#default-environment-variables
#
## Top-level build system configration.
gcc_prereqs="gmp-6.1.0.tar.bz2 mpfr-3.1.6.tar.bz2 mpc-1.0.3.tar.gz isl-0.18.tar.bz2"
host_package="9"

export CC="gcc-${host_package}"
export CXX="g++-${host_package}"
export GDC="gdc-${host_package}"
export MAKE="make"

environment() {
    ## Determine what flags to use for configure, build and testing the compiler.
    ## Commonize CI environment variables.
    #
    # project_dir:              directory of checked out sources.
    # cache_dir:                tarballs of downloaded dependencies cached
    #                           between builds.
    # log_dir:                  where to save testsuite logs to upload them
    # build_host:               host triplet that build is ran from.
    # build_host_canonical:     canonical version of host triplet.
    # build_target:             target triplet of the compiler to build.
    # build_target_canonical:   canonical version of target triplet.
    # make_flags:               flags to pass to make.
    # build_bootstrap:          whether to enable bootstrap build.
    #
    if [ "${SEMAPHORE}" = "true" ]; then
        if [ -z "${SEMAPHORE_CACHE_DIR}" ]; then
            export SEMAPHORE_CACHE_DIR="$PWD/gcc-deps"
        fi;
        if [ -z "${SEMAPHORE_PROJECT_DIR}" ]; then
            export SEMAPHORE_PROJECT_DIR="$PWD"
        fi;
        project_dir=${SEMAPHORE_PROJECT_DIR}
        cache_dir=${SEMAPHORE_CACHE_DIR}
        if [ "${SEMAPHORE_AGENT_MACHINE_OS_IMAGE}" != "" ]; then
            cache restore $SEMAPHORE_PROJECT_NAME-$SEMAPHORE_AGENT_MACHINE_OS_IMAGE-deps
        else
            cache restore $SEMAPHORE_PROJECT_NAME-deps
        fi
        log_dir=${PWD}/logs
        mkdir -p ${log_dir}
        build_host=$($CC -dumpmachine)
        build_host_canonical=$(${project_dir}/config.sub ${build_host})
        build_target=${build_host}
        build_target_canonical=${build_host_canonical}
        if [ "${SEMAPHORE_AGENT_MACHINE_OS_IMAGE}" = "macos-xcode11" ]; then
            make_flags="-j$(sysctl -n hw.logicalcpu)"
        else
            make_flags="-j$(nproc)"
        fi
        build_bootstrap="disable"
    elif [ "${BUILDKITE}" = "true" ]; then
        project_dir=${PWD}
        cache_dir=${BUILDKITE_CACHE_DIR}
        log_dir=${PWD}/logs
        mkdir -p ${log_dir}
        if [ "${BUILDKITE_OS}" = "netbsd" ]; then
            export CC="gcc"
            export CXX="g++"
            export GDC="gdc"
            export MAKE="gmake"
            make_flags="-j$(sysctl -n hw.ncpu)"
        elif [ "${BUILDKITE_OS}" = "openbsd" ]; then
            export CC="egcc"
            export CXX="eg++"
            export GDC="egdc"
            export MAKE="gmake"
            make_flags="-j$(sysctl -n hw.ncpu)"
        elif [ "${BUILDKITE_OS}" = "alpine" ]; then
            export CC="gcc"
            export CXX="g++"
            export GDC="gdc"
            make_flags="-j$(nproc)"
        else
            make_flags="-j$(nproc)"
        fi
        build_host=$($CC -dumpmachine)
        build_host_canonical=$(${project_dir}/config.sub ${build_host})
        build_target=${BUILDKITE_TARGET}
        build_target_canonical=$(${project_dir}/config.sub ${build_target})
        make_flags="${make_flags} -sw LIBTOOLFLAGS=--silent"
        build_bootstrap=${BUILDKITE_BOOTSTRAP}
    elif [ "${CIRRUS_CI}" = "true" ]; then
        project_dir=${PWD}
        cache_dir="${PWD}/gcc-deps"
        log_dir=${PWD}/logs
        mkdir -p ${log_dir}
        if [ "${CIRRUS_OS}" = "freebsd" ]; then
            export CC="gcc${host_package}"
            export CXX="g++${host_package}"
            export GDC="gdc${host_package}"
            export MAKE="gmake"
            make_flags="-j$(sysctl -n hw.ncpu)"
        elif [ "${CIRRUS_OS}" = "darwin" ]; then
            make_flags="-j$(sysctl -n hw.logicalcpu)"
        else
            make_flags="-j$(nproc)"
        fi
        build_host=$($CC -dumpmachine)
        build_host_canonical=$(${project_dir}/config.sub ${build_host})
        build_target=${build_host}
        build_target_canonical=${build_host_canonical}
        build_bootstrap="disable"
    elif [ "${AZURE}" = "true" ]; then
        project_dir=${PWD}
        cache_dir="${PWD}/gcc-deps"
        build_host=$($CC -dumpmachine)
        build_host_canonical=$(${project_dir}/config.sub ${build_host})
        build_target=${build_host}
        build_target_canonical=${build_host_canonical}
        make_flags="-j$(nproc)"
        build_bootstrap="disable"
    elif [ "${CI}" = "true" ]; then
        gcc_prereqs=""
        project_dir=${PWD}
        cache_dir=${RUNNER_TOOL_CACHE}
        log_dir=${PWD}/logs
        mkdir -p ${log_dir}
        make_flags="-j$(nproc)"
        build_host=$($CC -dumpmachine)
        build_host_canonical=$(${project_dir}/config.sub ${build_host})
        build_target=${GCC_CI_TARGET}
        build_target_canonical=$(${project_dir}/config.sub ${build_target})
        build_bootstrap=${GCC_CI_BOOTSTRAP}
    else
        echo "Unhandled CI environment"
        exit 1
    fi

    ## Options determined by target, what steps to skip, or extra flags to add.
    ## Also, should the testsuite be ran under a simulator?
    #
    # build_supports_phobos:    whether to build phobos and run unittests.
    # build_target_phobos:      where to run the phobos testsuite from.
    # build_enable_languages:   which languages to build, this affects whether C++
    #                           or LTO tests are ran in the testsuite.
    # build_prebuild_script:    script to run after sources have been extracted.
    # build_configure_flags:    extra configure flags for the target.
    # build_test_flags:         options to pass to RUNTESTFLAGS.
    #
    build_supports_phobos='yes'
    build_target_phobos=''
    build_enable_languages='c++,d,lto'
    build_prebuild_script=''
    build_configure_flags=''
    build_test_flags=''

    # Check whether this is a cross or multiarch compiler.
    if [ "${build_host_canonical}" != "${build_target_canonical}" ]; then
        multilib_targets=( $(${CC} -print-multi-lib | cut -f2 -d\;) )
        is_cross_compiler=1

        for multilib in ${multilib_targets[@]}; do
            build_multiarch=$(${CC} -print-multiarch ${multilib/@/-})
            build_multiarch_canonical=$(${project_dir}/config.sub ${build_multiarch})

            # This is a multiarch compiler, update target to the host compiler.
            if [ "${build_multiarch_canonical}" = "${build_target_canonical}" ]; then
                build_target=$build_host
                build_target_canonical=$build_host_canonical
                build_target_phobos="${build_target}/$(${CC} ${multilib/@/-} -print-multi-directory)/libphobos"
                build_test_flags="--target_board=unix{${multilib/@/-}}"
                build_configure_flags='--enable-multilib --enable-multiarch'
                is_cross_compiler=0
                break
            fi
        done

        # Building a cross compiler, need to explicitly say where to find native headers.
        if [ ${is_cross_compiler} -eq 1 ]; then
            build_configure_flags="--with-native-system-header-dir=/usr/${build_target}/include"

            # Note: setting target board to something other than "generic" only makes
            # sense if phobos is being built. Without phobos, all runnable tests will
            # all fail as being 'UNRESOLVED', and so are never ran anyway.
            case ${build_target_canonical} in
                arm*-*-*)
                    build_test_flags='--target_board=buildci-arm-sim'
                    ;;
                *)
                    build_test_flags='--target_board=buildci-generic-sim'
                    ;;
            esac
        fi
    fi

    if [ "${build_target_phobos}" = "" ]; then
        build_target_phobos="${build_target}/libphobos"
    fi

    # Unless requested, don't build with multilib.
    if [ `expr "${build_configure_flags}" : '.*enable-multilib'` -eq 0 ]; then
        build_configure_flags="--disable-multilib ${build_configure_flags}"
    fi

    # If bootstrapping, be sure to turn off slow tree checking.
    if [ "${build_bootstrap}" = "enable" ]; then
        build_configure_flags="${build_configure_flags} \
            --enable-bootstrap --enable-checking=release"
    else
        build_configure_flags="${build_configure_flags} \
            --disable-bootstrap --enable-checking"
    fi

    # Determine correct flags for configuring a compiler for target.
    case ${build_target_canonical} in
      arm-*-*eabihf)
            build_configure_flags="${build_configure_flags} \
                --with-arch=armv7-a --with-fpu=vfpv3-d16 --with-float=hard --with-mode=thumb"
            if [ `expr "${build_configure_flags}" : '.*enable-multilib'` -eq 1 ]; then
                build_prebuild_script="${cache_dir}/patches/arm-multilib.sh"
            fi
            ;;
      arm*-*-*eabi)
            build_configure_flags="${build_configure_flags} \
                --with-arch=armv5t --with-float=soft"
            ;;
      mips-*-*|mipsel-*-*)
            build_configure_flags="${build_configure_flags} \
                --with-arch=mips32r2"
            ;;
      mips64*-*-*)
            build_configure_flags="${build_configure_flags} \
                --with-arch-64=mips64r2 --with-abi=64"
            ;;
      powerpc64le-*-*)
            build_configure_flags="${build_configure_flags} \
                --with-cpu=power8 --with-long-double-128"
            ;;
      powerpc64-*-*)
            build_configure_flags="${build_configure_flags} \
                --with-cpu=power7"
            ;;
      x86_64-*-darwin19)
            build_configure_flags="${build_configure_flags} \
                --with-sysroot=/Library/Developer/CommandLineTools/SDKs/MacOSX10.15.sdk"
            ;;
      x86_64-*-openbsd*)
            build_configure_flags="${build_configure_flags} \
                --with-gmp=/usr/local --enable-threads=posix --enable-default-pie"
            build_prebuild_script="${cache_dir}/patches/openbsd-support.sh"
            ;;
      x86_64-*-*)
            ;;
      *)
            build_supports_phobos='no'
            build_enable_languages='c++,d --disable-lto'
            ;;
    esac

    if [ "${build_supports_phobos}" = "yes" ]; then
        build_configure_flags="--enable-libphobos ${build_configure_flags}"
    fi
}

installdeps() {
    ## Install build dependencies.
    # Would save 1 minute if these were preinstalled in some docker image.
    # But the network speed is nothing to complain about so far...
    if [ "${SEMAPHORE}" = "true" ]; then
        if [ "${SEMAPHORE_AGENT_MACHINE_OS_IMAGE}" = "ubuntu1804" ]; then
            sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
            sudo apt-get update -qq
            sudo apt-get install -qq gcc-${host_package} g++-${host_package} gdc-${host_package} \
                autogen autoconf automake bison dejagnu flex patch || exit 1
        elif [ "${SEMAPHORE_AGENT_MACHINE_OS_IMAGE}" = "macos-xcode11" ]; then
            brew update
            brew install gcc@${host_package} autogen deja-gnu || exit 1
        elif [ "${SEMAPHORE_PLATFORM}" = "bionic-kvm" ]; then
            sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
            sudo apt-get update -qq
            sudo apt-get install -qq gcc-${host_package} g++-${host_package} gdc-${host_package} \
                autogen autoconf automake bison dejagnu flex patch || exit 1
        else
            echo "Unhandled CI environment"
            exit 1
        fi
    elif [ "${CIRRUS_CI}" = "true" ]; then
        if [ "${CIRRUS_OS}" = "linux" ]; then
            apt-get update -qq
            apt-get install -qq software-properties-common
            add-apt-repository -y ppa:ubuntu-toolchain-r/test
            apt-get update -qq
            apt-get install -qq gcc-${host_package} g++-${host_package} gdc-${host_package} \
                autogen autoconf automake bison curl dejagnu flex make patch || exit 1
        elif [ "${CIRRUS_OS}" = "freebsd" ]; then
            pkg install -y gcc${host_package} \
                autogen autoconf automake autotools bison coreutils curl dejagnu flex gmake patch || exit 1
        elif [ "${CIRRUS_OS}" = "darwin" ]; then
            brew update-reset
            brew install gcc@${host_package} autogen deja-gnu xz || exit 1
        else
            echo "Unhandled CI environment"
            exit 1
        fi
    elif [ "${CI}" = "true" ]; then
        if [ "${RUNNER_OS}" = "Linux" ]; then
            case ${GCC_CI_TARGET} in
                arm*-*-*eabi)
                    install_packages="binutils-arm-linux-gnueabi libc6-dev-armel-cross"
                    ;;
                arm*-*-*eabihf)
                    install_packages="binutils-arm-linux-gnueabihf libc6-dev-armhf-cross"
                    ;;
                aarch64-*-*)
                    install_packages="binutils-aarch64-linux-gnu libc6-dev-arm64-cross"
                    ;;
                mips-*-*)
                    install_packages="binutils-mips-linux-gnu libc6-dev-mips-cross"
                    ;;
                mips64el-*-*)
                    install_packages="binutils-mips64el-linux-gnuabi64 libc6-dev-mips64el-cross"
                    ;;
                mipsel-*-*)
                    install_packages="binutils-mipsel-linux-gnu libc6-dev-mipsel-cross"
                    ;;
                powerpc64le-*-*)
                    install_packages="binutils-powerpc64le-linux-gnu libc6-dev-ppc64el-cross"
                    ;;
                s390x-*-*)
                    install_packages="binutils-s390x-linux-gnu libc6-dev-s390x-cross"
                    ;;
                sparc64-*-*)
                    install_packages="binutils-sparc64-linux-gnu libc6-dev-sparc64-cross"
                    ;;
                *)
                    install_packages="binutils libc6-dev"
                    ;;
            esac
            sudo apt-get update -qq
            sudo apt-get install -qq gcc-${host_package} g++-${host_package} gdc-${host_package} \
                ${install_packages} autogen autoconf automake dejagnu patch \
                libcurl4-gnutls-dev libgmp-dev libisl-dev libmpc-dev libmpfr-dev || exit 1
        else
            echo "Unhandled CI environment"
            exit 1
        fi
    else
        echo "Unhandled CI environment"
        exit 1
    fi
}

configure() {
    ## And download GCC prerequisites.
    # Makes use of local cache to save downloading on every build run.
    for prereq in ${gcc_prereqs}; do
        if [ ! -e ${cache_dir}/infrastructure/${prereq} ]; then
            curl "http://gcc.gnu.org/pub/gcc/infrastructure/${prereq}" \
                --location --retry 50 --create-dirs -o ${cache_dir}/infrastructure/${prereq} || exit 1
        fi
        tar -C ${project_dir} -xf ${cache_dir}/infrastructure/${prereq}
        ln -s "${project_dir}/${prereq%.tar*}" "${project_dir}/${prereq%-*}"
    done

    if [ "${SEMAPHORE}" = "true" ]; then
        if [ "${SEMAPHORE_AGENT_MACHINE_OS_IMAGE}" != "" ]; then
            cache store $SEMAPHORE_PROJECT_NAME-$SEMAPHORE_AGENT_MACHINE_OS_IMAGE-deps $cache_dir
        else
            cache store $SEMAPHORE_PROJECT_NAME-deps $cache_dir
        fi
    fi

    ## Apply any ad-hoc fixes to the sources.
    if [ "${build_prebuild_script}" != "" ]; then
       source ${build_prebuild_script}
    fi

    ## Create the build directory.
    # Build typically takes around 10 minutes with -j4, could this be cached across CI runs?
    mkdir ${project_dir}/build
    cd ${project_dir}/build

    ## Configure GCC to build a D compiler.
    ${project_dir}/configure --prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib --with-sysroot=/ \
        --enable-languages=${build_enable_languages} --enable-link-mutex \
        --disable-werror --disable-libgomp --disable-libmudflap \
        --disable-libquadmath --disable-libitm --disable-libsanitizer \
        --build=${build_host} --host=${build_host} --target=${build_target} \
        ${build_configure_flags} --with-bugurl="http://bugzilla.gdcproject.org"
}

setup() {
    installdeps
    environment
    configure
}

build() {
    if [ "${build_bootstrap}" = "enable" ]; then
        ## Build the entire project to completion.
        cd ${project_dir}/build
        ${MAKE} ${make_flags}
    else
        ## Build the bare-minimum in order to run tests.
        cd ${project_dir}/build
        ${MAKE} ${make_flags} all-gcc || exit 1

        # Note: libstdc++ and libphobos are built separately so that build errors don't mix.
        if [ "${build_supports_phobos}" = "yes" ]; then
            ${MAKE} ${make_flags} all-target-libstdc++-v3 || exit 1
            ${MAKE} ${make_flags} all-target-libphobos || exit 1
        fi
    fi
}

testsuite() {
    ## Run just the compiler testsuite.
    cd ${project_dir}/build

    ${MAKE} check-gcc RUNTESTFLAGS="help.exp"
    ${MAKE} ${make_flags} check-gcc-d RUNTESTFLAGS="${build_test_flags}"

    # Upload testsuite results
    save_logs

    # For now, be lenient towards any failures, just report on them.
    summary
}

unittests() {
    ## Run just the library unittests.
    if [ "${build_supports_phobos}" = "yes" ]; then
        cd ${project_dir}/build
        if ! ${MAKE} ${make_flags} -C ${build_target_phobos} check RUNTESTFLAGS="${build_test_flags}"; then
            save_logs
            echo "== Unittest has failures =="
            exit 1
        fi
        save_logs
    fi
}

summary() {
    ## Processes *.{sum,log} files, producing a summary of all testsuite runs.
    cd ${project_dir}/build
    files=`find . -name \*.sum -print | sort`
    anyfile=false

    for file in $files; do
        if [ -f $file ]; then
            anyfile=true
        fi
    done

    # Based on GCC testsuite summary scripts.
    if [ "${anyfile}" = "true" ]; then
        # We use cat instead of listing the files as arguments to AWK because
        # GNU awk 3.0.0 would break if any of the filenames contained `=' and
        # was preceded by an invalid variable name.
        ( echo @TOPLEVEL_CONFIGURE_ARGUMENTS@ | ./config.status --file=-; cat $files ) |
        awk '
        BEGIN {
            lang=""; configflags = "";
            version="gcc";
        }
        NR == 1 {
            configflags = $0 " ";
            srcdir = configflags;
            sub(/\/configure\047? .*/, "", srcdir);
            sub(/^\047/, "", srcdir);
            if ( system("test -f " srcdir "/LAST_UPDATED") == 0 ) {
                printf "LAST_UPDATED: ";
                system("tail -1 " srcdir "/LAST_UPDATED");
                print "";
            }

            sub(/^[^ ]*\/configure\047? */, " ", configflags);
            sub(/,;t t $/, " ", configflags);
            sub(/ --with-gcc-version-trigger=[^ ]* /, " ", configflags);
            sub(/ --norecursion /, " ", configflags);
            sub(/ $/, "", configflags);
            sub(/^ *$/, " none", configflags);
            configflags = "configure flags:" configflags;
        }
        /^Running target / { print; }
        /^Target / { if (host != "") next; else host = $3; }
        /^Host / && host ~ /^unix\{.*\}$/ { host = $3 " " substr(host, 5); }
        /^Native / { if (host != "") next; else host = $4; }
        /^[     ]*=== [^        ]+ tests ===/ {
            if (lang == "") lang = " "$2" "; else lang = " ";
        }
        $2 == "version" {
            save = $0; $1 = ""; $2 = ""; version = $0; gsub(/^ */, "", version); gsub(/\r$/, "", version); $0 = save;
        }
        /\===.*Summary/ || /tests ===/ { print ""; print; blanks=1; }
        /^(Target|Host|Native)/ { print; }
        /^(XPASS|FAIL|UNRESOLVED|WARNING|ERROR|# of )/ { sub ("\r", ""); print; }
        /^using:/ { print ""; print; print ""; }
        /^$/ && blanks>0 { print; --blanks; }
        END {
            if (lang != "") {
                print "";
                print "Compiler version: " prefix version lang;
                print "Platform: " host;
                print configflags;
            }
        }
        { next; }
        ' | sed "s/\([\`\$\\\\]\)/\\\\\\1/g"
    fi
}

save_logs() {
    cd ${project_dir}/build

    test -e ./gcc/testsuite/gdc/gdc.log && mkdir -p ${log_dir}/gdc && \
        mv gcc/testsuite/gdc/*.{sum,log} ${log_dir}/gdc
    test -e ./gcc/testsuite/gcc/gcc.log && mkdir -p ${log_dir}/gcc && \
        mv gcc/testsuite/gcc/*.{sum,log} ${log_dir}/gcc
    test -e ./${build_target}/libphobos/testsuite/libphobos.log && mkdir -p ${log_dir}/libphobos && \
        mv ${build_target}/libphobos/testsuite/*.{sum,log} ${log_dir}/libphobos

    # Compress logs
    find ${log_dir} \( -name \*.sum -o -name \*.log \) -exec xz \{\} \;
}

## Run a single build task or all at once.
if [ "$1" != "" ]; then
    # Skip calling environment if running setup, as dependencies might not be installed yet.
    if [ "$1" != "setup" ]; then
        environment
    fi
    $1
else
    setup
    build
    unittests
fi
