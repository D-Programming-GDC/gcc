// PERMUTE_ARGS: -inline -g -debug -unittest
/*
TEST_OUTPUT:
---
hit!
---
*/

import imports.std15021conv;

class AliasDecl {}

void aliasDecl(AliasDecl ad)
{
    AliasDecl* zis;

    static if (is(typeof(to!string(*zis))))
    {
        pragma(msg, "hit!");
        to!string(*zis);
    }
}

void main() {}
