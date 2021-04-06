
/* Compiler implementation of the D programming language
 * Copyright (C) 1999-2021 by The D Language Foundation, All Rights Reserved
 * written by Walter Bright
 * http://www.digitalmars.com
 * Distributed under the Boost Software License, Version 1.0.
 * http://www.boost.org/LICENSE_1_0.txt
 * https://github.com/dlang/dmd/blob/master/src/dmd/compiler.h
 */

#pragma once

#include "root/array.h"
#include "root/bitarray.h"

// This file contains a data structure that describes a back-end compiler
// and implements compiler-specific actions.

class Expression;
class Module;
class Type;
struct Scope;
struct UnionExp;

// DMD-generated module `__entrypoint` where the C main resides
extern Module *entrypoint;
// Module in which the D main is
extern Module *rootHasMain;

extern bool includeImports;
// array of module patterns used to include/exclude imported modules
extern Array<const char*> includeModulePatterns;
extern Array<Module *> compiledImports;

struct Compiler
{
    // CTFE support for cross-compilation.
    static Expression *paintAsType(UnionExp *, Expression *, Type *);
    // Backend
    static void genCmain(Scope *);
    static bool onImport(Module *);
    static void onParseModule(Module *);
};
