/*
TEST_OUTPUT:
---
fail_compilation/bug9631.d(20): Error: cannot implicitly convert expression `F()` of type `bug9631.T1!().F` to `bug9631.T2!().F`
---
*/

template T1()
{
    struct F { }
}

template T2()
{
    struct F { }
}

void main()
{
    T2!().F x = T1!().F();
}

/*
TEST_OUTPUT:
---
fail_compilation/bug9631.d(41): Error: incompatible types for `(x) == (y)`: `bug9631.S` and `bug9631.tem!().S`
---
*/

struct S { char c; }

template tem()
{
    struct S { int i; }
}

void equal()
{
    S x;
    auto y = tem!().S();
    bool b = x == y;
}

/*
TEST_OUTPUT:
---
fail_compilation/bug9631.d(55): Error: cannot cast expression `x` of type `bug9631.S` to `bug9631.tem!().S` because of different sizes
fail_compilation/bug9631.d(58): Error: cannot cast expression `ta` of type `bug9631.tem!().S[1]` to `bug9631.S[1]` because of different sizes
fail_compilation/bug9631.d(59): Error: cannot cast expression `sa` of type `S[1]` to `S[]` since sizes don't line up
---
*/
void test3()
{
    S x;
    auto y = cast(tem!().S)x;

    tem!().S[1] ta;
    S[1] sa = cast(S[1])ta;
    auto t2 = cast(tem!().S[])sa;
}

/*
TEST_OUTPUT:
---
fail_compilation/bug9631.d(79): Error: function `bug9631.arg.f(int i, S s)` is not callable using argument types `(int, S)`
fail_compilation/bug9631.d(79):        cannot pass argument `y` of type `bug9631.tem!().S` to parameter `bug9631.S s`
fail_compilation/bug9631.d(80): Error: function literal `__lambda2(S s)` is not callable using argument types `(S)`
fail_compilation/bug9631.d(80):        cannot pass argument `x` of type `bug9631.S` to parameter `bug9631.tem!().S s`
fail_compilation/bug9631.d(86): Error: constructor `bug9631.arg.A.this(S _param_0)` is not callable using argument types `(S)`
fail_compilation/bug9631.d(86):        cannot pass argument `S(0)` of type `bug9631.tem!().S` to parameter `bug9631.S _param_0`
---
*/
void arg()
{
    S x;
    tem!().S y;

    void f(int i, S s);
    f(4, y);
    (tem!().S s){}(x);

    struct A
    {
        this(S){}
    }
    A(tem!().S());
}

/*
TEST_OUTPUT:
---
fail_compilation/bug9631.d(106): Error: function `bug9631.targ.ft!().ft(S _param_0)` is not callable using argument types `(S)`
fail_compilation/bug9631.d(106):        cannot pass argument `x` of type `bug9631.S` to parameter `bug9631.tem!().S _param_0`
fail_compilation/bug9631.d(107): Error: template `bug9631.targ.ft` cannot deduce function from argument types `!()(S)`, candidates are:
fail_compilation/bug9631.d(105):        `ft()(tem!().S)`
fail_compilation/bug9631.d(109): Error: template `bug9631.targ.ft2` cannot deduce function from argument types `!()(S, int)`, candidates are:
fail_compilation/bug9631.d(108):        `ft2(T)(S, T)`
---
*/
void targ()
{
    S x;
    tem!().S y;

    void ft()(tem!().S){}
    ft!()(x);
    ft(x);
    void ft2(T)(S, T){}
    ft2(y, 1);
}

