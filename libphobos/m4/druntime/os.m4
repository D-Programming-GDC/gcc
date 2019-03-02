#
# Contains macros to detect OS features.
#


# DRUNTIME_OS_THREAD_MODEL
# ------------------------
# Detect thread model and substitute DCFG_THREAD_MODEL
AC_DEFUN([DRUNTIME_OS_THREAD_MODEL],
[
  AC_REQUIRE([AC_PROG_GDC])
  AC_MSG_CHECKING([for thread model used by GDC])
  d_thread_model=`$GDC -v 2>&1 | sed -n 's/^Thread model: //p'`
  AC_MSG_RESULT([$d_thread_model])

  # Map from thread model to thread interface.
  DRUNTIME_CONFIGURE_THREADS([$d_thread_model])
])


# DRUNTIME_CONFIGURE_THREADS(thread_model)
# ----------------------------------------
# Map target os to D version identifier
AC_DEFUN([DRUNTIME_CONFIGURE_THREADS],
[
case $1 in
    aix)    DCFG_THREAD_MODEL="Posix" ;;
    lynx)   DCFG_THREAD_MODEL="Posix" ;;
    posix)  DCFG_THREAD_MODEL="Posix" ;;
    single) DCFG_THREAD_MODEL="Single" ;;
    win32)  DCFG_THREAD_MODEL="Win32" ;;
    # TODO: These targets need porting.
    dce|mipssde|rtems|tpf|vxworks)
	    DCFG_THREAD_MODEL="Single" ;;
    *)	    as_fn_error "Thread implementation '$1' not recognised" "$LINENO" 5 ;;
esac
AC_SUBST(DCFG_THREAD_MODEL)
])


# DRUNTIME_OS_DETECT
# ------------------
# Set the druntime_cv_target_os variable
AC_DEFUN([DRUNTIME_OS_DETECT],
[
  AC_CACHE_CHECK([[for target OS]],
    [[druntime_cv_target_os]],
    [[druntime_cv_target_os=`echo $target_os | sed 's/^\([A-Za-z_]+\)/\1/'`]])
    AS_IF([[test -z "$druntime_cv_target_os"]],
      [AC_MSG_ERROR([[can't detect target OS]])],
      [])
])


# DRUNTIME_OS_UNIX
# ----------------
# Add --enable-unix option or autodetects if system is unix
# and create the DRUNTIME_OS_UNIX conditional.
AC_DEFUN([DRUNTIME_OS_UNIX],
[
  AC_REQUIRE([DRUNTIME_OS_DETECT])
  AC_ARG_ENABLE(unix,
    AC_HELP_STRING([--enable-unix],
                   [enables Unix runtime (default: yes, for Unix targets)]),
    :,[enable_unix=auto])

  case "$druntime_cv_target_os" in
    aix*|*bsd*|cygwin*|darwin*|gnu*|linux*|skyos*|*solaris*|sysv*) d_have_unix=1 ;;
  esac
  if test -n "$d_have_unix" && test "$enable_unix" = auto ; then
    enable_unix=yes
  fi
  AM_CONDITIONAL([DRUNTIME_OS_UNIX], [test "$enable_unix" = "yes"])
])


# DRUNTIME_OS_SOURCES
# -------------------
# Detect target OS and add DRUNTIME_OS_AIX DRUNTIME_OS_DARWIN
# DRUNTIME_OS_FREEBSD DRUNTIME_OS_LINUX DRUNTIME_OS_MINGW
# DRUNTIME_OS_SOLARIS DRUNTIME_OS_OPENBSD conditionals.
AC_DEFUN([DRUNTIME_OS_SOURCES],
[
  AC_REQUIRE([DRUNTIME_OS_DETECT])

  druntime_target_os_parsed=""
  case "$druntime_cv_target_os" in
      aix*)    druntime_target_os_parsed="aix"
               ;;
      *android*)
               druntime_target_os_parsed="android"
               ;;
      darwin*) druntime_target_os_parsed="darwin"
               ;;
      dragonfly*)
               druntime_target_os_parsed="dragonflybsd"
               ;;
      freebsd*|k*bsd*-gnu)
               druntime_target_os_parsed="freebsd"
               ;;
      openbsd*)
               druntime_target_os_parsed="openbsd"
               ;;
      netbsd*)
               druntime_target_os_parsed="netbsd"
               ;;
      linux*)  druntime_target_os_parsed="linux"
               ;;
      mingw*)  druntime_target_os_parsed="mingw"
             ;;
      *solaris*) druntime_target_os_parsed="solaris"
  esac
  AM_CONDITIONAL([DRUNTIME_OS_AIX],
                 [test "$druntime_target_os_parsed" = "aix"])
  AM_CONDITIONAL([DRUNTIME_OS_ANDROID],
                 [test "$druntime_target_os_parsed" = "android"])
  AM_CONDITIONAL([DRUNTIME_OS_DARWIN],
                 [test "$druntime_target_os_parsed" = "darwin"])
  AM_CONDITIONAL([DRUNTIME_OS_DRAGONFLYBSD],
                 [test "$druntime_target_os_parsed" = "dragonflybsd"])
  AM_CONDITIONAL([DRUNTIME_OS_FREEBSD],
                 [test "$druntime_target_os_parsed" = "freebsd"])
  AM_CONDITIONAL([DRUNTIME_OS_NETBSD],
                 [test "$druntime_target_os_parsed" = "netbsd"])
  AM_CONDITIONAL([DRUNTIME_OS_OPENBSD],
                 [test "$druntime_target_os_parsed" = "openbsd"])
  AM_CONDITIONAL([DRUNTIME_OS_LINUX],
                 [test "$druntime_target_os_parsed" = "linux"])
  AM_CONDITIONAL([DRUNTIME_OS_MINGW],
                 [test "$druntime_target_os_parsed" = "mingw"])
  AM_CONDITIONAL([DRUNTIME_OS_SOLARIS],
                 [test "$druntime_target_os_parsed" = "solaris"])
])


