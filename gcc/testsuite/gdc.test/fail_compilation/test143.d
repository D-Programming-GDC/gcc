// REQUIRED_ARGS: -de
// https://issues.dlang.org/show_bug.cgi?id=143
/*
TEST_OUTPUT:
---
fail_compilation/test143.d(19): Error: undefined identifier `x`
---
*/
module test143;

import imports.test143;

void bar(int)
{
}

void foo()
{
    bar(x);
}
