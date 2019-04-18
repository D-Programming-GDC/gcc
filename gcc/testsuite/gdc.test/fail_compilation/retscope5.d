/*
REQUIRED_ARGS: -dip1000
PERMUTE_ARGS:
*/

/*
TEST_OUTPUT:
---
fail_compilation/retscope5.d(5010): Error: reference `t` assigned to `p` with longer lifetime
---
*/

#line 5000

// https://issues.dlang.org/show_bug.cgi?id=17725

void test() @safe
{
    int* p;
    struct T {
            int a;
    }
    void escape(ref T t) @safe {
            p = &t.a; // should not compile
    }
}

