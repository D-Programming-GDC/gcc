// { dg-do compile }
// Contributed by Gabriel Dos Reis <gdr at integrable-solutions dot net>
// PR c++/2204: Check for parameters of abstract type in function declarations.

namespace N1 {
  struct X;

  struct X {  // { dg-message "note" }
    virtual void xfunc(void) = 0;  // { dg-message "note" }
  };

  struct Y1 {
    void g(X parm1) {}         // { dg-error "abstract" }
    void g(X parm2[2]) {}
    void g(X (*parm3)[2]) {}
  };

  template <int N>
  struct Y2 {
    void g(X parm4) {}         // { dg-error "abstract" }
    void g(X parm5[2]) {}
    void g(X (*parm6)[2]) {}
  };

  template struct Y2<42>;
}

namespace N2 {
  struct X1 { // { dg-message "note" }
    virtual void xfunc(void) = 0;  // { dg-message "note" }
    void g(X1 parm7) {}        // { dg-error "abstract" }
    void g(X1 parm8[2]) {}
    void g(X1 (*parm9)[2]) {}
  };

  template <int N>
  struct X2 { // { dg-message "note" }
    virtual void xfunc(void) = 0; // { dg-message "note" }
    void g(X2 parm10) {}        // { dg-error "abstract" }
    void g(X2 parm11[2]) {}
    void g(X2 (*parm12)[2]) {}
  };

  template struct X2<42>;
}

namespace N3 {
  struct X { // { dg-message "note" }
    virtual void xfunc(void) = 0;  // { dg-message "note" }
  };
  void g(X parm13) {}          // { dg-error "abstract" }
  void g(X parm14[2]) {}
  void g(X (*parm15)[2]) {}

  template <int N>
  void g(X parm16) {}          // { dg-error "abstract" }
  template <int N>
  void g(X parm17[2]) {}
  template <int N>
  void g(X (*parm18)[2]) {}

  template void g<42>(X);
}
