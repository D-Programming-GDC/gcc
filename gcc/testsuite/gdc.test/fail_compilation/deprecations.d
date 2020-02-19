/*
REQUIRED_ARGS: -de
TEST_OUTPUT:
---
fail_compilation/deprecations.d(42): Deprecation: struct `deprecations.S` is deprecated
fail_compilation/deprecations.d(63): Error: template instance `deprecations.otherPar!()` error instantiating
fail_compilation/deprecations.d(54): Deprecation: struct `deprecations.S` is deprecated
fail_compilation/deprecations.d(54): Deprecation: struct `deprecations.S` is deprecated
fail_compilation/deprecations.d(64): Error: template instance `deprecations.otherVar!()` error instantiating
---

https://issues.dlang.org/show_bug.cgi?id=20474
*/

deprecated struct S {}

deprecated void foo()(S par) if (is(S == S))
{
    S var;
}

deprecated template bar()  if (is(S == S))
{
    void bar(S par)
    {
        S var;
    }
}

deprecated void foobar (T) (T par)  if (is(T == S))
{
    T inst;
}

template otherPar()
{
    deprecated void otherPar(S par)
    {
        S var;
    }

    void par(S par) {}
}

template otherVar()
{
    deprecated void otherVar(S par)
    {
        S var;
    }

    void var()
    {
        S var;
    }
}

deprecated void main()
{
    foo(S.init);
    bar(S.init);
    foobar(S.init);
    otherPar(S.init);
    otherVar(S.init);
}
