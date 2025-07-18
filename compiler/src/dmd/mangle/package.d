/**
 * Does name mangling for `extern(D)` symbols.
 *
 * Specification: $(LINK2 https://dlang.org/spec/abi.html#name_mangling, Name Mangling)
 *
 * Copyright: Copyright (C) 1999-2025 by The D Language Foundation, All Rights Reserved
 * Authors: Walter Bright, https://www.digitalmars.com
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/mangle/package.d, _dmangle.d)
 * Documentation:  https://dlang.org/phobos/dmd_dmangle.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/mangle/package.d
 * References:  https://dlang.org/blog/2017/12/20/ds-newfangled-name-mangling/
 */

module dmd.mangle;


/******************************************************************************
 * Returns exact mangled name of function.
 */
const(char)* mangleExact(FuncDeclaration fd)
{
    //printf("mangleExact()\n");
    if (!fd.mangleString)
    {
        OutBuffer buf;
        auto backref = Backref(null);
        scope Mangler v = new Mangler(buf, &backref);
        v.mangleExact(fd);
        fd.mangleString = buf.extractChars();
    }
    return fd.mangleString;
}

void mangleToBuffer(Type t, ref OutBuffer buf)
{
    //printf("mangleToBuffer t()\n");
    if (t.deco)
        buf.writestring(t.deco);
    else
    {
        auto backref = Backref(t);
        mangleType(t, 0, buf, backref);
        //printf("%s\n", buf.peekChars());
    }
}

void mangleToBuffer(Expression e, ref OutBuffer buf)
{
    //printf("mangleToBuffer e()\n");
    auto backref = Backref(null);
    scope Mangler v = new Mangler(buf, &backref);
    e.accept(v);
}

void mangleToBuffer(Dsymbol s, ref OutBuffer buf)
{
    //printf("mangleToBuffer s(%s)\n", s.toChars());
    auto backref = Backref(null);
    scope Mangler v = new Mangler(buf, &backref);
    s.accept(v);
}

void mangleToBuffer(TemplateInstance ti, ref OutBuffer buf)
{
    //printf("mangleToBuffer ti()\n");
    auto backref = Backref(null);
    scope Mangler v = new Mangler(buf, &backref);
    v.mangleTemplateInstance(ti);
}

/// Returns: `true` if the given character is a valid mangled character
package(dmd) bool isValidMangling(dchar c) nothrow
{
    import dmd.common.charactertables;

    return
        c >= 'A' && c <= 'Z' ||
        c >= 'a' && c <= 'z' ||
        c >= '0' && c <= '9' ||
        c != 0 && strchr("$%().:?@[]_", c) ||
        isAnyIdentifierCharacter(c);
}

// valid mangled characters
unittest
{
    assert('a'.isValidMangling);
    assert('B'.isValidMangling);
    assert('2'.isValidMangling);
    assert('@'.isValidMangling);
    assert('_'.isValidMangling);
}

// invalid mangled characters
unittest
{
    assert(!'-'.isValidMangling);
    assert(!0.isValidMangling);
    assert(!'/'.isValidMangling);
    assert(!'\\'.isValidMangling);
}

/**********************************************
 * Convert a string representing a type (the deco) and
 * return its equivalent Type.
 * Params:
 *      deco = string containing the deco
 * Returns:
 *      null for failed to convert
 *      Type for succeeded
 */

public Type decoToType(const(char)[] deco)
{
    //printf("decoToType(): %.*s\n", cast(int)deco.length, deco.ptr);
    if (auto sv = Type.stringtable.lookup(deco))
    {
        if (sv.value)
        {
            Type t = cast(Type)sv.value;
            assert(t.deco);
            return t;
        }
    }
    return null;
}


/***************************************** private ***************************************/

private:


import core.stdc.ctype;
import core.stdc.stdio;
import core.stdc.string;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.astenums;
import dmd.mangle.basic;
import dmd.dclass;
import dmd.declaration;
import dmd.dinterpret;
import dmd.dmodule;
import dmd.dsymbol;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.funcsem;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.mtype;
import dmd.root.ctfloat;
import dmd.common.outbuffer;
import dmd.optimize;
import dmd.root.aav;
import dmd.root.string;
import dmd.root.stringtable;
import dmd.root.utf;
import dmd.target;
import dmd.tokens;
import dmd.visitor;

/************************************************
 * Append the mangling of type `t` to `buf`.
 * Params:
 *      t = type to mangle
 *      modMask = mod bits currently applying to t
 *      buf = buffer to append mangling to
 *      backref = state of back references (updated)
 */
