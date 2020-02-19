/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 *              Copyright (C) 2018-2019 by The D Language Foundation, All Rights Reserved
 * Authors:     Iain Buclaw
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/iasmgcc.d, _iasmgcc.d)
 * Documentation:  https://dlang.org/phobos/dmd_iasmgcc.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/iasmgcc.d
 */

/* Inline assembler for the GCC D compiler.
 */

module dmd.iasmgcc;

import core.stdc.string;

import dmd.arraytypes;
import dmd.astcodegen;
import dmd.dscope;
import dmd.errors;
import dmd.expression;
import dmd.expressionsem;
import dmd.identifier;
import dmd.globals;
import dmd.parse;
import dmd.tokens;
import dmd.statement;
import dmd.statementsem;

private:

/***********************************
 * Parse list of extended asm input or output operands.
 * Grammar:
 *      | Operands:
 *      |     SymbolicName(opt) StringLiteral AssignExpression
 *      |     SymbolicName(opt) StringLiteral AssignExpression , Operands
 *      |
 *      | SymbolicName:
 *      |     [ Identifier ]
 * Params:
 *      p = parser state
 *      s = asm statement to parse
 * Returns:
 *      number of operands added to the gcc asm statement
 */
int parseExtAsmOperands(Parser)(Parser p, GccAsmStatement s)
{
    int numargs = 0;

    while (1)
    {
        Expression arg;
        Identifier name;
        Expression constraint;

        switch (p.token.value)
        {
            case TOK.semicolon:
            case TOK.colon:
            case TOK.endOfFile:
                return numargs;

            case TOK.leftBracket:
                if (p.peekNext() == TOK.identifier)
                {
                    p.nextToken();
                    name = p.token.ident;
                    p.nextToken();
                }
                else
                {
                    p.error(s.loc, "expected identifier after `[`");
                    goto Lerror;
                }
                p.check(TOK.rightBracket);
                goto case;

            case TOK.string_:
                constraint = p.parsePrimaryExp();
                arg = p.parseAssignExp();

                if (!s.args)
                {
                    s.names = new Identifiers();
                    s.constraints = new Expressions();
                    s.args = new Expressions();
                }
                s.names.push(name);
                s.args.push(arg);
                s.constraints.push(constraint);
                numargs++;

                if (p.token.value == TOK.comma)
                    p.nextToken();
                break;

            default:
                p.error("expected constant string constraint for operand, not `%s`",
                        p.token.toChars());
                goto Lerror;
        }
    }
Lerror:
    while (p.token.value != TOK.rightCurly &&
           p.token.value != TOK.semicolon &&
           p.token.value != TOK.endOfFile)
        p.nextToken();

    return numargs;
}

/***********************************
 * Parse list of extended asm clobbers.
 * Grammar:
 *      | Clobbers:
 *      |     StringLiteral
 *      |     StringLiteral , Clobbers
 * Params:
 *      p = parser state
 * Returns:
 *      array of parsed clobber expressions
 */
Expressions *parseExtAsmClobbers(Parser)(Parser p)
{
    Expressions *clobbers;

    while (1)
    {
        Expression clobber;

        switch (p.token.value)
        {
            case TOK.semicolon:
            case TOK.colon:
            case TOK.endOfFile:
                return clobbers;

            case TOK.string_:
                clobber = p.parsePrimaryExp();
                if (!clobbers)
                    clobbers = new Expressions();
                clobbers.push(clobber);

                if (p.token.value == TOK.comma)
                    p.nextToken();
                break;

            default:
                p.error("expected constant string constraint for clobber name, not `%s`",
                        p.token.toChars());
                goto Lerror;
        }
    }
Lerror:
    while (p.token.value != TOK.rightCurly &&
           p.token.value != TOK.semicolon &&
           p.token.value != TOK.endOfFile)
        p.nextToken();

    return clobbers;
}

/***********************************
 * Parse list of extended asm goto labels.
 * Grammar:
 *      | GotoLabels:
 *      |     Identifier
 *      |     Identifier , GotoLabels
 * Params:
 *      p = parser state
 * Returns:
 *      array of parsed goto labels
 */
