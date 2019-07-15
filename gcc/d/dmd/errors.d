/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2019 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/errors.d, _errors.d)
 * Documentation:  https://dlang.org/phobos/dmd_errors.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/errors.d
 */

module dmd.errors;

import core.stdc.stdarg;
import dmd.globals;

nothrow:

/// Interface for diagnostic reporting.
abstract class DiagnosticReporter
{
  nothrow:

    /// Returns: the number of errors that occurred during lexing or parsing.
    abstract int errorCount();

    /// Returns: the number of warnings that occurred during lexing or parsing.
    abstract int warningCount();

    /// Returns: the number of deprecations that occurred during lexing or parsing.
    abstract int deprecationCount();

    /**
    Reports an error message.

    Params:
        loc = Location of error
        format = format string for error
        ... = format string arguments
    */
    final void error(const ref Loc loc, const(char)* format, ...)
    {
        va_list args;
        va_start(args, format);
        error(loc, format, args);
        va_end(args);
    }

    /// ditto
    abstract void error(const ref Loc loc, const(char)* format, va_list args);

    /**
    Reports additional details about an error message.

    Params:
        loc = Location of error
        format = format string for supplemental message
        ... = format string arguments
    */
    final void errorSupplemental(const ref Loc loc, const(char)* format, ...)
    {
        va_list args;
        va_start(args, format);
        errorSupplemental(loc, format, args);
        va_end(args);
    }

    /// ditto
    abstract void errorSupplemental(const ref Loc loc, const(char)* format, va_list);

    /**
    Reports a warning message.

    Params:
        loc = Location of warning
        format = format string for warning
        ... = format string arguments
    */
    final void warning(const ref Loc loc, const(char)* format, ...)
    {
        va_list args;
        va_start(args, format);
        warning(loc, format, args);
        va_end(args);
    }

    /// ditto
    abstract void warning(const ref Loc loc, const(char)* format, va_list args);

    /**
    Reports additional details about a warning message.

    Params:
        loc = Location of warning
        format = format string for supplemental message
        ... = format string arguments
    */
    final void warningSupplemental(const ref Loc loc, const(char)* format, ...)
    {
        va_list args;
        va_start(args, format);
        warningSupplemental(loc, format, args);
        va_end(args);
    }

    /// ditto
    abstract void warningSupplemental(const ref Loc loc, const(char)* format, va_list);

    /**
    Reports a deprecation message.

    Params:
        loc = Location of the deprecation
        format = format string for the deprecation
        ... = format string arguments
    */
    final void deprecation(const ref Loc loc, const(char)* format, ...)
    {
        va_list args;
        va_start(args, format);
        deprecation(loc, format, args);
        va_end(args);
    }

    /// ditto
    abstract void deprecation(const ref Loc loc, const(char)* format, va_list args);

    /**
    Reports additional details about a deprecation message.

    Params:
        loc = Location of deprecation
        format = format string for supplemental message
        ... = format string arguments
    */
    final void deprecationSupplemental(const ref Loc loc, const(char)* format, ...)
    {
        va_list args;
        va_start(args, format);
        deprecationSupplemental(loc, format, args);
        va_end(args);
    }

    /// ditto
    abstract void deprecationSupplemental(const ref Loc loc, const(char)* format, va_list);
}

/**
Diagnostic reporter which prints the diagnostic messages to stderr.

This is usually the default diagnostic reporter.
*/
final class StderrDiagnosticReporter : DiagnosticReporter
{
    private const DiagnosticReporting useDeprecated;

    private int errorCount_;
    private int warningCount_;
    private int deprecationCount_;

  nothrow:

    /**
    Initializes this object.

    Params:
        useDeprecated = indicates how deprecation diagnostics should be
            handled
    */
    this(DiagnosticReporting useDeprecated)
    {
        this.useDeprecated = useDeprecated;
    }

    override int errorCount()
    {
        return errorCount_;
    }

    override int warningCount()
    {
        return warningCount_;
    }

    override int deprecationCount()
    {
        return deprecationCount_;
    }

    override void error(const ref Loc loc, const(char)* format, va_list args)
    {
        verror(loc, format, args);
        errorCount_++;
    }

    override void errorSupplemental(const ref Loc loc, const(char)* format, va_list args)
    {
        verrorSupplemental(loc, format, args);
    }

    override void warning(const ref Loc loc, const(char)* format, va_list args)
    {
        vwarning(loc, format, args);
        warningCount_++;
    }

    override void warningSupplemental(const ref Loc loc, const(char)* format, va_list args)
    {
        vwarningSupplemental(loc, format, args);
    }

    override void deprecation(const ref Loc loc, const(char)* format, va_list args)
    {
        vdeprecation(loc, format, args);

        if (useDeprecated == DiagnosticReporting.error)
            errorCount_++;
        else
            deprecationCount_++;
    }

    override void deprecationSupplemental(const ref Loc loc, const(char)* format, va_list args)
    {
        vdeprecationSupplemental(loc, format, args);
    }
}

/**
 * Print an error message, increasing the global error count.
 * Params:
 *      loc    = location of error
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void error(const ref Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    verror(loc, format, ap);
    va_end(ap);
}

/**
 * Same as above, but allows Loc() literals to be passed.
 * Params:
 *      loc    = location of error
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (D) void error(Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    verror(loc, format, ap);
    va_end(ap);
}

/**
 * Same as above, but takes a filename and line information arguments as separate parameters.
 * Params:
 *      filename = source file of error
 *      linnum   = line in the source file
 *      charnum  = column number on the line
 *      format   = printf-style format specification
 *      ...      = printf-style variadic arguments
 */
