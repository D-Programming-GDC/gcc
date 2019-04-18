/*
REQUIRED_ARGS: -de
TEST_OUTPUT:
---
fail_compilation/test12228.d(14): Deprecation: Using `this` as a type is deprecated. Use `typeof(this)` instead
fail_compilation/test12228.d(19): Error: no property `x` for type `object.Object`
fail_compilation/test12228.d(20): Deprecation: Using `super` as a type is deprecated. Use `typeof(super)` instead
fail_compilation/test12228.d(21): Deprecation: Using `super` as a type is deprecated. Use `typeof(super)` instead
---
*/

class C
{
    shared(this) x;
}

class D : C
{
    alias x = typeof(super).x;
    shared(super) a;
    super b;
}
