/**
 * Implement CTFE for intrinsic (builtin) functions.
 *
 * Currently includes functions from `std.math`, `core.math` and `core.bitop`.
 *
 * Copyright:   Copyright (C) 1999-2021 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/builtin.d, _builtin.d)
 * Documentation:  https://dlang.org/phobos/dmd_builtin.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/builtin.d
 */

module dmd.builtin;

import core.stdc.math;
import core.stdc.string;
import dmd.arraytypes;
import dmd.expression;
import dmd.func;
import dmd.globals;

/**********************************
 * Determine if function is a builtin one that we can
 * evaluate at compile time.
 */
public extern (C++) BUILTIN isBuiltin(FuncDeclaration fd);

/**************************************
 * Evaluate builtin function.
 * Return result; NULL if cannot evaluate it.
 */
public extern (C++) Expression eval_builtin(Loc loc, FuncDeclaration fd, Expressions* arguments);
