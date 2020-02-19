/* REQUIRED_ARGS:
TEST_OUTPUT:
---
fail_compilation/test17284.d(16): Error: field `U.c` cannot access pointers in `@safe` code that overlap other fields
pure nothrow @safe void(U t)
---
*/

// https://issues.dlang.org/show_bug.cgi?id=17284

class C { }
union U { C c; int i; }

@safe void func(T)(T t)
{
        t.c = new C;
}

pragma(msg, typeof(func!U));

