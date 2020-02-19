
/* Compiler implementation of the D programming language
 * Copyright (C) 1999-2019 by The D Language Foundation, All Rights Reserved
 * written by Walter Bright
 * http://www.digitalmars.com
 * Distributed under the Boost Software License, Version 1.0.
 * http://www.boost.org/LICENSE_1_0.txt
 * https://github.com/dlang/dmd/blob/master/src/dmd/statement.h
 */

#pragma once

#include "arraytypes.h"
#include "ast_node.h"
#include "dsymbol.h"
#include "visitor.h"
#include "tokens.h"

struct Scope;
class Expression;
class LabelDsymbol;
class Identifier;
class IfStatement;
class ExpStatement;
class DefaultStatement;
class VarDeclaration;
class Condition;
class ErrorStatement;
class ReturnStatement;
class CompoundStatement;
class Parameter;
class StaticAssert;
class AsmStatement;
class GotoStatement;
class ScopeStatement;
class TryCatchStatement;
class TryFinallyStatement;
class CaseStatement;
class DefaultStatement;
class LabelStatement;
class StaticForeach;

// Back end
struct code;

bool inferAggregate(ForeachStatement *fes, Scope *sc, Dsymbol *&sapply);
bool inferApplyArgTypes(ForeachStatement *fes, Scope *sc, Dsymbol *&sapply);

/* How a statement exits; this is returned by blockExit()
 */
enum BE
{
    BEnone =     0,
    BEfallthru = 1,
    BEthrow =    2,
    BEreturn =   4,
    BEgoto =     8,
    BEhalt =     0x10,
    BEbreak =    0x20,
    BEcontinue = 0x40,
    BEerrthrow = 0x80,
    BEany = (BEfallthru | BEthrow | BEreturn | BEgoto | BEhalt)
};

class Statement : public ASTNode
{
public:
    Loc loc;

    virtual Statement *syntaxCopy();

    const char *toChars();

    void error(const char *format, ...);
    void warning(const char *format, ...);
    void deprecation(const char *format, ...);
    virtual Statement *getRelatedLabeled() { return this; }
    virtual bool hasBreak() const;
    virtual bool hasContinue() const;
    bool usesEH();
    bool comeFrom();
    bool hasCode();
    virtual Statement *scopeCode(Scope *sc, Statement **sentry, Statement **sexit, Statement **sfinally);
    virtual Statements *flatten(Scope *sc);
    virtual Statement *last();

    // Avoid dynamic_cast
    virtual ErrorStatement *isErrorStatement() { return NULL; }
    virtual ScopeStatement *isScopeStatement() { return NULL; }
    virtual ExpStatement *isExpStatement() { return NULL; }
    virtual CompoundStatement *isCompoundStatement() { return NULL; }
    virtual ReturnStatement *isReturnStatement() { return NULL; }
    virtual IfStatement *isIfStatement() { return NULL; }
    virtual CaseStatement *isCaseStatement() { return NULL; }
    virtual DefaultStatement *isDefaultStatement() { return NULL; }
    virtual LabelStatement *isLabelStatement() { return NULL; }
    virtual GotoDefaultStatement *isGotoDefaultStatement() { return NULL; }
    virtual GotoCaseStatement *isGotoCaseStatement() { return NULL; }
    virtual BreakStatement *isBreakStatement() { return NULL; }
    virtual DtorExpStatement *isDtorExpStatement() { return NULL; }
    virtual ForwardingStatement *isForwardingStatement() { return NULL; }
    void accept(Visitor *v) { v->visit(this); }
};

/** Any Statement that fails semantic() or has a component that is an ErrorExp or
 * a TypeError should return an ErrorStatement from semantic().
 */
class ErrorStatement : public Statement
{
public:
    Statement *syntaxCopy();

    ErrorStatement *isErrorStatement() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

class PeelStatement : public Statement
{
public:
    Statement *s;

    void accept(Visitor *v) { v->visit(this); }
};

class ExpStatement : public Statement
{
public:
    Expression *exp;

    static ExpStatement *create(Loc loc, Expression *exp);
    Statement *syntaxCopy();
    Statement *scopeCode(Scope *sc, Statement **sentry, Statement **sexit, Statement **sfinally);
    Statements *flatten(Scope *sc);