Identifiers *parseExtAsmGotoLabels(Parser)(Parser p)
{
    Identifiers *labels;

    while (1)
    {
        switch (p.token.value)
        {
            case TOK.semicolon:
            case TOK.endOfFile:
                return labels;

            case TOK.identifier:
                if (!labels)
                    labels = new Identifiers();
                labels.push(p.token.ident);

                if (p.nextToken() == TOK.comma)
                    p.nextToken();
                break;

            default:
                p.error("expected identifier for goto label name, not `%s`",
                        p.token.toChars());
                goto Lerror;
        }
    }
Lerror:
    while (p.token.value != TOK.rightCurly &&
           p.token.value != TOK.semicolon &&
           p.token.value != TOK.endOfFile)
        p.nextToken();

    return labels;
}

/***********************************
 * Parse a gcc asm statement.
 * There are three forms of inline asm statements, basic, extended, and goto.
 * Grammar:
 *      | AsmInstruction:
 *      |     BasicAsmInstruction
 *      |     ExtAsmInstruction
 *      |     GotoAsmInstruction
 *      |
 *      | BasicAsmInstruction:
 *      |     Expression
 *      |
 *      | ExtAsmInstruction:
 *      |     Expression : Operands(opt) : Operands(opt) : Clobbers(opt)
 *      |
 *      | GotoAsmInstruction:
 *      |     Expression : : Operands(opt) : Clobbers(opt) : GotoLabels(opt)
 * Params:
 *      p = parser state
 *      s = asm statement to parse
 * Returns:
 *      the parsed gcc asm statement
 */
GccAsmStatement parseGccAsm(Parser)(Parser p, GccAsmStatement s)
{
    s.insn = p.parseExpression();
    if (p.token.value == TOK.semicolon || p.token.value == TOK.endOfFile)
        goto Ldone;

    // No semicolon followed after instruction template, treat as extended asm.
    foreach (section; 0 .. 4)
    {
        p.check(TOK.colon);

        final switch (section)
        {
            case 0:
                s.outputargs = p.parseExtAsmOperands(s);
                break;

            case 1:
                p.parseExtAsmOperands(s);
                break;

            case 2:
                s.clobbers = p.parseExtAsmClobbers();
                break;

            case 3:
                s.labels = p.parseExtAsmGotoLabels();
                break;
        }

        if (p.token.value == TOK.semicolon || p.token.value == TOK.endOfFile)
            goto Ldone;
    }
Ldone:
    p.check(TOK.semicolon);

    return s;
}

/***********************************
 * Parse and run semantic analysis on a GccAsmStatement.
 * Params:
 *      s  = gcc asm statement being parsed
 *      sc = the scope where the asm statement is located
 * Returns:
 *      the completed gcc asm statement, or null if errors occurred
 */
public Statement gccAsmSemantic(GccAsmStatement s, Scope *sc)
{
    //printf("GccAsmStatement.semantic()\n");
    scope diagnosticReporter = new StderrDiagnosticReporter(global.params.useDeprecated);
    scope p = new Parser!ASTCodegen(sc._module, ";", false, diagnosticReporter);

    // Make a safe copy of the token list before parsing.
    Token *toklist = null;
    Token **ptoklist = &toklist;

    for (Token *token = s.tokens; token; token = token.next)
    {
        *ptoklist = p.allocateToken();
        memcpy(*ptoklist, token, Token.sizeof);
        ptoklist = &(*ptoklist).next;
        *ptoklist = null;
    }
    p.token = *toklist;
    p.scanloc = s.loc;

    // Parse the gcc asm statement.
    s = p.parseGccAsm(s);
    if (p.errors)
        return null;
    s.stc = sc.stc;

    // Fold the instruction template string.
    s.insn = semanticString(sc, s.insn, "asm instruction template");

    if (s.labels && s.outputargs)
        s.error("extended asm statements with labels cannot have output constraints");

    // Analyse all input and output operands.
    if (s.args)
    {
        foreach (i; 0 .. s.args.dim)
        {
            Expression e = (*s.args)[i];
            e = e.expressionSemantic(sc);
            // Check argument is a valid lvalue/rvalue.
            if (i < s.outputargs)
                e = e.modifiableLvalue(sc, null);
            else if (e.checkValue())
                e = new ErrorExp();
            (*s.args)[i] = e;

            e = (*s.constraints)[i];
            e = e.expressionSemantic(sc);
            assert(e.op == TOK.string_ && (cast(StringExp) e).sz == 1);
            (*s.constraints)[i] = e;
        }
    }

    // Analyse all clobbers.
    if (s.clobbers)
    {
        foreach (i; 0 .. s.clobbers.dim)
        {
            Expression e = (*s.clobbers)[i];
            e = e.expressionSemantic(sc);
            assert(e.op == TOK.string_ && (cast(StringExp) e).sz == 1);
            (*s.clobbers)[i] = e;
        }
    }

    // Analyse all goto labels.
    if (s.labels)
    {
        foreach (i; 0 .. s.labels.dim)
        {
            Identifier ident = (*s.labels)[i];
            GotoStatement gs = new GotoStatement(s.loc, ident);
            if (!s.gotos)
                s.gotos = new GotoStatements();
            s.gotos.push(gs);
            gs.statementSemantic(sc);
        }
    }

    return s;
}

