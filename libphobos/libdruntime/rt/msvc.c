/**
* This module provides MS VC runtime helper function that
* wrap differences between different versions of the MS C runtime
*
* Copyright: Copyright Digital Mars 2015.
* License: Distributed under the
*      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
*    (See accompanying file LICENSE)
* Source:    $(DRUNTIMESRC rt/_msvc.c)
* Authors:   Rainer Schuetze
*/

#include <stddef.h>
#include <stdarg.h>
#include <_mingw.h>
#include "config.h"

struct _iobuf
{
    char* _ptr;
    int   _cnt;  // _cnt and _base exchanged for VS2015
    char* _base;
    int   _flag;
    int   _file;
    int   _charbuf;
    int   _bufsiz;
    char* _tmpfname;
    // additional members in VS2015
};

typedef struct _iobuf FILE;
extern FILE* stdin;
extern FILE* stdout;
extern FILE* stderr;
int _vsnprintf(char *buffer, size_t count, const char *format, va_list argptr);

#if __MSVCRT_VERSION__ >= 0x1400
FILE* __acrt_iob_func(int hnd);     // VS2015+
#endif
#if __MSVCRT_VERSION__ <= 0x1200
FILE* __iob_func();                 // VS2013-

int _set_output_format(int format); // VS2013-
#endif


#if defined _M_IX86 || (defined __MINGW32__ && defined __i386__)
    #define C_PREFIX "_"
#elif defined _M_X64 || defined _M_ARM || defined _M_ARM64 || (defined __MINGW32__ && defined __x86_64__)
    #define C_PREFIX ""
#else
    #error Unsupported architecture
#endif

// Upstream uses these linker directives to build one library which works
// for multiple MSVC versions. In theory, we can do that as well, but
// as binutils is broken, this won't fly:
// https://sourceware.org/bugzilla/show_bug.cgi?id=9687
// We use the __MSVCRT_VERSION__ macro instead, so our library can only be used with
// the MSVC version it's compiled for.
#if defined __GNUC__
#define DECLARE_ALTERNATE_NAME(name, alternate_name)  \
    asm ("    .weak " C_PREFIX #name "\n" \
         "    .set " C_PREFIX #name "," C_PREFIX #alternate_name "\n");
#else
#define DECLARE_ALTERNATE_NAME(name, alternate_name)  \
    __pragma(comment(linker, "/alternatename:" C_PREFIX #name "=" C_PREFIX #alternate_name))
#endif

void init_msvc()
{
#if __MSVCRT_VERSION__ >= 0x1400
    stdin = __acrt_iob_func(0);
    stdout = __acrt_iob_func(1);
    stderr = __acrt_iob_func(2);
#elif __MSVCRT_VERSION__ <= 0x1200
    FILE* fp = __iob_func();
    stdin = fp;
    stdout = fp + 1;
    stderr = fp + 2;
#endif
#if __MSVCRT_VERSION__ <= 0x1200
    const int _TWO_DIGIT_EXPONENT = 1;
    _set_output_format(_TWO_DIGIT_EXPONENT);
#endif
}

// VS2015+ provides C99-conformant (v)snprintf functions, so weakly
// link to legacy _(v)snprintf (not C99-conformant!) for VS2013- only

#if __MSVCRT_VERSION__ <= 0x1200
int snprintf ( char * s, size_t n, const char * format, ... )
{
    va_list arg;
    va_start(arg, format);
    int ret = _vsnprintf(s, n, format, arg);
    va_end(arg);
    return ret;
}

int vsnprintf (char * s, size_t n, const char * format, va_list arg )
{
    _vsnprintf(s, n, format, arg);
}
#endif

// VS2013- implements these functions as macros, VS2015+ provides symbols

#if __MSVCRT_VERSION__ <= 0x1200

// VS2013- helper functions
int _filbuf(FILE* fp);
int _flsbuf(int c, FILE* fp);

int _fputc_nolock(int c, FILE* fp)
{
    fp->_cnt = fp->_cnt - 1;
    if (fp->_cnt >= 0)
    {
        *(fp->_ptr) = (char)c;
        fp->_ptr = fp->_ptr + 1;
        return (char)c;
    }
    else
        return _flsbuf(c, fp);
}

int _fgetc_nolock(FILE* fp)
{
    fp->_cnt = fp->_cnt - 1;
    if (fp->_cnt >= 0)
    {
        char c = *(fp->_ptr);
        fp->_ptr = fp->_ptr + 1;
        return c;
    }
    else
        return _filbuf(fp);
}

enum
{
    SEEK_SET = 0,
    _IOEOF   = 0x10,
    _IOERR   = 0x20
};

int fseek(FILE* fp, long off, int whence);

void rewind(FILE* stream)
{
    fseek(stream, 0L, SEEK_SET);
    stream->_flag = stream->_flag & ~_IOERR;
}

void clearerr(FILE* stream)
{
    stream->_flag = stream->_flag & ~(_IOERR | _IOEOF);
}

int  feof(FILE* stream)
{
    return stream->_flag & _IOEOF;
}

int  ferror(FILE* stream)
{
    return stream->_flag & _IOERR;
}

int  fileno(FILE* stream)
{
    return stream->_file;
}
#endif


/**
 * 32-bit x86 MS VC runtimes lack most single-precision math functions.
 * Alternate implementations are pulled in from msvc_math.c.
 */
