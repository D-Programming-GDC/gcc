//
// { dg-do compile }
// { dg-options "-frelease" }
// ICE in array_bounds_check with module-level AA literal and -frelease.
string[string] aarr = ["name": "John", "family": "Doe"];
void main() {}
