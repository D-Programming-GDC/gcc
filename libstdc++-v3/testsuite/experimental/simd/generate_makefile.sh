#!/bin/sh

srcdir="$(cd "${0%/*}" && pwd)"
driver="$srcdir/driver.sh"
srcdir="$srcdir/tests"
sim=
rm_logs=true
dst=.
testflags=

usage() {
  cat <<EOF
Usage: $0 [Options] <g++ invocation>

Options:
  -h, --help          Print this message and exit.
  --srcdir <path>     The source directory of the tests (default: $srcdir).
  --sim <executable>  Path to an executable that is prepended to the test
                      execution binary (default: none).
  --keep-intermediate-logs
                      Keep intermediate logs.
  --testflags <flags> Force initial TESTFLAGS contents.
  -d <path>, --destination <path>
                      Destination for the generated Makefile. If the directory
                      does not exist it is created (default: $dst).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
  -h|--help)
    usage
    exit
    ;;
  --testflags)
    testflags="$2"
    shift
    ;;
  --testflags=*)
    testflags="${1#--testflags=}"
    ;;
  -d|--destination)
    dst="$2"
    shift
    ;;
  --destination=*)
    dst="${1#--destination=}"
    ;;
  --keep-intermediate-logs)
    rm_logs=false
    ;;
  --srcdir)
    srcdir="$2"
    shift
    ;;
  --srcdir=*)
    srcdir="${1#--srcdir=}"
    ;;
  --sim)
    sim="$2"
    shift
    ;;
  --sim=*)
    sim="${1#--sim=}"
    ;;
  --)
    shift
    break
    ;;
  *)
    break
    ;;
  esac
  shift
done

mkdir -p "$dst"
dst="$dst/Makefile"
if [ -f "$dst" ]; then
  echo "Error: $dst already exists. Aborting." 1>&2
  exit 1
fi

CXX="$1"
shift

echo "TESTFLAGS ?=" > "$dst"
echo "test_flags := $testflags \$(TESTFLAGS)" >> "$dst"
echo CXXFLAGS = "$@" "\$(test_flags)" >> "$dst"
[ -n "$sim" ] && echo "export GCC_TEST_SIMULATOR = $sim" >> "$dst"
cat >> "$dst" <<EOF
srcdir = ${srcdir}
CXX = ${CXX}
DRIVER = ${driver}
DRIVEROPTS ?=
driveroptions := \$(DRIVEROPTS)

all: simd_testsuite.sum

simd_testsuite.sum: simd_testsuite.log
	@printf "\n\t\t=== simd_testsuite \$(test_flags) Summary ===\n\n"\\
	"# of expected passes:\t\t\$(shell grep -c '^PASS:' \$@)\n"\\
	"# of unexpected passes:\t\t\$(shell grep -c '^XPASS:' \$@)\n"\\
	"# of unexpected failures:\t\$(shell grep -c '^FAIL:' \$@)\n"\\
	"# of expected failures:\t\t\$(shell grep -c '^XFAIL:' \$@)\n"\\
	"# of unsupported tests:\t\t\$(shell grep -c '^UNSUPPORTED:' \$@)\n"\\
	  | tee -a \$@

EOF

matches() {
  eval "case '$1' in
    $2) return 0;; esac"
  return 1
}

cxx_type() {
  case "$1" in
    ldouble) echo "long double";;
    ullong)  echo "unsigned long long";;
    ulong)   echo "unsigned long";;
    llong)   echo "long long";;
    uint)    echo "unsigned int";;
    ushort)  echo "unsigned short";;
    uchar)   echo "unsigned char";;
    schar)   echo "signed char";;
    *)       echo "$1";;
  esac
}

filter_types() {
  only="$1"
  skip="$2"
  shift 2
  if [ -z "$only" -a -z "$skip" ]; then
    for x in "$@"; do
      cxx_type "$x"
      echo "$x"
    done
  elif [ -z "$skip" ]; then
    for x in "$@"; do
      if matches "$x" "$only"; then
        cxx_type "$x"
        echo "$x"
      fi
    done
  elif [ -z "$only" ]; then
    for x in "$@"; do
      matches "$x" "$skip" && continue
      cxx_type "$x"
      echo "$x"
    done
  else
    for x in "$@"; do
      matches "$x" "$skip" && continue
      if matches "$x" "$only"; then
        cxx_type "$x"
        echo "$x"
      fi
    done
  fi
}

all_types() {
  src="$1"
  only=
  skip=
  if [ -n "$src" ]; then
    only="$(head -n25 "$src"| grep '^//\s*only: [^ ]* \* \* \*')"
    only="${only#*: }"
    only="${only%% *}"
    skip="$(head -n25 "$src"| grep '^//\s*skip: [^ ]* \* \* \*')"
    skip="${skip#*: }"
    skip="${skip%% *}"
  fi
  filter_types "$only" "$skip" \
    "ldouble" \
    "double" \
    "float" \
    "llong" \
    "ullong" \
    "ulong" \
    "long" \
    "int" \
    "uint" \
    "short" \
    "ushort" \
    "char" \
    "schar" \
    "uchar" \
    "char32_t" \
    "char16_t" \
    "wchar_t"
}

all_tests() {
  if [ -f testsuite_files_simd ]; then
    sed 's,^experimental/simd/tests/,,' testsuite_files_simd | while read file; do
      echo "$srcdir/$file"
      echo "${file%.cc}"
    done
  else
    for file in ${srcdir}/*.cc; do
      echo "$file"
      name="${file%.cc}"
      echo "${name##*/}"
    done
  fi
}