void mangleType(Type t, ubyte modMask, ref OutBuffer buf, ref Backref backref)
{
    void visitWithMask(Type t, ubyte modMask)
    {
        void mangleSymbol(Dsymbol s)
        {
            scope Mangler v = new Mangler(buf, &backref);
            v.mangleSymbol(s);
        }

        void visitType(Type t)
        {
            tyToDecoBuffer(buf, t.ty);
        }

        void visitTypeNext(TypeNext t)
        {
            visitType(t);
            visitWithMask(t.next, t.mod);
        }

        void visitTypeVector(TypeVector t)
        {
            buf.writestring("Nh");
            visitWithMask(t.basetype, t.mod);
        }

        void visitTypeSArray(TypeSArray t)
        {
            visitType(t);
            if (t.dim)
                buf.print(t.dim.toInteger());
            if (t.next)
                visitWithMask(t.next, t.mod);
        }

        void visitTypeDArray(TypeDArray t)
        {
            visitType(t);
            if (t.next)
                visitWithMask(t.next, t.mod);
        }

        void visitTypeAArray(TypeAArray t)
        {
            visitType(t);
            visitWithMask(t.index, 0);
            visitWithMask(t.next, t.mod);
        }

        void visitTypeFunction(TypeFunction t)
        {
            //printf("TypeFunction.toDecoBuffer() t = %p %s\n", t, t.toChars());
            //static int nest; if (++nest == 50) *(char*)0=0;
            mangleFuncType(t, t, t.mod, t.next, buf, backref);
        }

        void visitTypeIdentifier(TypeIdentifier t)
        {
            visitType(t);
            auto name = t.ident.toString();
            buf.print(cast(int)name.length);
            buf.writestring(name);
        }

        void visitTypeEnum(TypeEnum t)
        {
            visitType(t);
            mangleSymbol(t.sym);
        }

        void visitTypeStruct(TypeStruct t)
        {
            //printf("TypeStruct.toDecoBuffer('%s') = '%s'\n", t.toChars(), name);
            visitType(t);
            mangleSymbol(t.sym);
        }

        void visitTypeClass(TypeClass t)
        {
            //printf("TypeClass.toDecoBuffer('%s' mod=%x) = '%s'\n", t.toChars(), mod, name);
            visitType(t);
            mangleSymbol(t.sym);
        }

        void visitTypeTuple(TypeTuple t)
        {
            //printf("TypeTuple.toDecoBuffer() t = %p, %s\n", t, t.toChars());
            visitType(t);
            Parameter._foreach(t.arguments, (idx, param) {
                    mangleParameter(param, buf, backref);
                    return 0;
            });
            buf.writeByte('Z');
        }

        void visitTypeNull(TypeNull t)
        {
            visitType(t);
        }

        void visitTypeNoreturn(TypeNoreturn t)
        {
            buf.writestring("Nn");
        }

        if (modMask != t.mod)
        {
            MODtoDecoBuffer(buf, t.mod);
        }
        if (backref.addRefToType(buf, t))
            return;

        switch (t.ty)
        {
            case Tpointer:
            case Treference:
            case Tdelegate:
            case Tslice:     visitTypeNext      (cast(TypeNext)t);      break;

            case Tarray:     visitTypeDArray    (t.isTypeDArray());     break;
            case Tsarray:    visitTypeSArray    (t.isTypeSArray());     break;
            case Taarray:    visitTypeAArray    (t.isTypeAArray());     break;
            case Tfunction:  visitTypeFunction  (t.isTypeFunction());   break;
            case Tident:     visitTypeIdentifier(t.isTypeIdentifier()); break;
            case Tclass:     visitTypeClass     (t.isTypeClass());      break;
            case Tstruct:    visitTypeStruct    (t.isTypeStruct());     break;
            case Tenum:      visitTypeEnum      (t.isTypeEnum());       break;
            case Ttuple:     visitTypeTuple     (t.isTypeTuple());      break;
            case Tnull:      visitTypeNull      (t.isTypeNull());       break;
            case Tvector:    visitTypeVector    (t.isTypeVector());     break;
            case Tnoreturn:  visitTypeNoreturn  (t.isTypeNoreturn);     break;

            case Terror:
                break;      // ignore errors

            default:         visitType(t); break;
        }
    }

    visitWithMask(t, modMask);
}


/*************************************************************
 * Mangle type of function. writing it to `buf`
 * Params:
 *	t = function type
 *	ta = consult original function type for attributes
 *	modMask = type modifiers
 *	tret = function return type
 *	buf = sink for mangling characters
 *	backref = back reference
 */