extern (C++) void error(const(char)* filename, uint linnum, uint charnum, const(char)* format, ...)
{
    const loc = Loc(filename, linnum, charnum);
    va_list ap;
    va_start(ap, format);
    verror(loc, format, ap);
    va_end(ap);
}

/**
 * Print additional details about an error message.
 * Doesn't increase the error count or print an additional error prefix.
 * Params:
 *      loc    = location of error
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void errorSupplemental(const ref Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    verrorSupplemental(loc, format, ap);
    va_end(ap);
}

/**
 * Print a warning message, increasing the global warning count.
 * Params:
 *      loc    = location of warning
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void warning(const ref Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    vwarning(loc, format, ap);
    va_end(ap);
}

/**
 * Print additional details about a warning message.
 * Doesn't increase the warning count or print an additional warning prefix.
 * Params:
 *      loc    = location of warning
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void warningSupplemental(const ref Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    vwarningSupplemental(loc, format, ap);
    va_end(ap);
}

/**
 * Print a deprecation message, may increase the global warning or error count
 * depending on whether deprecations are ignored.
 * Params:
 *      loc    = location of deprecation
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void deprecation(const ref Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    vdeprecation(loc, format, ap);
    va_end(ap);
}

/**
 * Print additional details about a deprecation message.
 * Doesn't increase the error count, or print an additional deprecation prefix.
 * Params:
 *      loc    = location of deprecation
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void deprecationSupplemental(const ref Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    vdeprecationSupplemental(loc, format, ap);
    va_end(ap);
}

/**
 * Print a verbose message.
 * Doesn't prefix or highlight messages.
 * Params:
 *      loc    = location of message
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void message(const ref Loc loc, const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    vmessage(loc, format, ap);
    va_end(ap);
}

/**
 * Same as above, but doesn't take a location argument.
 * Params:
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void message(const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    vmessage(Loc.initial, format, ap);
    va_end(ap);
}

/**
 * Print a tip message with the prefix and highlighting.
 * Params:
 *      format = printf-style format specification
 *      ...    = printf-style variadic arguments
 */
extern (C++) void tip(const(char)* format, ...)
{
    va_list ap;
    va_start(ap, format);
    vtip(format, ap);
    va_end(ap);
}

/**
 * Same as $(D error), but takes a va_list parameter, and optionally additional message prefixes.
 * Params:
 *      loc    = location of error
 *      format = printf-style format specification
 *      ap     = printf-style variadic arguments
 *      p1     = additional message prefix
 *      p2     = additional message prefix
 *      header = title of error message
 */
extern (C++) void verror(const ref Loc loc, const(char)* format, va_list ap, const(char)* p1 = null, const(char)* p2 = null, const(char)* header = "Error: ");

/**
 * Same as $(D errorSupplemental), but takes a va_list parameter.
 * Params:
 *      loc    = location of error
 *      format = printf-style format specification
 *      ap     = printf-style variadic arguments
 */
extern (C++) void verrorSupplemental(const ref Loc loc, const(char)* format, va_list ap);

/**
 * Same as $(D warning), but takes a va_list parameter.
 * Params:
 *      loc    = location of warning
 *      format = printf-style format specification
 *      ap     = printf-style variadic arguments
 */
extern (C++) void vwarning(const ref Loc loc, const(char)* format, va_list ap);

/**
 * Same as $(D warningSupplemental), but takes a va_list parameter.
 * Params:
 *      loc    = location of warning
 *      format = printf-style format specification
 *      ap     = printf-style variadic arguments
 */
extern (C++) void vwarningSupplemental(const ref Loc loc, const(char)* format, va_list ap);

/**
 * Same as $(D deprecation), but takes a va_list parameter, and optionally additional message prefixes.
 * Params:
 *      loc    = location of deprecation
 *      format = printf-style format specification
 *      ap     = printf-style variadic arguments
 *      p1     = additional message prefix
 *      p2     = additional message prefix
 */
extern (C++) void vdeprecation(const ref Loc loc, const(char)* format, va_list ap, const(char)* p1 = null, const(char)* p2 = null);

/**
 * Same as $(D message), but takes a va_list parameter.
 * Params:
 *      loc       = location of message
 *      format    = printf-style format specification
 *      ap        = printf-style variadic arguments
 */
extern (C++) void vmessage(const ref Loc loc, const(char)* format, va_list ap);

/**
 * Same as $(D tip), but takes a va_list parameter.
 * Params:
 *      format    = printf-style format specification
 *      ap        = printf-style variadic arguments
 */
extern (C++) void vtip(const(char)* format, va_list ap);

/**
 * Same as $(D deprecationSupplemental), but takes a va_list parameter.
 * Params:
 *      loc    = location of deprecation
 *      format = printf-style format specification
 *      ap     = printf-style variadic arguments
 */
extern (C++) void vdeprecationSupplemental(const ref Loc loc, const(char)* format, va_list ap);

/**
 * Call this after printing out fatal error messages to clean up and exit
 * the compiler.
 */
extern (C++) void fatal();

/**
 * Try to stop forgetting to remove the breakpoints from
 * release builds.
 */
extern (C++) void halt();