unittest
{
    uint errors = global.startGagging();

    // Immitates asmSemantic if version = IN_GCC.
    static int semanticAsm(Token* tokens)
    {
        scope gas = new GccAsmStatement(Loc.initial, tokens);
        scope diagnosticReporter = new StderrDiagnosticReporter(global.params.useDeprecated);
        scope p = new Parser!ASTCodegen(null, ";", false, diagnosticReporter);
        p.token = *tokens;
        p.parseGccAsm(gas);
        return p.errors;
    }

    // Immitates parseStatement for asm statements.
    static void parseAsm(string input, bool expectError)
    {
        // Generate tokens from input test.
        scope diagnosticReporter = new StderrDiagnosticReporter(global.params.useDeprecated);
        scope p = new Parser!ASTCodegen(null, input, false, diagnosticReporter);
        p.nextToken();

        Token* toklist = null;
        Token** ptoklist = &toklist;
        p.check(TOK.asm_);
        p.check(TOK.leftCurly);
        while (1)
        {
            if (p.token.value == TOK.rightCurly || p.token.value == TOK.endOfFile)
                break;
            *ptoklist = p.allocateToken();
            memcpy(*ptoklist, &p.token, Token.sizeof);
            ptoklist = &(*ptoklist).next;
            *ptoklist = null;
            p.nextToken();
        }
        p.check(TOK.rightCurly);

        auto res = semanticAsm(toklist);
        assert(res == 0 || expectError);
    }

    /// Assembly Tests, all should pass.
    /// Note: Frontend is not initialized, use only strings and identifiers.
    immutable string[] passAsmTests = [
        // Basic asm statement
        q{ asm { "nop";
        } },

        // Extended asm statement
        q{ asm { "cpuid"
               : "=a" (a), "=b" (b), "=c" (c), "=d" (d)
               : "a" input;
        } },

        // Assembly with symbolic names
        q{ asm { "bts %[base], %[offset]"
               : [base] "+rm" *ptr,
               : [offset] "Ir" bitnum;
        } },

        // Assembly with clobbers
        q{ asm { "cpuid"
               : "=a" a
               : "a" input
               : "ebx", "ecx", "edx";
        } },

        // Goto asm statement
        q{ asm { "jmp %l0"
               :
               :
               :
               : Ljmplabel;
        } },

        // Any CTFE-able string allowed as instruction template.
        q{ asm { generateAsm();
        } },

        // Likewise mixins, permissible so long as the result is a string.
        q{ asm { mixin(`"repne"`, `~ "scasb"`);
        } },
    ];

    immutable string[] failAsmTests = [
        // Found 'h' when expecting ';'
        q{ asm { ""h;
        } },

        /+ Need a way to test without depending on Type._init()
        // Expression expected, not ';'
        q{ asm { ""[;
        } },

        // Expression expected, not ':'
        q{ asm { ""
               :
               : "g" a ? b : : c;
        } },
        +/
    ];

    foreach (test; passAsmTests)
        parseAsm(test, false);

    foreach (test; failAsmTests)
        parseAsm(test, true);

    global.endGagging(errors);
}
