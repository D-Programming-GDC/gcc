// REQUIRED_ARGS: -w
// https://issues.dlang.org/show_bug.cgi?id=4375: Dangling else

version (A)
    version (B)
        struct G3 {}
else
    struct G4 {}