{
  rmline=""
  if $rm_logs; then
    rmline="
	@rm \$^ \$(^:log=sum)"
  fi
  echo -n "simd_testsuite.log:"
  all_tests | while read file && read name; do
    echo -n " $name.log"
  done
  cat <<EOF

	@cat $^ > \$@
	@cat \$(^:log=sum) > \$(@:log=sum)${rmline}

EOF
  all_tests | while read file && read name; do
    echo -n "$name.log:"
    all_types "$file" | while read t && read type; do
      echo -n " $name-$type.log"
    done
    cat <<EOF

	@cat $^ > \$@
	@cat \$(^:log=sum) > \$(@:log=sum)${rmline}

EOF
  done
  all_types | while read t && read type; do
    cat <<EOF
%-$type.log: %-$type-0.log %-$type-1.log %-$type-2.log %-$type-3.log \
%-$type-4.log %-$type-5.log %-$type-6.log %-$type-7.log \
%-$type-8.log %-$type-9.log
	@cat \$^ > \$@
	@cat \$(^:log=sum) > \$(@:log=sum)${rmline}

EOF
    for i in $(seq 0 9); do
      cat <<EOF
%-$type-$i.log: \$(srcdir)/%.cc
	@\$(DRIVER) \$(driveroptions) -t "$t" -a $i -n \$* \$(CXX) \$(CXXFLAGS)

EOF
    done
  done
  cat <<EOF
run-%: export GCC_TEST_RUN_EXPENSIVE=yes
run-%: driveroptions += -v
run-%: %.log
	@rm \$^ \$(^:log=sum)

help: .make_help.txt
	@cat \$<

EOF
  dsthelp="${dst%Makefile}.make_help.txt"
  cat <<EOF > "$dsthelp"
use DRIVEROPTS=<options> to pass the following options:
-q, --quiet         Only print failures.
-v, --verbose       Print compiler and test output on failure.
-k, --keep-failed   Keep executables of failed tests.
--sim <executable>  Path to an executable that is prepended to the test
                    execution binary (default: the value of
                    GCC_TEST_SIMULATOR).
--timeout-factor <x>
                    Multiply the default timeout with x.
--run-expensive     Compile and run tests marked as expensive (default:
                    true if GCC_TEST_RUN_EXPENSIVE is set, false otherwise).
--only <pattern>    Compile and run only tests matching the given pattern.

use TESTFLAGS=<flags> to pass additional compiler flags

The following are some of the valid targets for this Makefile:
... all
... clean
... help"
EOF
  all_tests | while read file && read name; do
    echo "... run-${name}"
    all_types | while read t && read type; do
      echo "... run-${name}-${type}"
      for i in $(seq 0 9); do
        echo "... run-${name}-${type}-$i"
      done
    done
  done >> "$dsthelp"
  cat <<EOF

clean:
	rm -f -- *.sum *.log *.exe

.PHONY: clean help

.PRECIOUS: %.log %.sum
EOF
} >> "$dst"