void mangleFuncType(TypeFunction t, TypeFunction ta, ubyte modMask, Type tret, ref OutBuffer buf, ref Backref backref)
{
    //printf("mangleFuncType() %s\n", t.toChars());
    if (t.inuse && tret)
    {
        // printf("TypeFunction.mangleFuncType() t = %s inuse\n", t.toChars());
        t.inuse = 2; // flag error to caller
        return;
    }
    t.inuse++;
    if (modMask != t.mod)
        MODtoDecoBuffer(buf, t.mod);

    char mc;
    final switch (t.linkage)
    {
    case LINK.default_:
    case LINK.d:
        mc = 'F';
        break;
    case LINK.c:
        mc = 'U';
        break;
    case LINK.windows:
        mc = 'W';
        break;
    case LINK.cpp:
        mc = 'R';
        break;
    case LINK.objc:
        mc = 'Y';
        break;
    case LINK.system:
        assert(0);
    }
    buf.writeByte(mc);

    if (ta.purity)
        buf.writestring("Na");
    if (ta.isNothrow)
        buf.writestring("Nb");
    if (ta.isRef)
        buf.writestring("Nc");
    if (ta.isProperty)
        buf.writestring("Nd");
    if (ta.isNogc)
        buf.writestring("Ni");

    // `return scope` must be in that order
    if (ta.isReturnScope && !ta.isReturnInferred)
    {
        buf.writestring("NjNl");
    }
    else
    {
        // when return ref, the order is `scope return`
        if (ta.isScopeQual && !ta.isScopeInferred)
            buf.writestring("Nl");

        if (ta.isReturn && !ta.isReturnInferred)
            buf.writestring("Nj");
    }

    if (ta.isLive)
        buf.writestring("Nm");

    switch (ta.trust)
    {
        case TRUST.trusted:
            buf.writestring("Ne");
            break;
        case TRUST.safe:
            buf.writestring("Nf");
            break;
        default:
            break;
    }

    // Write argument types
    foreach (idx, param; t.parameterList)
        mangleParameter(param, buf, backref);
    //if (buf.data[buf.length - 1] == '@') assert(0);
    buf.writeByte(cast(ubyte)('Z' - t.parameterList.varargs)); // mark end of arg list
    if (tret !is null)
        mangleType(tret, 0, buf, backref);
    t.inuse--;
}

/*************************************************************
 */
void mangleParameter(Parameter p, ref OutBuffer buf, ref Backref backref)
{
    // https://dlang.org/spec/abi.html#Parameter

    auto stc = p.storageClass;

    // Inferred storage classes don't get mangled in
    if (stc & STC.scopeinferred)
        stc &= ~(STC.scope_ | STC.scopeinferred);
    if (stc & STC.returninferred)
        stc &= ~(STC.return_ | STC.returninferred);

    // much like hdrgen.stcToBuffer()
    string rrs;
    const isout = (stc & STC.out_) != 0;
    final switch (buildScopeRef(stc))
    {
        case ScopeRef.None:
        case ScopeRef.Scope:
        case ScopeRef.Ref:
        case ScopeRef.Return:
        case ScopeRef.RefScope:
            break;

        case ScopeRef.ReturnScope:     rrs = "NkM";                  goto L1;  // return scope
        case ScopeRef.ReturnRef:       rrs = isout ? "NkJ"  : "NkK"; goto L1;  // return ref
        case ScopeRef.ReturnRef_Scope: rrs = isout ? "MNkJ" : "MNkK"; goto L1; // scope return ref
        case ScopeRef.Ref_ReturnScope: rrs = isout ? "NkMJ" : "NkMK"; goto L1; // return scope ref
        L1:
            buf.writestring(rrs);
            stc &= ~(STC.out_ | STC.scope_ | STC.ref_ | STC.return_);
            break;
    }

    if (stc & STC.scope_)
        buf.writeByte('M');  // scope

    if (stc & STC.return_)
        buf.writestring("Nk"); // return

    switch (stc & ((STC.IOR | STC.lazy_) & ~STC.constscoperef))
    {
    case STC.none:
        break;
    case STC.in_:
        buf.writeByte('I');
        break;
    case STC.in_ | STC.ref_:
        buf.writestring("IK");
        break;
    case STC.out_:
        buf.writeByte('J');
        break;
    case STC.ref_:
        buf.writeByte('K');
        break;
    case STC.lazy_:
        buf.writeByte('L');
        break;
    default:
        debug
        {
            printf("storageClass = x%llx\n", stc & (STC.IOR | STC.lazy_));
        }
        assert(0);
    }
    mangleType(p.type, (stc & STC.in_) ? MODFlags.const_ : 0, buf, backref);
}


