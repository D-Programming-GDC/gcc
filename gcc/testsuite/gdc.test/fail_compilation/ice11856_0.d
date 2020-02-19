/*
TEST_OUTPUT:
---
fail_compilation/ice11856_0.d(19): Error: template `ice11856_0.f` cannot deduce function from argument types `!()(int)`, candidates are:
fail_compilation/ice11856_0.d(13):        `f(T)(T t)`
fail_compilation/ice11856_0.d(16):        `f(T)(T t)`
  with `T = int`
  must satisfy the following constraint:
`       !__traits(compiles, .f!T)`
---
*/

int f(T)(T t) if(!__traits(compiles,.f!T)) {
    return 0;
}
int f(T)(T t) if(!__traits(compiles,.f!T)) {
    return 1;
}
enum x=f(2);
