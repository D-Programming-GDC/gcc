/* compiler.d -- Compiler interface for the D front end.
 * Copyright (C) 2019 Free Software Foundation, Inc.
 *
 * GCC is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3, or (at your option)
 * any later version.
 *
 * GCC is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with GCC; see the file COPYING3.  If not see
 * <http://www.gnu.org/licenses/>.
 */

module dmd.compiler;

import dmd.arraytypes;
import dmd.dmodule;
import dmd.dscope;
import dmd.expression;
import dmd.mtype;
import dmd.root.array;

extern (C++) __gshared
{
    /// Module in which the D main is
    Module rootHasMain = null;

    bool includeImports = false;
    // array of module patterns used to include/exclude imported modules
    Array!(const(char)*) includeModulePatterns;
    Modules compiledImports;
}


/**
 * A data structure that describes a back-end compiler and implements
 * compiler-specific actions.
 */
extern (C++) struct Compiler
{
    /******************************
     * Encode the given expression, which is assumed to be an rvalue literal
     * as another type for use in CTFE.
     * This corresponds roughly to the idiom *(Type *)&e.
     */
    extern (C++) static Expression paintAsType(UnionExp* pue, Expression e, Type type);

    /******************************
     * For the given module, perform any post parsing analysis.
     * Certain compiler backends (ie: GDC) have special placeholder
     * modules whose source are empty, but code gets injected
     * immediately after loading.
     */
    extern (C++) static void loadModule(Module m);

    /**
     * A callback function that is called once an imported module is
     * parsed. If the callback returns true, then it tells the
     * frontend that the driver intends on compiling the import.
     */
    extern (C++) static bool onImport(Module m);
}