private extern (C++) final class Mangler : Visitor
{
    alias visit = Visitor.visit;
public:
    static assert(Key.sizeof == size_t.sizeof);

    OutBuffer* buf;
    Backref* backref;

    extern (D) this(ref OutBuffer buf, Backref* backref) @trusted
    {
        this.buf = &buf;
        this.backref = backref;
    }

    void mangleSymbol(Dsymbol s)
    {
        s.accept(this);
    }

    void mangleIdentifier(Identifier id, Dsymbol s)
    {
        if (!backref.addRefToIdentifier(*buf, id))
            toBuffer(*buf, id.toString(), s);
    }

    void mangleInteger(dinteger_t v)
    {
        if (cast(sinteger_t) v < 0)
        {
            buf.writeByte('N');
            buf.print(-v);
        }
        else
        {
            buf.writeByte('i');
            buf.print(v);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    void mangleDecl(Declaration sthis)
    {
        mangleParent(sthis);
        assert(sthis.ident);
        mangleIdentifier(sthis.ident, sthis);
        if (FuncDeclaration fd = sthis.isFuncDeclaration())
        {
            mangleFunc(fd, false);
        }
        else if (sthis.type)
        {
            mangleType(sthis.type, 0, *buf, *backref);
        }
        else
            assert(0);
    }

    void mangleParent(Dsymbol s)
    {
        //printf("mangleParent() %s %s\n", s.kind(), s.toChars());
        Dsymbol p;
        if (TemplateInstance ti = s.isTemplateInstance())
            p = ti.isTemplateMixin() ? ti.parent : ti.tempdecl.parent;
        else
            p = s.parent;
        if (p)
        {
            uint localNum = s.localNum;
            mangleParent(p);
            auto ti = p.isTemplateInstance();
            if (ti && !ti.isTemplateMixin())
            {
                localNum = ti.tempdecl.localNum;
                mangleTemplateInstance(ti);
            }
            else if (p.getIdent())
            {
                mangleIdentifier(p.ident, s);
                if (FuncDeclaration f = p.isFuncDeclaration())
                    mangleFunc(f, true);
            }
            else
                buf.writeByte('0');

            if (localNum)
                writeLocalParent(*buf, localNum);
        }
    }

    void mangleFunc(FuncDeclaration fd, bool inParent)
    {
        //printf("deco = '%s'\n", fd.type.deco ? fd.type.deco : "null");
        //printf("fd.type = %s\n", fd.type.toChars());
        if (fd.needThis() || fd.isNested())
            buf.writeByte('M');

        if (!fd.type || fd.type.ty == Terror)
        {
            // never should have gotten here, but could be the result of
            // failed speculative compilation
            buf.writestring("9__error__FZ");

            //printf("[%s] %s no type\n", fd.loc.toChars(), fd.toChars());
            //assert(0); // don't mangle function until semantic3 done.
        }
        else if (inParent)
        {
            TypeFunction tf = fd.type.isTypeFunction();
            TypeFunction tfo = fd.originalType.isTypeFunction();
            mangleFuncType(tf, tfo, 0, null, *buf, *backref);
        }
        else
        {
            mangleType(fd.type, 0, *buf, *backref);
        }
    }

    override void visit(Declaration d)
    {
        //printf("Declaration.mangle(this = %p, '%s', parent = '%s', linkage = %d)\n",
        //        d, d.toChars(), d.parent ? d.parent.toChars() : "null", d.linkage);
        if (const id = externallyMangledIdentifier(d))
        {
            buf.writestring(id);
            return;
        }
        buf.writestring("_D");
        mangleDecl(d);
        debug
        {
            const slice = (*buf)[];
            assert(slice.length);
            for (size_t pos; pos < slice.length; )
            {
                dchar c;
                auto ppos = pos;
                const s = utf_decodeChar(slice, pos, c);
                assert(s is null, s);
                assert(c.isValidMangling, "The mangled name '" ~ slice ~ "' " ~
                    "contains an invalid character: " ~ slice[ppos..pos]);
            }
        }
    }

    /******************************************************************************
     * Normally FuncDeclaration and FuncAliasDeclaration have overloads.
     * If and only if there is no overloads, mangle() could return
     * exact mangled name.
     *
     *      module test;
     *      void foo(long) {}           // _D4test3fooFlZv
     *      void foo(string) {}         // _D4test3fooFAyaZv
     *
     *      // from FuncDeclaration.mangle().
     *      pragma(msg, foo.mangleof);  // prints unexact mangled name "4test3foo"
     *                                  // by calling Dsymbol.mangle()
     *
     *      // from FuncAliasDeclaration.mangle()
     *      pragma(msg, __traits(getOverloads, test, "foo")[0].mangleof);  // "_D4test3fooFlZv"
     *      pragma(msg, __traits(getOverloads, test, "foo")[1].mangleof);  // "_D4test3fooFAyaZv"
     *
     * If a function has no overloads, .mangleof property still returns exact mangled name.
     *
     *      void bar() {}
     *      pragma(msg, bar.mangleof);  // still prints "_D4test3barFZv"
     *                                  // by calling FuncDeclaration.mangleExact().
     */
    override void visit(FuncDeclaration fd)
    {
        if (fd.isUnique())
            mangleExact(fd);
        else
            visit(cast(Dsymbol)fd);
    }

    // ditto
    override void visit(FuncAliasDeclaration fd)
    {
        FuncDeclaration f = fd.toAliasFunc();
        FuncAliasDeclaration fa = f.isFuncAliasDeclaration();
        if (!fd.hasOverloads && !fa)
        {
            mangleExact(f);
            return;
        }
        if (fa)
        {
            mangleSymbol(fa);
            return;
        }
        visit(cast(Dsymbol)fd);
    }

    override void visit(OverDeclaration od)
    {
        if (od.overnext)
        {
            visit(cast(Dsymbol)od);
            return;
        }
        if (FuncDeclaration fd = od.aliassym.isFuncDeclaration())
        {
            if (fd.isUnique())
            {
                mangleExact(fd);
                return;
            }
        }
        if (TemplateDeclaration td = od.aliassym.isTemplateDeclaration())
        {
            if (td.overnext is null)
            {
                mangleSymbol(td);
                return;
            }
        }
        visit(cast(Dsymbol)od);
    }

    void mangleExact(FuncDeclaration fd)
    {
        assert(!fd.isFuncAliasDeclaration());
        if (fd.mangleOverride)
        {
            buf.writestring(fd.mangleOverride);
            return;
        }
        if (fd.isMain())
        {
            buf.writestring("_Dmain");
            return;
        }
        if (fd.isWinMain() || fd.isDllMain())
        {
            buf.writestring(fd.ident.toString());
            return;
        }
        visit(cast(Declaration)fd);
    }

    override void visit(VarDeclaration vd)
    {
        if (vd.mangleOverride)
        {
            buf.writestring(vd.mangleOverride);
            return;
        }
        visit(cast(Declaration)vd);
    }

    override void visit(AggregateDeclaration ad)
    {
        ClassDeclaration cd = ad.isClassDeclaration();
        Dsymbol parentsave = ad.parent;
        if (cd)
        {
            /* These are reserved to the compiler, so keep simple
             * names for them.
             */
            if (cd.ident == Id.Exception && cd.parent.ident == Id.object || cd.ident == Id.TypeInfo || cd.ident == Id.TypeInfo_Struct || cd.ident == Id.TypeInfo_Class || cd.ident == Id.TypeInfo_Tuple || cd == ClassDeclaration.object || cd == Type.typeinfoclass || cd == Module.moduleinfo || strncmp(cd.ident.toChars(), "TypeInfo_", 9) == 0)
            {
                // Don't mangle parent
                ad.parent = null;
            }
        }
        visit(cast(Dsymbol)ad);
        ad.parent = parentsave;
    }

    override void visit(TemplateInstance ti)
    {
        version (none)
        {
            printf("TemplateInstance.mangle() %p %s", ti, ti.toChars());
            if (ti.parent)
                printf("  parent = %s %s", ti.parent.kind(), ti.parent.toChars());
            printf("\n");
        }
        if (!ti.tempdecl)
            error(ti.loc, "%s `%s` is not defined", ti.kind, ti.toPrettyChars);
        else
            mangleParent(ti);

        if (ti.isTemplateMixin() && ti.ident)
            mangleIdentifier(ti.ident, ti);
        else
            mangleTemplateInstance(ti);
    }

    void mangleTemplateInstance(TemplateInstance ti)
    {
        TemplateDeclaration tempdecl = ti.tempdecl.isTemplateDeclaration();
        assert(tempdecl);

        // Use "__U" for the symbols declared inside template constraint.
        const char T = ti.members ? 'T' : 'U';
        buf.printf("__%c", T);
        mangleIdentifier(tempdecl.ident, tempdecl);

        auto args = ti.tiargs;
        size_t nparams = tempdecl.parameters.length - (tempdecl.isVariadic() ? 1 : 0);
        for (size_t i = 0; i < args.length; i++)
        {
            auto o = (*args)[i];
            Type ta = isType(o);
            Expression ea = isExpression(o);
            Dsymbol sa = isDsymbol(o);
            Tuple va = isTuple(o);
            //printf("\to [%d] %p ta %p ea %p sa %p va %p\n", i, o, ta, ea, sa, va);
            if (i < nparams && (*tempdecl.parameters)[i].specialization())
                buf.writeByte('H'); // https://issues.dlang.org/show_bug.cgi?id=6574
            if (ta)
            {
                buf.writeByte('T');
                mangleType(ta, 0, *buf, *backref);
            }
            else if (ea)
            {
                // Don't interpret it yet, it might actually be an alias template parameter.
                // Only constfold manifest constants, not const/immutable lvalues, see https://issues.dlang.org/show_bug.cgi?id=17339.
                enum keepLvalue = true;
                ea = ea.optimize(WANTvalue, keepLvalue);
                if (auto ev = ea.isVarExp())
                {
                    sa = ev.var;
                    ea = null;
                    goto Lsa;
                }
                if (auto et = ea.isThisExp())
                {
                    sa = et.var;
                    ea = null;
                    goto Lsa;
                }
                if (auto ef = ea.isFuncExp())
                {
                    if (ef.td)
                        sa = ef.td;
                    else
                        sa = ef.fd;
                    ea = null;
                    goto Lsa;
                }
                buf.writeByte('V');
                if (ea.op == EXP.tuple)
                {
                    error(ea.loc, "sequence is not a valid template value argument");
                    continue;
                }
                // Now that we know it is not an alias, we MUST obtain a value
                const olderr = global.errors;
                ea = ea.ctfeInterpret();
                if (ea.op == EXP.error || olderr != global.errors)
                    continue;

                /* Use type mangling that matches what it would be for a function parameter
                */
                mangleType(ea.type, 0, *buf, *backref);
                ea.accept(this);
            }
            else if (sa)
            {
            Lsa:
                sa = sa.toAlias();
                if (sa.isDeclaration() && !sa.isOverDeclaration())
                {
                    Declaration d = sa.isDeclaration();

                    if (auto fad = d.isFuncAliasDeclaration())
                        d = fad.toAliasFunc();
                    if (d.mangleOverride)
                    {
                        buf.writeByte('X');
                        toBuffer(*buf, d.mangleOverride, d);
                        continue;
                    }
                    if (const id = externallyMangledIdentifier(d))
                    {
                        buf.writeByte('X');
                        toBuffer(*buf, id, d);
                        continue;
                    }
                    if (!d.type || !d.type.deco)
                    {
                        error(ti.loc, "%s `%s` forward reference of %s `%s`", ti.kind, ti.toPrettyChars, d.kind(), d.toChars());
                        continue;
                    }
                }
                buf.writeByte('S');
                mangleSymbol(sa);
            }
            else if (va)
            {
                assert(i + 1 == args.length); // must be last one
                args = &va.objects;
                i = -cast(size_t)1;
            }
            else
                assert(0);
        }
        buf.writeByte('Z');
    }

    override void visit(Dsymbol s)
    {
        version (none)
        {
            printf("Dsymbol.mangle() '%s'", s.toChars());
            if (s.parent)
                printf("  parent = %s %s", s.parent.kind(), s.parent.toChars());
            printf("\n");
        }
        if (s.parent && s.ident)
        {
            if (auto m = s.parent.isModule())
            {
                if (m.filetype == FileType.c)
                {
                    /* C types at global level get mangled into the __C global namespace
                     * to get the same mangling regardless of which module it
                     * is declared in. This works because types are the same if the mangling
                     * is the same.
                     */
                    mangleIdentifier(Id.ImportC, s); // parent
                    mangleIdentifier(s.ident, s);
                    return;
                }
            }
        }
        mangleParent(s);
        if (s.ident)
            mangleIdentifier(s.ident, s);
        else
            toBuffer(*buf, s.toString(), s);
        //printf("Dsymbol.mangle() %s = %s\n", s.toChars(), id);
    }

    ////////////////////////////////////////////////////////////////////////////
    override void visit(Expression e)
    {
        if (!e.type.isTypeError())
            error(e.loc, "expression `%s` is not a valid template value argument", e.toChars());
    }

    override void visit(IntegerExp e)
    {
        mangleInteger(e.toInteger());
    }

    override void visit(RealExp e)
    {
        buf.writeByte('e');
        realToMangleBuffer(*buf, e.value);
    }

    override void visit(ComplexExp e)
    {
        buf.writeByte('c');
        realToMangleBuffer(*buf, e.toReal());
        buf.writeByte('c'); // separate the two
        realToMangleBuffer(*buf, e.toImaginary());
    }

    override void visit(NullExp e)
    {
        buf.writeByte('n');
    }

    override void visit(StringExp e)
    {
        char m;
        OutBuffer tmp;
        const(char)[] q;

        void mangleAsArray()
        {
            buf.writeByte('A');
            buf.print(e.len);
            foreach (i; 0 .. e.len)
                mangleInteger(e.getIndex(i));
        }

        /* Write string in UTF-8 format
         */
        switch (e.sz)
        {
        case 1:
            m = 'a';
            q = e.peekString();
            break;
        case 2:
        {
            m = 'w';
            const slice = e.peekWstring();
            for (size_t u = 0; u < e.len;)
            {
                dchar c;
                if (const s = utf_decodeWchar(slice, u, c))
                    return mangleAsArray();
                else
                    tmp.writeUTF8(c);
            }
            q = tmp[];
            break;
        }
        case 4:
        {
            m = 'd';
            const slice = e.peekDstring();
            foreach (c; slice)
            {
                if (!utf_isValidDchar(c))
                    return mangleAsArray();
                else
                    tmp.writeUTF8(c);
            }
            q = tmp[];
            break;
        }
        case 8:
            // String of size 8 has to be hexstring cast to long[], mangle as array literal
            return mangleAsArray();
        default:
            assert(0);
        }
        buf.reserve(1 + 11 + 2 * q.length);
        buf.writeByte(m);
        buf.print(q.length);
        buf.writeByte('_');    // nbytes <= 11
        buf.writeHexString(cast(const(ubyte)[]) q, false);
    }

    override void visit(ArrayLiteralExp e)
    {
        const dim = e.elements ? e.elements.length : 0;
        buf.writeByte('A');
        buf.print(dim);
        foreach (i; 0 .. dim)
        {
            e[i].accept(this);
        }
    }

    override void visit(AssocArrayLiteralExp e)
    {
        const dim = e.keys.length;
        buf.writeByte('A');
        buf.print(dim);
        foreach (i; 0 .. dim)
        {
            (*e.keys)[i].accept(this);
            (*e.values)[i].accept(this);
        }
    }

    override void visit(StructLiteralExp e)
    {
        const dim = e.elements ? e.elements.length : 0;
        buf.writeByte('S');
        buf.print(dim);
        foreach (i; 0 .. dim)
        {
            Expression ex = (*e.elements)[i];
            if (ex)
                ex.accept(this);
            else
                buf.writeByte('v'); // 'v' for void
        }
    }

    override void visit(FuncExp e)
    {
        buf.writeByte('f');
        if (e.td)
            mangleSymbol(e.td);
        else
            mangleSymbol(e.fd);
    }
}

/***************************************
 * Manage back reference mangling
 */
private struct Backref
{
    /**
    * Back references a non-basic type
    *
    * The encoded mangling is
    *       'Q' <relative position of first occurrence of type>
    *
    * Params:
    *  t = the type to encode via back referencing
    *
    * Returns:
    *  true if the type was found. A back reference has been encoded.
    *  false if the type was not found. The current position is saved for later back references.
    */
    bool addRefToType(ref OutBuffer buf, Type t)
    {
        if (t.isTypeBasic())
            return false;

        /**
         * https://issues.dlang.org/show_bug.cgi?id=21591
         *
         * Special case for unmerged TypeFunctions: use the generic merged
         * function type as backref cache key to avoid missed backrefs.
         *
         * Merging is based on mangling, so we need to avoid an infinite
         * recursion by excluding the case where `t` is the root type passed to
         * `mangleToBuffer()`.
         */
        if (t != rootType)
        {
            if (t.isFunction_Delegate_PtrToFunction())
            {
                import dmd.typesem : merge2;
                t = t.merge2();
            }
        }

        return backrefImpl(buf, types, t);
    }

    /**
    * Back references a single identifier
    *
    * The encoded mangling is
    *       'Q' <relative position of first occurrence of type>
    *
    * Params:
    *  id = the identifier to encode via back referencing
    *
    * Returns:
    *  true if the identifier was found. A back reference has been encoded.
    *  false if the identifier was not found. The current position is saved for later back references.
    */
    bool addRefToIdentifier(ref OutBuffer buf, Identifier id)
    {
        return backrefImpl(buf, idents, id);
    }

  private:

    extern(D) bool backrefImpl(T)(ref OutBuffer buf, ref AssocArray!(T, size_t) aa, T key)
    {
        auto p = aa.getLvalue(key);
        if (*p)
        {
            const offset = *p - 1;
            writeBackRef(buf, buf.length - offset);
            return true;
        }
        *p = buf.length + 1;
        return false;
    }

    Type rootType;                          /// avoid infinite recursion
    AssocArray!(Type, size_t) types;        /// Type => (offset+1) in buf
    AssocArray!(Identifier, size_t) idents; /// Identifier => (offset+1) in buf
}

/*********************************
 * Mangling for mod.
 */
private void MODtoDecoBuffer(ref OutBuffer buf, MOD mod) @safe
{
    switch (mod)
    {
    case 0:
        break;
    case MODFlags.const_:
        buf.writeByte('x');
        break;
    case MODFlags.immutable_:
        buf.writeByte('y');
        break;
    case MODFlags.shared_:
        buf.writeByte('O');
        break;
    case MODFlags.shared_ | MODFlags.const_:
        buf.writestring("Ox");
        break;
    case MODFlags.wild:
        buf.writestring("Ng");
        break;
    case MODFlags.wildconst:
        buf.writestring("Ngx");
        break;
    case MODFlags.shared_ | MODFlags.wild:
        buf.writestring("ONg");
        break;
    case MODFlags.shared_ | MODFlags.wildconst:
        buf.writestring("ONgx");
        break;
    default:
        assert(0);
    }
}


/**
 * writes a back reference with the relative position encoded with base 26
 *  using upper case letters for all digits but the last digit which uses
 *  a lower case letter.
 * The decoder has to look up the referenced position to determine
 *  whether the back reference is an identifier (starts with a digit)
 *  or a type (starts with a letter).
 *
 * Params:
 *  buf           = buffer to write to
 *  pos           = relative position to encode
 */
private
void writeBackRef(ref OutBuffer buf, size_t pos) @safe
{
    buf.writeByte('Q');
    enum base = 26;
    size_t mul = 1;
    while (pos >= mul * base)
        mul *= base;
    while (mul >= base)
    {
        auto dig = cast(ubyte)(pos / mul);
        buf.writeByte(cast(char)('A' + dig));
        pos -= dig * mul;
        mul /= base;
    }
    buf.writeByte(cast(char)('a' + pos));
}


/************************************************************
 * Write length prefixed string to buf.
 */
private
extern (D) void toBuffer(ref OutBuffer buf, const(char)[] id, Dsymbol s)
{
    const len = id.length;
    if (buf.length + len >= 8 * 1024 * 1024) // 8 megs ought be enough for anyone
        error(s.loc, "%s `%s` excessive length %llu for symbol, possible recursive expansion?", s.kind, s.toPrettyChars, cast(ulong)(buf.length + len));
    else
    {
        buf.print(len);
        buf.writestring(id);
    }
}


/*****
 * There can be multiple different declarations in the same
 * function that have the same mangled name.
 * This results in localNum having a non-zero number, which
 * is used to add a fake parent of the form `__Sddd` to make
 * the mangled names unique.
 * https://issues.dlang.org/show_bug.cgi?id=20565
 * Params:
 *      buf = buffer to write to
 *      localNum = local symbol number
 */
private
void writeLocalParent(ref OutBuffer buf, uint localNum)
{
    uint ndigits = 1;
    auto n = localNum;
    while (n >= 10)
    {
        n /= 10;
        ++ndigits;
    }
    buf.printf("%u__S%u", ndigits + 3, localNum);
}

/*************************
 * Write real to buffer.
 * Params:
 *      buf = buffer to write to
 *      value = real to write
 */
private
void realToMangleBuffer(ref OutBuffer buf, real_t value)
{
    /* Rely on %A to get portable mangling.
     * Must munge result to get only identifier characters.
     *
     * Possible values from %A  => mangled result
     * NAN                      => NAN
     * -INF                     => NINF
     * INF                      => INF
     * -0X1.1BC18BA997B95P+79   => N11BC18BA997B95P79
     * 0X1.9P+2                 => 19P2
     */
    if (CTFloat.isNaN(value))
    {
        buf.writestring("NAN"); // no -NAN bugs
        return;
    }

    if (value < CTFloat.zero)
    {
        buf.writeByte('N');
        value = -value;
    }

    if (CTFloat.isInfinity(value))
    {
        buf.writestring("INF");
        return;
    }

    char[36] buffer = void;
    // 'A' format yields [-]0xh.hhhhp+-d
    const n = CTFloat.sprint(buffer.ptr, buffer.length, 'A', value);
    assert(n < buffer.length);
    foreach (const c; buffer[2 .. n])
    {
        switch (c)
        {
            case '-':
                buf.writeByte('N');
                break;

            case '+':
            case '.':
                break;

            default:
                buf.writeByte(c);
                break;
        }
    }
}

/************************************************************
 * Try to obtain an externally mangled identifier from a declaration.
 * If the declaration is at global scope or mixed in at global scope,
 * the user might want to call it externally, so an externally mangled
 * name is returned. Member functions or nested functions can't be called
 * externally in C, so in that case null is returned. C++ does support
 * namespaces, so extern(C++) always gives a C++ mangled name.
 *
 * See also: https://issues.dlang.org/show_bug.cgi?id=20012
 *
 * Params:
 *     d = declaration to mangle
 *
 * Returns:
 *     an externally mangled name or null if the declaration cannot be called externally
 */
private
extern (D) const(char)[] externallyMangledIdentifier(Declaration d)
{
    assert(!d.mangleOverride, "mangle overrides should have been handled earlier");

    const linkage = d.resolvedLinkage();
    const par = d.toParent(); //toParent() skips over mixin templates
    if (!par || par.isModule() || linkage == LINK.cpp ||
        (linkage == LINK.c && d.isCsymbol() &&
         // https://github.com/dlang/dmd/issues/21241
         // Static check is so C static functions get a unique mangle so the linker
         // won't merge them if compiling all-at-once.
         // Non-static functions can use their ident as their mangle.
         ((d.isFuncDeclaration() && !d.isStatic()) ||
          (d.isVarDeclaration() && d.isDataseg() && d.storage_class & STC.extern_))))
    {
        if (linkage != LINK.d && d.localNum)
            error(d.loc, "%s `%s` the same declaration cannot be in multiple scopes with non-D linkage", d.kind, d.toPrettyChars);

        final switch (linkage)
        {
            case LINK.d:
                break;
            case LINK.c:
            case LINK.windows:
            case LINK.objc:
                return d.ident.toString();
            case LINK.cpp:
            {
                const p = target.cpp.toMangle(d);
                return p.toDString();
            }
            case LINK.default_:
                error(d.loc, "%s `%s` forward declaration", d.kind, d.toPrettyChars);
                return d.ident.toString();
            case LINK.system:
                assert(0);
        }
    }
    return null;
}
