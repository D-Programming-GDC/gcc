/*
DISABLED: win32 win64 osx linux freebsd dragonflybsd
https://issues.dlang.org/show_bug.cgi?id=18385
Disabled for 2.079, s.t. a deprecation cycle can be started with 2.080
TEST_OUTPUT:
---
fail_compilation/fail2789.d(15): Error: function `fail2789.A2789.m()` conflicts with previous declaration at fail_compilation/fail2789.d(10)
fail_compilation/fail2789.d(25): Error: function `fail2789.A2789.m()` conflicts with previous declaration at fail_compilation/fail2789.d(10)
---
*/
class A2789
{
    int m()
    {
        return 1;
    }

    float m()       // conflict
    {
        return 2.0;
    }

    float m() const // doen't conflict
    {
        return 3.0;
    }

    static void m() // conflict
    {
    }
}

/*
TEST_OUTPUT:
---
fail_compilation/fail2789.d(46): Error: function `fail2789.f3()` conflicts with previous declaration at fail_compilation/fail2789.d(45)
fail_compilation/fail2789.d(49): Error: function `fail2789.f4()` conflicts with previous declaration at fail_compilation/fail2789.d(48)
fail_compilation/fail2789.d(52): Error: function `fail2789.f5()` conflicts with previous declaration at fail_compilation/fail2789.d(51)
fail_compilation/fail2789.d(55): Error: function `fail2789.f6()` conflicts with previous declaration at fail_compilation/fail2789.d(54)
---
*/
void f1();
void f1() {}    // ok

void f2() {}
void f2();      // ok

void f3();
void f3();      // ok

void f4() {}
void f4() {}    // conflict

void f5() @safe {}
void f5() @system {}    // conflict

auto f6() { return 10; }    // int()
auto f6() { return ""; }    // string(), conflict

/*
TEST_OUTPUT:
---
fail_compilation/fail2789.d(67): Error: function `fail2789.f_ExternC1()` cannot be overloaded with another `extern(C)` function at fail_compilation/fail2789.d(66)
fail_compilation/fail2789.d(70): Error: function `fail2789.f_ExternC2(int)` cannot be overloaded with another `extern(C)` function at fail_compilation/fail2789.d(69)
fail_compilation/fail2789.d(73): Error: function `fail2789.f_ExternC3()` cannot be overloaded with another `extern(C)` function at fail_compilation/fail2789.d(72)
fail_compilation/fail2789.d(76): Error: function `fail2789.f_MixExtern1()` conflicts with previous declaration at fail_compilation/fail2789.d(75)
---
*/
extern(C) void f_ExternC1() {}
extern(C) void f_ExternC1() {}      // conflict

extern(C) void f_ExternC2() {}
extern(C) void f_ExternC2(int) {}   // conflict

extern(C) void f_ExternC3(int) {}
extern(C) void f_ExternC3() {}      // conflict

extern (D) void f_MixExtern1() {}
extern (C) void f_MixExtern1() {}   // conflict

extern (D) void f_MixExtern2(int) {}
extern (C) void f_MixExtern2() {}   // no error

extern (C) void f_ExternC4(int sig);
extern (C) void f_ExternC4(int sig) @nogc;      // no error

extern (C) void f_ExternC5(int sig) {}
extern (C) void f_ExternC5(int sig) @nogc;      // no error

extern (C) void f_ExternC6(int sig);
extern (C) void f_ExternC6(int sig) @nogc {}    // no error

/*
TEST_OUTPUT:
---
fail_compilation/fail2789.d(103): Error: function `fail2789.mul14147(const(int[]) left, const(int[]) right)` conflicts with previous declaration at fail_compilation/fail2789.d(99)
---
*/
struct S14147(alias func)
{
}
pure auto mul14147(const int[] left, const int[] right)
{
    S14147!(a => a) s;
}
pure auto mul14147(const int[] left, const int[] right)
{
    S14147!(a => a) s;
}
