/* TEST_OUTPUT:
---
fail_compilation/test19971.d(15): Error: function `test19971.f(int x)` is not callable using argument types `(string)`
fail_compilation/test19971.d(15):        cannot pass argument `"%s"` of type `string` to parameter `int x`
fail_compilation/test19971.d(16): Error: function literal `__lambda1(int x)` is not callable using argument types `(string)`
fail_compilation/test19971.d(16):        cannot pass argument `"%s"` of type `string` to parameter `int x`
---
*/

// https://issues.dlang.org/show_bug.cgi?id=19971

void f(int x) {}
void main()
{
    f("%s");
    (int x) {} ("%s");
}