# DRUNTIME_OS_ARM_EABI_UNWINDER
# ------------------------
# Check if using ARM unwinder and substitute DCFG_ARM_EABI_UNWINDER
# and set DRUNTIME_OS_ARM_EABI_UNWINDER conditional.
AC_DEFUN([DRUNTIME_OS_ARM_EABI_UNWINDER],
[
  AC_LANG_PUSH([C])
  AC_MSG_CHECKING([for ARM unwinder])
  AC_TRY_COMPILE([#include <unwind.h>],[
  #if __ARM_EABI_UNWINDER__
  #error Yes, it is.
  #endif
  ],
    [AC_MSG_RESULT([no])
     DCFG_ARM_EABI_UNWINDER=false],
    [AC_MSG_RESULT([yes])
     DCFG_ARM_EABI_UNWINDER=true])
  AC_SUBST(DCFG_ARM_EABI_UNWINDER)
  AM_CONDITIONAL([DRUNTIME_OS_ARM_EABI_UNWINDER], [test "$DCFG_ARM_EABI_UNWINDER" = "true"])
  AC_LANG_POP([C])
])


# DRUNTIME_OS_MINFO_BRACKETING
# ----------------------------
# Check if the linker provides __start_minfo and __stop_minfo symbols and
# substitute DCFG_MINFO_BRACKETING.
AC_DEFUN([DRUNTIME_OS_MINFO_BRACKETING],
[
  AC_LANG_PUSH([C])
  AC_MSG_CHECKING([for minfo section bracketing])
  AC_LINK_IFELSE([AC_LANG_SOURCE([
    void* module_info_ptr __attribute__((section ("minfo")));
    extern void* __start_minfo __attribute__((visibility ("hidden")));
    extern void* __stop_minfo __attribute__((visibility ("hidden")));

    int main()
    {
        // Never run, just to prevent compiler from optimizing access
        return &__start_minfo == &__stop_minfo;
    }
  ])],
    [AC_MSG_RESULT([yes])
     DCFG_MINFO_BRACKETING=true],
    [AC_MSG_RESULT([no])
     DCFG_MINFO_BRACKETING=false])
  AC_SUBST(DCFG_MINFO_BRACKETING)
  AM_CONDITIONAL([DRUNTIME_OS_MINFO_BRACKETING], [test "$DCFG_MINFO_BRACKETING" = "true"])
  AC_LANG_POP([C])
])

# DRUNTIME_OS_SHARED_SUPPORT
# --------------------------
# Override LT_INIT shared lib values for OS where we do not support
# building shared druntime libs.
AC_DEFUN([DRUNTIME_OS_SHARED_SUPPORT],
[
  AC_REQUIRE([DRUNTIME_OS_DETECT])

  case "$druntime_cv_target_os" in
    mingw*)
      AC_MSG_NOTICE([Shared phobos libraries are not supported for windows targets. Disabled.])
      enable_shared=no
      enable_static=yes
      ;;
  esac
])

# DRUNTIME_OS_EXTRA_GDCFLAGS
# --------------------------
# Add OS specific flags to GDCFLAGS and GDCFLAGSX.
AC_DEFUN([DRUNTIME_OS_EXTRA_GDCFLAGS],
[
  AC_REQUIRE([DRUNTIME_OS_DETECT])
  AC_MSG_CHECKING([for extra flags to pass to unit test build])
  OS_EXTRA_GDCFLAGSX=""
  case "$druntime_cv_target_os" in
    mingw*)
      OS_EXTRA_GDCFLAGSX="-Wa,-mbig-obj"
      ;;
  esac
  AC_MSG_RESULT([$OS_EXTRA_GDCFLAGSX])
  GDCFLAGSX="$GDCFLAGSX $OS_EXTRA_GDCFLAGSX"
])

# DRUNTIME_OS_TLS
# ---------------
# Check whether OS supports TLS. If it uses emutls, check if
# emutls supports GC hooks.
AC_DEFUN([DRUNTIME_OS_TLS],
[
  AC_LANG_PUSH(D)
    AC_MSG_CHECKING([If gdc compiler uses emutls])
    OS_EMUTLS=no
    AC_COMPILE_IFELSE([AC_LANG_SOURCE([
      version (GNU_EMUTLS)
          static assert(false);
      ])],[
        OS_EMUTLS=no
        AC_MSG_RESULT([no])
      ], [
        OS_EMUTLS=yes
        AC_MSG_RESULT([yes])
      ])
  AC_LANG_POP(D)

  AS_IF([[ test "x$OS_EMUTLS" == "xyes"]], [
    AC_LANG_PUSH(C)
    AC_MSG_CHECKING([If emutls supports GC hooks])
    AC_LINK_IFELSE([AC_LANG_PROGRAM(
        [void __emutls_iterate_memory (void *cb, void* user);], [[return 0;]])],[
        AC_MSG_RESULT([yes])
      ], [
        AC_MSG_RESULT([no])
        AC_MSG_ERROR([emutls without GC hooks is not supported!])
    ])
    AC_LANG_POP(C)
  ])
])