    ExpStatement *isExpStatement() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

class DtorExpStatement : public ExpStatement
{
public:
    /* Wraps an expression that is the destruction of 'var'
     */

    VarDeclaration *var;

    Statement *syntaxCopy();
    void accept(Visitor *v) { v->visit(this); }

    DtorExpStatement *isDtorExpStatement() { return this; }
};

class CompileStatement : public Statement
{
public:
    Expressions *exps;

    Statement *syntaxCopy();
    Statements *flatten(Scope *sc);
    void accept(Visitor *v) { v->visit(this); }
};

class CompoundStatement : public Statement
{
public:
    Statements *statements;

    static CompoundStatement *create(Loc loc, Statement *s1, Statement *s2);
    Statement *syntaxCopy();
    Statements *flatten(Scope *sc);
    ReturnStatement *isReturnStatement();
    Statement *last();

    CompoundStatement *isCompoundStatement() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

class CompoundDeclarationStatement : public CompoundStatement
{
public:
    Statement *syntaxCopy();
    void accept(Visitor *v) { v->visit(this); }
};

/* The purpose of this is so that continue will go to the next
 * of the statements, and break will go to the end of the statements.
 */
class UnrolledLoopStatement : public Statement
{
public:
    Statements *statements;

    Statement *syntaxCopy();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class ScopeStatement : public Statement
{
public:
    Statement *statement;
    Loc endloc;                 // location of closing curly bracket

    Statement *syntaxCopy();
    ScopeStatement *isScopeStatement() { return this; }
    ReturnStatement *isReturnStatement();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class ForwardingStatement : public Statement
{
    ForwardingScopeDsymbol *sym;
    Statement *statement;

    Statement *syntaxCopy();
    Statements *flatten(Scope *sc);
    ForwardingStatement *isForwardingStatement() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

class WhileStatement : public Statement
{
public:
    Expression *condition;
    Statement *_body;
    Loc endloc;                 // location of closing curly bracket

    Statement *syntaxCopy();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class DoStatement : public Statement
{
public:
    Statement *_body;
    Expression *condition;
    Loc endloc;                 // location of ';' after while

    Statement *syntaxCopy();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class ForStatement : public Statement
{
public:
    Statement *_init;
    Expression *condition;
    Expression *increment;
    Statement *_body;
    Loc endloc;                 // location of closing curly bracket

    // When wrapped in try/finally clauses, this points to the outermost one,
    // which may have an associated label. Internal break/continue statements
    // treat that label as referring to this loop.
    Statement *relatedLabeled;

    Statement *syntaxCopy();
    Statement *scopeCode(Scope *sc, Statement **sentry, Statement **sexit, Statement **sfinally);
    Statement *getRelatedLabeled() { return relatedLabeled ? relatedLabeled : this; }
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class ForeachStatement : public Statement
{
public:
    TOK op;                     // TOKforeach or TOKforeach_reverse
    Parameters *parameters;     // array of Parameter*'s
    Expression *aggr;
    Statement *_body;
    Loc endloc;                 // location of closing curly bracket

    VarDeclaration *key;
    VarDeclaration *value;

    FuncDeclaration *func;      // function we're lexically in

    Statements *cases;          // put breaks, continues, gotos and returns here
    ScopeStatements *gotos;     // forward referenced goto's go here

    Statement *syntaxCopy();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class ForeachRangeStatement : public Statement
{
public:
    TOK op;                     // TOKforeach or TOKforeach_reverse
    Parameter *prm;             // loop index variable
    Expression *lwr;
    Expression *upr;
    Statement *_body;
    Loc endloc;                 // location of closing curly bracket

    VarDeclaration *key;

    Statement *syntaxCopy();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class IfStatement : public Statement
{
public:
    Parameter *prm;
    Expression *condition;
    Statement *ifbody;
    Statement *elsebody;
    VarDeclaration *match;      // for MatchExpression results
    Loc endloc;                 // location of closing curly bracket

    Statement *syntaxCopy();
    IfStatement *isIfStatement() { return this; }

    void accept(Visitor *v) { v->visit(this); }
};

class ConditionalStatement : public Statement
{
public:
    Condition *condition;
    Statement *ifbody;
    Statement *elsebody;

    Statement *syntaxCopy();
    Statements *flatten(Scope *sc);

    void accept(Visitor *v) { v->visit(this); }
};

class StaticForeachStatement : public Statement
{
public:
    StaticForeach *sfe;

    Statement *syntaxCopy();
    Statements *flatten(Scope *sc);

    void accept(Visitor *v) { v->visit(this); }
};

class PragmaStatement : public Statement
{
public:
    Identifier *ident;
    Expressions *args;          // array of Expression's
    Statement *_body;

    Statement *syntaxCopy();

    void accept(Visitor *v) { v->visit(this); }
};

class StaticAssertStatement : public Statement
{
public:
    StaticAssert *sa;

    Statement *syntaxCopy();

    void accept(Visitor *v) { v->visit(this); }
};

class SwitchStatement : public Statement
{
public:
    Expression *condition;
    Statement *_body;
    bool isFinal;

    DefaultStatement *sdefault;
    TryFinallyStatement *tf;
    GotoCaseStatements gotoCases;  // array of unresolved GotoCaseStatement's
    CaseStatements *cases;         // array of CaseStatement's
    int hasNoDefault;           // !=0 if no default statement
    int hasVars;                // !=0 if has variable case values
    VarDeclaration *lastVar;

    Statement *syntaxCopy();
    bool hasBreak() const;

    void accept(Visitor *v) { v->visit(this); }
};

class CaseStatement : public Statement
{
public:
    Expression *exp;
    Statement *statement;

    int index;          // which case it is (since we sort this)
    VarDeclaration *lastVar;

    Statement *syntaxCopy();
    CaseStatement *isCaseStatement() { return this; }

    void accept(Visitor *v) { v->visit(this); }
};


class CaseRangeStatement : public Statement
{
public:
    Expression *first;
    Expression *last;
    Statement *statement;

    Statement *syntaxCopy();
    void accept(Visitor *v) { v->visit(this); }
};


class DefaultStatement : public Statement
{
public:
    Statement *statement;
    VarDeclaration *lastVar;

    Statement *syntaxCopy();
    DefaultStatement *isDefaultStatement() { return this; }

    void accept(Visitor *v) { v->visit(this); }
};

class GotoDefaultStatement : public Statement
{
public:
    SwitchStatement *sw;

    Statement *syntaxCopy();
    GotoDefaultStatement *isGotoDefaultStatement() { return this; }

    void accept(Visitor *v) { v->visit(this); }
};

class GotoCaseStatement : public Statement
{
public:
    Expression *exp;            // NULL, or which case to goto
    CaseStatement *cs;          // case statement it resolves to

    Statement *syntaxCopy();
    GotoCaseStatement *isGotoCaseStatement() { return this; }

    void accept(Visitor *v) { v->visit(this); }
};

class SwitchErrorStatement : public Statement
{
public:
    Expression *exp;

    void accept(Visitor *v) { v->visit(this); }
};

class ReturnStatement : public Statement
{
public:
    Expression *exp;
    size_t caseDim;

    Statement *syntaxCopy();

    ReturnStatement *isReturnStatement() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

class BreakStatement : public Statement
{
public:
    Identifier *ident;

    Statement *syntaxCopy();

    BreakStatement *isBreakStatement() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

class ContinueStatement : public Statement
{
public:
    Identifier *ident;

    Statement *syntaxCopy();

    void accept(Visitor *v) { v->visit(this); }
};

class SynchronizedStatement : public Statement
{
public:
    Expression *exp;
    Statement *_body;

    Statement *syntaxCopy();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class WithStatement : public Statement
{
public:
    Expression *exp;
    Statement *_body;
    VarDeclaration *wthis;
    Loc endloc;

    Statement *syntaxCopy();

    void accept(Visitor *v) { v->visit(this); }
};

class TryCatchStatement : public Statement
{
public:
    Statement *_body;
    Catches *catches;

    Statement *syntaxCopy();
    bool hasBreak() const;

    void accept(Visitor *v) { v->visit(this); }
};

class Catch : public RootObject
{
public:
    Loc loc;
    Type *type;
    Identifier *ident;
    Statement *handler;

    VarDeclaration *var;
    // set if semantic processing errors
    bool errors;

    // was generated by the compiler,
    // wasn't present in source code
    bool internalCatch;

    Catch *syntaxCopy();
};

class TryFinallyStatement : public Statement
{
public:
    Statement *_body;
    Statement *finalbody;

    bool bodyFallsThru;         // true if _body falls through to finally

    static TryFinallyStatement *create(Loc loc, Statement *body, Statement *finalbody);
    Statement *syntaxCopy();
    bool hasBreak() const;
    bool hasContinue() const;

    void accept(Visitor *v) { v->visit(this); }
};

class ScopeGuardStatement : public Statement
{
public:
    TOK tok;
    Statement *statement;

    Statement *syntaxCopy();
    Statement *scopeCode(Scope *sc, Statement **sentry, Statement **sexit, Statement **sfinally);

    void accept(Visitor *v) { v->visit(this); }
};

class ThrowStatement : public Statement
{
public:
    Expression *exp;
    // was generated by the compiler,
    // wasn't present in source code
    bool internalThrow;

    Statement *syntaxCopy();

    void accept(Visitor *v) { v->visit(this); }
};

class DebugStatement : public Statement
{
public:
    Statement *statement;

    Statement *syntaxCopy();
    Statements *flatten(Scope *sc);
    void accept(Visitor *v) { v->visit(this); }
};

class GotoStatement : public Statement
{
public:
    Identifier *ident;
    LabelDsymbol *label;
    TryFinallyStatement *tf;
    ScopeGuardStatement *os;
    VarDeclaration *lastVar;

    Statement *syntaxCopy();

    void accept(Visitor *v) { v->visit(this); }
};

class LabelStatement : public Statement
{
public:
    Identifier *ident;
    Statement *statement;
    TryFinallyStatement *tf;
    ScopeGuardStatement *os;
    VarDeclaration *lastVar;
    Statement *gotoTarget;      // interpret

    bool breaks;                // someone did a 'break ident'

    Statement *syntaxCopy();
    Statements *flatten(Scope *sc);
    Statement *scopeCode(Scope *sc, Statement **sentry, Statement **sexit, Statement **sfinally);

    LabelStatement *isLabelStatement() { return this; }

    void accept(Visitor *v) { v->visit(this); }
};

class LabelDsymbol : public Dsymbol
{
public:
    LabelStatement *statement;

    static LabelDsymbol *create(Identifier *ident);
    LabelDsymbol *isLabel();
    void accept(Visitor *v) { v->visit(this); }
};

Statement* asmSemantic(AsmStatement *s, Scope *sc);

class AsmStatement : public Statement
{
public:
    Token *tokens;

    Statement *syntaxCopy();
    void accept(Visitor *v) { v->visit(this); }
};

class InlineAsmStatement : public AsmStatement
{
public:
    code *asmcode;
    unsigned asmalign;          // alignment of this statement
    unsigned regs;              // mask of registers modified (must match regm_t in back end)
    bool refparam;              // true if function parameter is referenced
    bool naked;                 // true if function is to be naked

    Statement *syntaxCopy();
    void accept(Visitor *v) { v->visit(this); }
};

// A GCC asm statement - assembler instructions with D expression operands
class GccAsmStatement : public AsmStatement
{
public:
    StorageClass stc;           // attributes of the asm {} block
    Expression *insn;           // string expression that is the template for assembler code
    Expressions *args;          // input and output operands of the statement
    unsigned outputargs;        // of the operands in 'args', the number of output operands
    Identifiers *names;         // list of symbolic names for the operands
    Expressions *constraints;   // list of string constants specifying constraints on operands
    Expressions *clobbers;      // list of string constants specifying clobbers and scratch registers
    Identifiers *labels;        // list of goto labels
    GotoStatements *gotos;      // of the goto labels, the equivalent statements they represent

    Statement *syntaxCopy();
    void accept(Visitor *v) { v->visit(this); }
};

// a complete asm {} block
class CompoundAsmStatement : public CompoundStatement
{
public:
    StorageClass stc; // postfix attributes like nothrow/pure/@trusted

    CompoundAsmStatement *syntaxCopy();
    Statements *flatten(Scope *sc);

    void accept(Visitor *v) { v->visit(this); }
};

class ImportStatement : public Statement
{
public:
    Dsymbols *imports;          // Array of Import's

    Statement *syntaxCopy();

    void accept(Visitor *v) { v->visit(this); }
};
