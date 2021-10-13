/**
TEST_OUTPUT:
---
fail_compilation/diag_funclit.d(103): Error: function literal `__lambda1(x, y, z)` is not callable using argument types `()`
fail_compilation/diag_funclit.d(103):        missing argument for parameter #1: `x`
fail_compilation/diag_funclit.d(106): Error: function literal `__lambda2(x, y, z)` is not callable using argument types `(int, string, int, int)`
fail_compilation/diag_funclit.d(106):        too many arguments, expected `3`, got `4`
fail_compilation/diag_funclit.d(108): Error: function literal `__lambda3(x, y, string z = "Hello")` is not callable using argument types `(int, int, string, string)`
fail_compilation/diag_funclit.d(108):        too many arguments, expected `3`, got `4`
fail_compilation/diag_funclit.d(110): Error: function literal `__lambda4(x, y, string z = "Hello")` is not callable using argument types `(int)`
fail_compilation/diag_funclit.d(110):        too few arguments, expected `3`, got `1`
fail_compilation/diag_funclit.d(112): Error: function literal `__lambda5(x, y, z)` is not callable using argument types `(int)`
fail_compilation/diag_funclit.d(112):        too few arguments, expected `3`, got `1`
fail_compilation/diag_funclit.d(115): Error: function literal `__lambda6(x, y, ...)` is not callable using argument types `(int)`
fail_compilation/diag_funclit.d(115):        too few arguments, expected `2`, got `1`
fail_compilation/diag_funclit.d(117): Error: function literal `__lambda7(x, y, string z = "Hey", ...)` is not callable using argument types `(int)`
fail_compilation/diag_funclit.d(117):        too few arguments, expected `3`, got `1`
---
 */

#line 100
void main()
{
    // No argument
    (x, y, z) { return 42; }();

    // Too many args, non-variadic
    (x, y, z) { return 42; }(42, "Hello", 42, 42);
    // Too many args, non-variadic, default param
    (x, y, string z = "Hello") { return x; }(42, 42, "Nope", "Noooope");
    // Too few args, non-variadic
    (x, y, string z = "Hello") { return x; }(42);
    // Too few args, non-variadic, default param
    (x, y, z) { return x; }(42);

    // Too few args, variadic
    (x, y, ...) { return x; }(42);
    // Too few args, variadic, default param
    (x, y, string z = "Hey", ...) { return x; }(42);
}
