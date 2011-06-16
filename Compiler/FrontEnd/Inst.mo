/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-CurrentYear, Link�ping University,
 * Department of Computer and Information Science,
 * SE-58183 Link�ping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 
 * AND THIS OSMC PUBLIC LICENSE (OSMC-PL). 
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES RECIPIENT'S  
 * ACCEPTANCE OF THE OSMC PUBLIC LICENSE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from Link�ping University, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or  
 * http://www.openmodelica.org, and in the OpenModelica distribution. 
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS
 * OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package Inst
" file:         Inst.mo
  package:     Inst
  description: Model instantiation

  RCS: $Id$

  This module is responsible for instantiation of Modelica models.
  The instantation is the process of instantiating model components,
  flattening inheritance and generating equations from connect statements.
  The instantiation process takes Modelica AST as defined in SCode and
  produces variables and equations and algorithms, etc. as defined in DAE.

  This module uses Lookup to lookup classes and variables from the
  environment defined in Env. It uses Connect for generating equations from
  connect statements. The type system defined in Types is used for
  variable instantiation and type . DAE.Mod is used for modifiers and
  merging of modifiers.

  The extends language feature is performed by InstExtends. Instantiation of
  algorithm sections and equation sections (including connections) is done
  by InstSection.

  There are basically four different ways/granularities of instantiation.
  1. Using partialInstClassIn which only instantiates class definitions.
     This function is used for looking up class definitions in e.g. packages.
     For example, if looking up the class A.B.C, a new scope is opened and
     A is partially instantiated in that scope using partialInstClassIn.

  2. Function implicit instantiation. is the last argument of type bool to
     instClassIn. It is needed since instantiation of functions is needed
     to generate code for functions and there are cases where such
     instantiations differ
     from standard function instantiation. For example
     function foo
       input Real x{:};
       ...
     end foo;
     should be possible to instantiate even though the dimension size of x is
     not known.

  3. Implicit instantiation controlled by the next last argument to
     instClassIn.
     This is also needed, when a DAE should not be generated.
     It is not clear when this is needed, perhaps it can be removed in the
     future.

  4. ???"

// public imports
public import Absyn;
public import ClassInf;
public import Connect;
public import ConnectionGraph;
public import DAE;
public import Env;
public import InnerOuter;
public import Mod;
public import Prefix;
public import RTOpts;
public import SCode;
public import UnitAbsyn;


public 
constant Boolean alwaysUnroll = true;
constant Boolean neverUnroll = false;

constant Integer RT_CLOCK_EXECSTAT_MAIN = 11;

// the index of the inst hash table in the global table
constant Integer instHashIndex = 0;

// **
// These type aliases are introduced to make the code a little more readable.
// **

public
type Ident = DAE.Ident "an identifier";

public
type InstanceHierarchy = InnerOuter.InstHierarchy "an instance hierarchy";

public uniontype CallingScope "
Calling scope is used to determine when unconnected flow variables should be set to zero."
  record TOP_CALL   "this is a top call"    end TOP_CALL;
  record INNER_CALL "this is an inner call" end INNER_CALL;
end CallingScope;

public type InstDims = list<list<DAE.Subscript>>
"Changed from list<Subscript> to list<list<Subscript>>. One list for each scope.
 This so when instantiating classes extending from primitive types can collect the dimension of -one- surrounding scope to create type.
 E.g. RealInput p[3]; gives the list {3} for this scope and other lists for outer (in instance hierachy) scopes";

// protected imports
protected import BaseHashTable;
protected import Builtin;
protected import Ceval;
protected import ConnectUtil;
protected import ComponentReference;
protected import DAEDump;
protected import DAEUtil;
protected import Debug;
protected import Dump;
protected import Error;
protected import ErrorExt;
protected import Expression;
protected import ExpressionDump;
protected import ExpressionSimplify;
protected import Graph;
protected import HashTable;
protected import HashTable5;
protected import InstSection;
protected import InstExtends;
protected import Interactive;
protected import Lookup;
protected import MetaUtil;
protected import ModUtil;
protected import OptManager;
protected import PrefixUtil;
protected import SCodeUtil;
protected import Static;
protected import Types;
protected import UnitAbsynBuilder;
protected import UnitChecker;
protected import UnitParserExt;
protected import Util;
protected import Values;
protected import ValuesUtil;
protected import System;
protected import SCodeFlatten;
protected import SCodeDump;
protected import Database;

public function newIdent
"function: newIdent
  This function creates a new, unique identifer.
  The same name is never returned twice."
  output DAE.ComponentRef outComponentRef;
  Integer i;
  String is,s;
algorithm
  i := tick();
  is := intString(i);
  s := stringAppend("__TMP__", is);
  outComponentRef := ComponentReference.makeCrefIdent(s,DAE.ET_OTHER(),{});
end newIdent;

protected function isNotFunction
"function: isNotFunction
  This function returns true if the Class is not a function."
  input SCode.Element cls;
  output Boolean res;
algorithm
  res := SCode.isFunction(cls);
  res := boolNot(res);
end isNotFunction;

public function instantiate
"function: instantiate
  To instantiate a Modelica program, an initial environment is
  built, containing the predefined types. Then the program is
  instantiated by the function instProgram"
  input Env.Cache inCache;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDAElist;
  output SCode.Program outProgram;
algorithm
  (outCache,outIH,outDAElist,outProgram) := match (inCache,inIH,inProgram)
    local
      list<SCode.Element> pnofunc,pfunc,p;
      list<Env.Frame> env,envimpl,envimpl_1;
      DAE.DAElist lfunc,lnofunc,l;
      Env.Cache cache;
      InstanceHierarchy oIH1, oIH2, iIH;
    case (cache,iIH,p)
      equation
        p = SCodeFlatten.flattenProgram(p);
        // Debug.fprintln("insttr", "instantiate");
        pnofunc = Util.listSelect(p, isNotFunction);
        pfunc = Util.listSelect(p, SCode.isFunction);
        (cache,env) = Builtin.initialEnv(cache);
        // Debug.fprintln("insttr", "Instantiating functions");
        // pfuncnames = Util.listMap(pfunc, SCode.className);
        // str1 = Util.stringDelimitList(pfuncnames, ", ");
        // Debug.fprint("insttr", "Instantiating functions: ");
        // Debug.fprintln("insttr", str1);
        envimpl = Env.extendFrameClasses(env, p) "pfunc" ;
        (cache,envimpl_1,oIH1,lfunc) = instProgramImplicit(cache, envimpl, iIH, pfunc);
        // Debug.fprint("insttr", "Instantiating other classes: ");
        // pnofuncnames = Util.listMap(pnofunc, SCode.className);
        // str2 = Util.stringDelimitList(pnofuncnames, ", ");
        // Debug.fprintln("insttr", str2);
        (cache, oIH2, lnofunc) = instProgram(cache, envimpl_1, oIH1, pnofunc);
        l = DAEUtil.joinDaes(lfunc, lnofunc);
        // p_1 = addElaboratedFuncsToProgram(cache,env,p); // stefan
      then
        (cache,oIH2,l,p);
    case (_,_,_)
      equation
        //Debug.fprintln("failtrace", "Inst.instantiate failed");
      then
        fail();
  end match;
end instantiate;

public function instantiateImplicit
"function: instantiateImplicit
  Implicit instantiation of a program can be used for e.g. code generation
  of functions, since a function must be implicitly instantiated in order to
  generate code from it."
  input Env.Cache inCache;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDAElist;
algorithm
  (outCache,outIH,outDAElist) := matchcontinue (inCache,inIH,inProgram)
    local
      list<Env.Frame> env,env_1;
      DAE.DAElist l;
      list<SCode.Element> p;
      Env.Cache cache;
    case (cache,inIH,p)
      equation
        // Debug.fprintln("insttr", "instantiate_implicit");
        (cache,env) = Builtin.initialEnv(cache);
        env_1 = Env.extendFrameClasses(env, p);
        (cache,_,outIH,l) = instProgramImplicit(cache,env_1,inIH, p);
      then
        (cache,outIH,l);
    case (_,_,_)
      equation
        //Debug.fprintln("failtrace", "Inst.instantiateImplicit failed");
      then
        fail();
  end matchcontinue;
end instantiateImplicit;

public function instantiateClass
"function: instantiateClass
  To enable interactive instantiation, an arbitrary class in the program
  needs to be possible to instantiate. This function performs the same
  action as instProgram, but given a specific class to instantiate.

   First, all the class definitions are added to the environment without
  modifications, and then the specified class is instantiated in the
  function instClassInProgram"
  input Env.Cache inCache;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDAElist;
algorithm
  (outCache,outEnv,outIH,outDAElist) := matchcontinue (inCache,inIH,inProgram,inPath)
    local
      Absyn.Path cr,path;
      list<Env.Frame> env,env_1,env_2;
      DAE.DAElist dae1,dae,dae2;
      list<SCode.Element> cdecls;
      String name2,n,pathstr,name,cname_str;
      SCode.Element cdef;
      Env.Cache cache;
      InstanceHierarchy ih;
      ConnectionGraph.ConnectionGraph graph;
      DAE.ElementSource source "the origin of the element";
      list<DAE.Element> daeElts;

    case (cache,ih,{},cr)
      equation
        Error.addMessage(Error.NO_CLASSES_LOADED, {});
      then
        fail();

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.IDENT(name = name2))) /* top level class */
      equation
        cdecls = SCodeFlatten.flattenClassInProgram(inPath, cdecls);
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,dae1) = instClassDecls(cache, env, ih, cdecls, path);
        (cache,env_2,ih,dae2) = instClassInProgram(cache, env_1, ih, cdecls, path);
        // check the models for balancing
        //Debug.fcall2("checkModel", checkModelBalancing, SOME(path), dae1);
        //Debug.fcall2("checkModel", checkModelBalancing, SOME(path), dae2);
        // set the source of this element
        source = DAEUtil.addElementSourcePartOfOpt(DAE.emptyElementSource, Env.getEnvPath(env));
        daeElts = DAEUtil.daeElements(dae2);
        dae2 = DAE.DAE({DAE.COMP(name2,daeElts,source,NONE())});
        
        // let the GC collect these as they are used only by Inst!
        setGlobalRoot(instHashIndex, emptyInstHashTable());
        setGlobalRoot(Types.memoryIndex,  Types.createEmptyTypeMemory());
      then
        (cache,env_2,ih,dae2);

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.QUALIFIED(name = name))) /* class in package */
      equation
        cdecls = SCodeFlatten.flattenClassInProgram(inPath, cdecls);
        pathstr = Absyn.pathString(path);
                
        //System.startTimer();
        //print("\nBuiltinMaking");
        (cache,env) = Builtin.initialEnv(cache);
        //System.stopTimer();
        //print("\nBuiltinMaking: " +& realString(System.getTimerIntervalTime()));
        
        //System.startTimer();
        //print("\nInstClassDecls");
        (cache,env_1,ih,_) = instClassDecls(cache, env, ih, cdecls, path);
        //System.stopTimer();
        //print("\nInstClassDecls: " +& realString(System.getTimerIntervalTime()));

        //System.startTimer();
        //print("\nLookupClass");
        (cache,(cdef as SCode.CLASS(name = n)),env_2) = Lookup.lookupClass(cache, env_1, path, true);
        //System.stopTimer();
        //print("\nLookupClass: " +& realString(System.getTimerIntervalTime()));
        
        //System.startTimer();
        //print("\nInstClass");
        (cache,env_2,ih,_,dae,_,_,_,_,graph) = instClass(cache,env_2,ih,
          UnitAbsynBuilder.emptyInstStore(),DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, cdef, {}, false, TOP_CALL(), ConnectionGraph.EMPTY) "impl";
        //System.stopTimer();
        //print("\nInstClass: " +& realString(System.getTimerIntervalTime()));
        
        //System.startTimer();
        //print("\nOverConstrained");
        // deal with Overconstrained connections
        dae = ConnectionGraph.handleOverconstrainedConnections(graph, dae, Absyn.pathString(path));
        //System.stopTimer();
        //print("\nOverconstrained: " +& realString(System.getTimerIntervalTime()));
        
        //System.startTimer();
        //print("\nReEvaluateIf");
        //print(" ********************** backpatch 1 **********************\n");
        dae = reEvaluateInitialIfEqns(cache,env_2,dae,true);
        //System.stopTimer();
        //print("\nReEvaluateIf: " +& realString(System.getTimerIntervalTime()));

        // check the model for balancing
        // Debug.fcall2("checkModel", checkModelBalancing, SOME(path), dae);

        //System.startTimer();
        //print("\nSetSource+DAE");
        // set the source of this element
        source = DAEUtil.addElementSourcePartOfOpt(DAE.emptyElementSource, Env.getEnvPath(env));
        daeElts = DAEUtil.daeElements(dae);
        dae = DAE.DAE({DAE.COMP(pathstr,daeElts,source,NONE())});
        //System.stopTimer();
        //print("\nSetSource+DAE: " +& realString(System.getTimerIntervalTime()));

        // let the GC collect these as they are used only by Inst!
        setGlobalRoot(instHashIndex, emptyInstHashTable());
        setGlobalRoot(Types.memoryIndex,  Types.createEmptyTypeMemory());
      then
        (cache, env_2, ih, dae);

    case (cache,ih,cdecls,path) /* error instantiating */
      equation
        cname_str = Absyn.pathString(path);
        Error.addMessage(Error.ERROR_FLATTENING, {cname_str});
      then
        fail();
  end matchcontinue;
end instantiateClass;

protected function reEvaluateInitialIfEqns "
Author BZ 
This is a backpatch to fix the case of 'connection.isRoot' in initial if equations. 
After the class is instantiated a second sweep is done to check the initial if equations conditions.
If all conditions are constand, we return only the 'correct' branch equations."
  input Env.Cache cache;
  input Env.Env env;
  input DAE.DAElist dae;
  input Boolean isTopCall;
  output DAE.DAElist odae;
algorithm odae := match(cache,env,dae,isTopCall)
  local
    list<DAE.Element> elems;
  case(cache,env,DAE.DAE(elementLst = elems),true)
    equation
      elems = reEvaluateInitialIfEqns2(cache,env,elems);
    then
      DAE.DAE(elems);
  case(_,_,dae,false) then dae;
  end match;
end reEvaluateInitialIfEqns;

protected function reEvaluateInitialIfEqns2 ""
  input Env.Cache cache;
  input Env.Env env;
  input list<DAE.Element> elems;
  output list<DAE.Element> oelems;
algorithm oelems := matchcontinue(cache,env,elems)
  local
    list<DAE.Exp> conds;
    list<Values.Value> valList;
    list<list<DAE.Element>> tbs;
    list<DAE.Element> fb,selectedBranch;
    DAE.Element elem;
    DAE.ElementSource source;
    list<Boolean> blist;
    case(_,_,{}) then {};
  case(cache,env,(elem as DAE.INITIAL_IF_EQUATION(condition1 = conds, equations2=tbs, equations3=fb, source=source))::elems)
    equation
      //print(" (Initial if)To ceval: " +& Util.stringDelimitList(Util.listMap(conds,ExpressionDump.printExpStr),", ") +& "\n");
      (cache,valList) = Ceval.cevalList(cache,env, conds, true,NONE(), Ceval.NO_MSG());
      //print(" Ceval res: ("+&Util.stringDelimitList(Util.listMap(valList,ValuesUtil.printValStr),",")+&")\n");

      blist = Util.listMap(valList,ValuesUtil.valueBool);
      selectedBranch = Util.selectList(blist, tbs, fb);
      selectedBranch = makeDAEElementInitial(selectedBranch);
      oelems = reEvaluateInitialIfEqns2(cache,env,elems);
      oelems = listAppend(selectedBranch,oelems);
      
      //print("RETURN _INITIAL_ DAE: " +& DAEDump.dumpDAEElementsStr(DAE.DAE(selectedBranch,DAE.AVLTREENODE(NONE(),0,NONE(),NONE()))) +& "\n");
      //print(" INSTEAD OF: " +& DAEDump.dumpDAEElementsStr(DAE.DAE({elem},DAE.AVLTREENODE(NONE(),0,NONE(),NONE()))) +& "\n");
    then
      oelems;
  case(cache,env,elem::elems)
    equation
      oelems = reEvaluateInitialIfEqns2(cache,env,elems);
    then
      elem::oelems;
  end matchcontinue;
end reEvaluateInitialIfEqns2;

protected function makeDAEElementInitial "
Author BZ
Helper function for reEvaluateInitialIfEqns, makes the contenst of an initial if equation initial."
  input list<DAE.Element> inElems;
  output list<DAE.Element> outElems;
algorithm 
  outElems := matchcontinue(inElems)
    local
      DAE.Element elem;
      DAE.ComponentRef cr;
      DAE.Exp e1,e2;
      DAE.ElementSource s;
      list<DAE.Exp> expl;
      list<list<DAE.Element>> tbs ;
      list<DAE.Element> fb;
      DAE.Algorithm al;
      list<DAE.Dimension> dims;
    
    case({}) then {};
    
    case(DAE.DEFINE(cr,e1,s)::inElems)
      equation
        outElems = makeDAEElementInitial(inElems);
      then
        DAE.INITIALDEFINE(cr,e1,s)::outElems;
    
    case(DAE.ARRAY_EQUATION(dims,e1,e2,s)::_)
      equation
        outElems = makeDAEElementInitial(inElems);
      then
        DAE.INITIAL_ARRAY_EQUATION(dims,e1,e2,s)::outElems;
    
    case(DAE.EQUATION(e1,e2,s)::inElems)
      equation
        outElems = makeDAEElementInitial(inElems);
      then
        DAE.INITIALEQUATION(e1,e2,s)::outElems;
    
    case(DAE.IF_EQUATION(expl,tbs,fb,s)::inElems)
      equation
        outElems = makeDAEElementInitial(inElems);
      then
        DAE.INITIAL_IF_EQUATION(expl,tbs,fb,s)::outElems;
    
    case(DAE.ALGORITHM(al,s)::inElems)
      equation
        outElems = makeDAEElementInitial(inElems);
      then
        DAE.INITIALALGORITHM(al,s)::outElems;
    
    case(DAE.COMPLEX_EQUATION(e1,e2,s)::inElems)
      equation
        outElems = makeDAEElementInitial(inElems);
      then
        DAE.INITIAL_COMPLEX_EQUATION(e1,e2,s)::outElems;
    
    case(elem::inElems) // safe "last case" since we can not fail in cases above.
      equation
        outElems = makeDAEElementInitial(inElems);
      then
        elem::outElems;
  end matchcontinue;
end makeDAEElementInitial;

public function instantiatePartialClass 
"Author: BZ, 2009-07
 This is a function for instantiating partial 'top' classes.
 It does so by converting the partial class into a non partial class.
 Currently used by: MathCore.modelEquations, CevalScript.checkModel"
  input Env.Cache inCache;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDAElist;
algorithm
  (outCache,outEnv,outIH,outDAElist) := matchcontinue (inCache,inIH,inProgram,inPath)
    local
      Absyn.Path cr,path;
      list<Env.Frame> env,env_1,env_2;
      DAE.DAElist dae1,dae;
      list<SCode.Element> cdecls;
      String name2,n,pathstr,name,cname_str;
      SCode.Element cdef;
      Env.Cache cache;
      InstanceHierarchy ih;
      DAE.ElementSource source "the origin of the element";
      list<DAE.Element> daeElts;
      DAE.FunctionTree funcs;
    
    case (cache,ih,{},cr)
      equation
        Error.addMessage(Error.NO_CLASSES_LOADED, {});
      then
        fail();

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.IDENT(name = name2))) /* top level class */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,dae1) = instClassDecls(cache, env, ih, cdecls, path);
        cdecls = Util.listMap1(cdecls,SCode.classSetPartial,SCode.NOT_PARTIAL());
        (cache,env_2,ih,dae) = instClassInProgram(cache, env_1, ih, cdecls, path);

        // set the source of this element
        source = DAEUtil.addElementSourcePartOfOpt(DAE.emptyElementSource, Env.getEnvPath(env));
        daeElts = DAEUtil.daeElements(dae);
        dae = DAE.DAE({DAE.COMP(name2,daeElts,source,NONE())});
      then
        (cache,env_2,ih,dae);

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.QUALIFIED(name = name))) /* class in package */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,_) = instClassDecls(cache, env, ih, cdecls, path);
        (cache,(cdef as SCode.CLASS(name = n)),env_2) = Lookup.lookupClass(cache,env_1, path, true);
        cdef = SCode.classSetPartial(cdef, SCode.NOT_PARTIAL());
        (cache,env_2,ih,_,dae,_,_,_,_,_) =
          instClass(cache, env_2, ih, UnitAbsynBuilder.emptyInstStore(),DAE.NOMOD(), Prefix.NOPRE(),
            Connect.emptySet, cdef, {}, false, TOP_CALL(), ConnectionGraph.EMPTY) "impl" ;
        pathstr = Absyn.pathString(path);

        // set the source of this element
        source = DAEUtil.addElementSourcePartOfOpt(DAE.emptyElementSource, Env.getEnvPath(env));
        daeElts = DAEUtil.daeElements(dae);
        dae = DAE.DAE({DAE.COMP(pathstr,daeElts,source,NONE())});
      then
        (cache,env_2,ih,dae);

    case (cache,ih,cdecls,path) /* error instantiating */
      equation
        cname_str = Absyn.pathString(path);
        //print(" Error flattening partial, errors: " +& ErrorExt.printMessagesStr() +& "\n");
        Error.addMessage(Error.ERROR_FLATTENING, {cname_str});
      then
        fail();
  end matchcontinue;
end instantiatePartialClass;

public function instantiateClassImplicit
"function: instantiateClassImplicit
  author: PA
  Similar to instantiate_class, i.e. instantation of arbitrary classes
  but this one instantiates the class implicit, which is less costly."
  input Env.Cache inCache;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDAElist;
algorithm
  (outCache,outEnv,outIH,outDAElist) := matchcontinue (inCache,inIH,inProgram,inPath)
    local
      Absyn.Path cr,path;
      list<Env.Frame> env,env_1,env_2;
      DAE.DAElist dae1,dae;
      list<SCode.Element> cdecls;
      String name2,n,name;
      SCode.Element cdef;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,ih,{},cr)
      equation
        Error.addMessage(Error.NO_CLASSES_LOADED, {});
      then
        fail();

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.IDENT(name = name2))) /* top level class */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,dae1) = instClassDecls(cache, env, ih, cdecls, path);
        (cache,env_2,ih,dae) = instClassInProgramImplicit(cache, env_1, ih, cdecls, path);
      then
        (cache,env_2,ih,dae);

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.QUALIFIED(name = name))) /* class in package */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,_) = instClassDecls(cache, env, ih, cdecls, path);
        (cache,(cdef as SCode.CLASS(name = n)),env_2) = Lookup.lookupClass(cache,env_1, path, true);
        env_2 = Env.extendFrameC(env_2, cdef);
        (cache, env, ih, dae) = implicitInstantiation(cache, env_2, ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, cdef, {});
      then
        (cache,env,ih,dae);

    case (_,_,_,_)
      equation
        print("-Inst.instantiateClassImplicit failed\n");
      then
        fail();
  end matchcontinue;
end instantiateClassImplicit;

public function instantiateFunctionImplicit
"function: instantiateFunctionImplicit
  author: PA
  Similar to instantiateClassImplict, i.e. instantation of arbitrary
  classes but this one instantiates the class implicit for functions."
  input Env.Cache inCache;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outCache,outEnv,outIH) := matchcontinue (inCache,inIH,inProgram,inPath)
    local
      Absyn.Path cr,path;
      list<Env.Frame> env,env_1,env_2;
      list<SCode.Element> cdecls;
      String name2,n,name;
      SCode.Element cdef;
      Env.Cache cache;
      InstanceHierarchy ih;

    // Fully qualified paths
    case (cache,ih,cdecls,Absyn.FULLYQUALIFIED(path))
      equation
        (cache,env,ih) = instantiateFunctionImplicit(cache,ih,cdecls,path);
      then
        (cache,env,ih);

    case (cache,ih,{},cr)
      equation
        Error.addMessage(Error.NO_CLASSES_LOADED, {});
      then
        fail();

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.IDENT(name = name2))) /* top level class */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,_) = instClassDecls(cache, env, ih, cdecls, path);
        (cache,env_2,ih) = instFunctionInProgramImplicit(cache, env_1, ih, cdecls, path);
      then
        (cache,env_2,ih);

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.QUALIFIED(name = name))) /* class in package */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,_) = instClassDecls(cache, env, ih, cdecls, path);
        (cache,(cdef as SCode.CLASS(name = n)),env_2) = Lookup.lookupClass(cache,env_1, path, true);
        env_2 = Env.extendFrameC(env_2, cdef);
        (cache,env,ih) = implicitFunctionInstantiation(cache, env_2, ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, cdef, {});
      then
        (cache,env,ih);

    case (_,_,_,path)
      equation
        //print("-instantiateFunctionImplicit ");print(Absyn.pathString(path));print(" failed\n");
        true = RTOpts.debugFlag("failtrace");
        Debug.fprint("failtrace", "-Inst.instantiateFunctionImplicit " +& Absyn.pathString(path) +& " failed\n");
      then
        fail();
  end matchcontinue;
end instantiateFunctionImplicit;

protected function instClassInProgram
"function: instClassInProgram
  Instantitates a specifc class in a Program.
  The class must reside on top level."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outEnv,outIH,outDae) := matchcontinue (inCache,inEnv,inIH,inProgram,inPath)
    local
      DAE.DAElist dae;
      list<Env.Frame> env_1,env;
      SCode.Element c;
      String name,name2;
      list<SCode.Element> cs;
      Absyn.Path path;
      Env.Cache cache;
      InstanceHierarchy ih;
      ConnectionGraph.ConnectionGraph graph;

    // The class and the path match => instantiate the class.
    case (cache,env,ih,((c as SCode.CLASS(name = name)) :: cs),Absyn.IDENT(name = name2))
      equation
        true = stringEq(name, name2);
        (cache,env_1,ih,_,dae,_,_,_,_,graph) = instClass(cache,env, ih,
          UnitAbsynBuilder.emptyInstStore(), DAE.NOMOD(), Prefix.NOPRE(),
            Connect.emptySet, c, {}, false, TOP_CALL(), ConnectionGraph.EMPTY) "impl" ;
        // deal with Overconstrained connections
        dae = ConnectionGraph.handleOverconstrainedConnections(graph, dae, name);

        //print(" ********************** backpatch 2 **********************\n");
        dae = reEvaluateInitialIfEqns(cache,env_1,dae,true);
        
        // check the models for balancing
        //Debug.fcall2("checkModel",checkModelBalancing,SOME(inPath),dae);
      then
        (cache,env_1,ih,dae);

    // The class does not match the path, and no more classes left => error.
    case (cache,env,ih,((c as SCode.CLASS(name = name)) :: {}),(path as Absyn.IDENT(name = name2)))
      equation
        false = stringEq(name, name2);
        false = stringEq(name2, "");
        Error.addMessage(Error.LOAD_MODEL_ERROR, {name2});
      then
        fail();
        
    // The class does not match the path, but there are more classes left => continue searching for a matching class.
    case (cache,env,ih,((c as SCode.CLASS(name = name)) :: cs),(path as Absyn.IDENT(name = name2)))
      equation
        false = stringEq(name, name2);
        _::_ = cs; // non empty list 
        (cache,env,ih,dae) = instClassInProgram(cache, env, ih, cs, path);
      then
        (cache,env,ih,dae);

    case (cache,env,ih,{},_) 
      then (cache,env,ih,DAEUtil.emptyDae);
    
    case (cache,env,ih,_,_)
      equation
        Debug.fprintln("failtrace", "Inst.instClassInProgram failed");
      then fail();
  end matchcontinue;
end instClassInProgram;

protected function instClassInProgramImplicit
"function: instClassInProgramImplicit
  Instantitates a specifc class in a Program using implicit instatiation.
  The class must reside on top level."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outEnv,outIH,outDae) := matchcontinue (inCache,inEnv,inIH,inProgram,inPath)
    local
      list<Env.Frame> env_1,env;
      DAE.DAElist dae;
      SCode.Element c;
      String name,name2;
      list<SCode.Element> cs;
      Absyn.Path path;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,env,ih,((c as SCode.CLASS(name = name)) :: cs),Absyn.IDENT(name = name2))
      equation
        true = stringEq(name, name2);
        env = Env.extendFrameC(env, c);
        (cache,env_1,ih,dae) = implicitInstantiation(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {}) ;
      then
        (cache,env_1,ih,dae);

    case (cache,env,ih,((c as SCode.CLASS(name = name)) :: cs),(path as Absyn.IDENT(name = name2)))
      equation
        false = stringEq(name, name2);
        (cache,env,ih,dae) = instClassInProgramImplicit(cache, env, ih, cs, path);
      then
        (cache,env,ih,dae);

    case (cache,env,ih,{},_) 
      then (cache,env,ih,DAEUtil.emptyDae);

    case (_,env,ih,_,_)
      equation
        Debug.fprint("failtrace", "Inst.instClassInProgramImplicit failed");
      then fail();
  end matchcontinue;
end instClassInProgramImplicit;

protected function instFunctionInProgramImplicit
"function: instFunctionInProgramImplicit
  Instantitates a specific function in a Program using implicit instatiation.
  The class must reside on top level."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outCache,outEnv,outIH) := matchcontinue (inCache,inEnv,inIH,inProgram,inPath)
    local
      list<Env.Frame> env_1,env;
      SCode.Element c;
      String name1,name2;
      list<SCode.Element> cs;
      Absyn.Path path;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),Absyn.IDENT(name = name2))
      equation
        true = stringEq(name1, name2);
        env = Env.extendFrameC(env, c);
        (cache,env_1,ih) = implicitFunctionInstantiation(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {});
      then
        (cache,env_1,ih);

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),(path as Absyn.IDENT(name = name2)))
      equation
        false = stringEq(name1, name2);
        (cache,env,ih) = instFunctionInProgramImplicit(cache,env,ih, cs, path);
      then
        (cache,env,ih);

    case (cache,env,ih,{},_) then (cache,env,ih);
    case (cache,env,ih,_,_)  then fail();
  end matchcontinue;
end instFunctionInProgramImplicit;

protected function instClassDecls
"function: instClassDecls
  This function instantiated class definitions, i.e.
  adding the class definitions to the environment.
  See also partialInstClassIn."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outEnv,outIH,outDae) := matchcontinue (inCache,inEnv,inIH,inProgram,inPath)
    local
      list<Env.Frame> env_1,env_2,env;
      DAE.DAElist dae1,dae2,dae;
      SCode.Element c;
      String name1,name2;
      list<SCode.Element> cs;
      Absyn.Path ref;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),(ref as Absyn.IDENT(name = name2)))
      equation
        false = stringEq(name1, name2);
        (cache,env_1,ih,dae1) = instClassDecl(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {}) ;
        (cache,env_2,ih,dae2) = instClassDecls(cache,env_1,ih, cs, ref);
        dae = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,env_2,ih,dae);

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),(ref as Absyn.IDENT(name = name2)))
      equation
        true = stringEq(name1, name2);
        (cache,env_1,ih,dae2) = instClassDecls(cache,env,ih, cs, ref);
      then
        (cache,env_1,ih,dae2);

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),(ref as Absyn.QUALIFIED(name = name2)))
      equation
        true = stringEq(name1, name2);
        (cache,env_1,ih,dae1) = instClassDecl(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {});
        (cache,env_2,ih,dae2) = instClassDecls(cache,env_1,ih, cs, ref);
        dae = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,env_2,ih,dae);

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),(ref as Absyn.QUALIFIED(name = name2)))
      equation
        false = stringEq(name1, name2);
        (cache,env_1,ih,dae1) = instClassDecl(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {})  ;
        (cache,env_2,ih,dae2) = instClassDecls(cache,env_1,ih, cs, ref);
        dae = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,env_2,ih,dae);

    case (cache,env,ih,{},_) then (cache,env,ih,DAEUtil.emptyDae);
    
    case (_,_,ih,_,ref)
      equation
        print("Inst.instClassDecls failed\n ref =" +& Absyn.pathString(ref) +& "\n");
      then
        fail();
  end matchcontinue;
end instClassDecls;

public function makeEnvFromProgram
"function: makeEnvFromProgram
  This function takes a SCode.Program and builds
  an environment, excluding the class in A1."
  input Env.Cache inCache;
  input SCode.Program prog;
  input SCode.Path c;
  output Env.Cache outCache;
  output Env.Env env_1;
protected
  list<Env.Frame> env;
  Env.Cache cache;
algorithm
  (cache,env) := Builtin.initialEnv(inCache);
  (outCache,env_1,_) := addProgramToEnv(cache,env,InnerOuter.emptyInstHierarchy, prog, c);
end makeEnvFromProgram;

public function makeSimpleEnvFromProgram
"function: makeSimpleEnvFromProgram
  Similar as to makeEnvFromProgram, but not using the complete builtin
  environment, but a more simple one without the builtin operators.
  See also: Builtin.simpleInitialEnv."
  input Env.Cache inCache;
  input SCode.Program prog;
  input SCode.Path c;
  output Env.Cache outCache;
  output Env.Env env_1;
  list<Env.Frame> env;
algorithm
  env := Builtin.simpleInitialEnv();
  (outCache,env_1,_) := addProgramToEnv(inCache,env,InnerOuter.emptyInstHierarchy, prog, c);
end makeSimpleEnvFromProgram;

protected function addProgramToEnv
"function: addProgramToEnv
  Adds all classes in a Program to the environment."
  input Env.Cache inCache;
  input Env.Env env;
  input InstanceHierarchy inIH;
  input SCode.Program p;
  input SCode.Path path;
  output Env.Cache outCache;
  output Env.Env env_1;
  output InstanceHierarchy outIH;
algorithm
  (outCache,env_1,outIH,_) := instClassDecls(inCache,env,inIH, p, path);
end addProgramToEnv;

protected function instProgram
"function: instProgram
  Instantiating a Modelica program is the same as instantiating the
  last class definition in the source file. First all the class
  definitions is added to the environment without modifications, and
  then the last class is instantiated in the function instClass.
  This is used when calling the compiler with a Modelica source code file.
  It is not used in the interactive environment when instantiating a class."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outIH,outDae) := match (inCache,inEnv,inIH,inProgram)
    local
      list<Env.Frame> env,env_1;
      DAE.DAElist dae,dae1,dae2;
      Connect.Sets csets;
      SCode.Element c;
      String n;
      list<SCode.Element> cs;
      Env.Cache cache;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      UnitAbsyn.InstStore store;
      Option<Absyn.Path> containedInOpt;
      DAE.ElementSource source "the origin of the element";
      list<DAE.Element> daeElts;
      SCode.ClassDef cdef;
      Option<SCode.Comment> comment;

    case (cache,env,ih,{})
      equation
        Error.addMessage(Error.NO_CLASSES_LOADED, {});
      then
        fail();

    case (cache,env,ih,{(c as SCode.CLASS(name = "OpenModelica"))}) /* Ignore ModelicaBuiltin.mo */
      equation
        Error.addMessage(Error.NO_CLASSES_LOADED, {});
      then fail();

    case (cache,env,ih,{(c as SCode.CLASS(name = n, classDef = cdef))})
      equation
        // Debug.fprint("insttr", "inst_program1: ");
        // Debug.fprint("insttr", n);
        // Debug.fprintln("insttr", "");
        containedInOpt = Env.getEnvPath(env);
        (cache,env_1,ih,store,dae,csets,_,_,_,graph) =
          instClass(cache,env,ih,UnitAbsynBuilder.emptyInstStore(), DAE.NOMOD(),
            Prefix.NOPRE(), Connect.emptySet, c, {}, false, TOP_CALL(), ConnectionGraph.EMPTY) ;
        Debug.execStat("instClass done",RT_CLOCK_EXECSTAT_MAIN);
        // deal with Overconstrained connections
        dae = ConnectionGraph.handleOverconstrainedConnections(graph, dae, n);
        //print(" ********************** backpatch 3 **********************\n");
        dae = reEvaluateInitialIfEqns(cache,env_1,dae,true);
        
        // check the models for balancing
        //Debug.fcall2("checkModel",checkModelBalancing,containedInOpt,dae);

        // set the source of this element
        source = DAEUtil.addElementSourcePartOfOpt(DAE.emptyElementSource, Env.getEnvPath(env));

        // finish with the execution statistics
        Debug.execStat("Instantiation done",RT_CLOCK_EXECSTAT_MAIN);

        daeElts = DAEUtil.daeElements(dae);
        comment = extractClassDefComment(cache, env, cdef);
        dae = DAE.DAE({DAE.COMP(n,daeElts,source,comment)});
      then
        (cache,ih,dae);

    case (cache,env,ih,(c :: (cs as (_ :: _))))
      equation
        // Debug.fprintln("insttr", "inst_program2");
        (cache,env_1,ih,dae1) = instClassDecl(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {}) ;
        //str = SCodeDump.printClassStr(c); print("------------------- CLASS instProgram-----------------\n");print(str);print("\n===============================================\n");
        //str = Env.printEnvStr(env_1);print("------------------- env instProgram 1-----------------\n");print(str);print("\n===============================================\n");
        (cache,ih,dae2) = instProgram(cache,env_1,ih, cs) "Env.extend_frame_c(env,c) => env\' &" ;
        dae = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,ih,dae);

    case (_,_,ih,_)
      equation
        //Debug.fprintln("failtrace", "- Inst.instProgram failed");
      then
        fail();

  end match;
end instProgram;

protected function instProgramImplicit
"function: instProgramImplicit
  Instantiates a program using implicit instantiation.
  Used when instantiating functions."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outEnv,outIH,outDae) := match (inCache,inEnv,inIH,inProgram)
    local
      list<Env.Frame> env_1,env_2,env;
      DAE.DAElist dae1,dae2,dae;
      SCode.Element c;
      String n;
      SCode.Restriction restr;
      list<SCode.Element> cs;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,env,ih,((c as SCode.CLASS(name = n,restriction = restr)) :: cs))
      equation
        // Debug.fprint("insttr", "inst_program_implicit: ");
        // Debug.fprint("insttr", n);
        // Debug.fprintln("insttr", "");
        env = Env.extendFrameC(env, c);
        (cache,env_1,ih,dae1) = implicitInstantiation(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {});
        (cache,env_2,ih,dae2) = instProgramImplicit(cache,env_1,ih, cs);
        dae = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,env_2,ih,dae);

    case (cache,env,ih,{})
      equation
        // Debug.fprintln("insttr", "Inst.instProgramImplicit (end)");
      then
        (cache,env,ih,DAEUtil.emptyDae);
  end match;
end instProgramImplicit;

public function instClass " function: instClass
  Instantiation of a class can be either implicit or normal.
  This function is used in both cases. When implicit instantiation
  is performed, the last argument is true, otherwise it is false.

  Instantiating a class consists of the following steps:
   o Create a new frame on the environment
   o Initialize the class inference state machine
   o Instantiate all the elements and equations
   o Generate equations from the connection sets built during instantiation"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input SCode.Element inClass;
  input InstDims inInstDims;
  input Boolean inBoolean;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache cache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output DAE.Type outType;
  output ClassInf.State outState;
  output Option<SCode.Attributes> optDerAttr;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (cache,outEnv,outIH,outStore,outDae,outSets,outType,outState,optDerAttr,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inMod,inPrefix,inSets,inClass,inInstDims,inBoolean,inCallingScope,inGraph)
    local
      list<Env.Frame> env,env_1,env_3;
      DAE.Mod mod;
      Prefix.Prefix pre;
      Connect.Sets csets,csets_1;
      String n;
      Boolean impl,callscope_1,isFn,notIsPartial,isPartialFn;
      SCode.Partial partialPrefix;
      SCode.Encapsulated encflag;
      ClassInf.State ci_state,ci_state_1;
      DAE.DAElist dae1,dae1_1,dae2,dae;
      list<DAE.Var> tys;
      Option<DAE.Type> bc_ty;
      Absyn.Path fq_class;
      DAE.Type ty;
      SCode.Element c;
      SCode.Restriction r;
      InstDims inst_dims;
      CallingScope callscope;
      Option<SCode.Attributes> oDA;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      DAE.EqualityConstraint equalityConstraint;
      Absyn.Info info;

    // adrpo: ONLY when running checkModel we should be able to instantiate partial classes
    case (cache,env,ih,store,mod,pre,csets,
          (c as SCode.CLASS(name=n, partialPrefix = SCode.PARTIAL(), info = info)),
          inst_dims,impl,callscope,graph)
      equation
        true = OptManager.getOption("checkModel");
        c = SCode.setClassPartialPrefix(SCode.NOT_PARTIAL(), c);
        // add a warning
        Error.addSourceMessage(Error.INST_PARTIAL_CLASS_CHECK_MODEL_WARNING, {n}, info);
        // call normal instantiation        
        (cache,env,ih,store,dae,csets,ty,ci_state_1,oDA,graph) =
           instClass(inCache, inEnv, inIH, store, inMod, inPrefix, inSets, c, inInstDims, inBoolean, inCallingScope, inGraph);
      then
        (cache,env,ih,store,dae,csets,ty,ci_state_1,oDA,graph);
       
    /* Instantiation of a class. Create new scope and call instClassIn.
     *  Then generate equations from connects.
     */
    case (cache,env,ih,store,mod,pre,csets,
          (c as SCode.CLASS(name = n,encapsulatedPrefix = encflag,restriction = r, partialPrefix = partialPrefix)),
          inst_dims,impl,callscope,graph)
      equation
        //print("---- CLASS: "); print(n);print(" ----\n"); print(SCodeDump.printClassStr(c)); //Print out the input SCode class
        //str = SCodeDump.printClassStr(c); print("------------------- CLASS instClass-----------------\n");print(str);print("\n===============================================\n");

        // First check if the class is non-partial or a partial function
        isFn = SCode.isFunctionOrExtFunction(r);
        notIsPartial = not SCode.partialBool(partialPrefix);
        isPartialFn = isFn and SCode.partialBool(partialPrefix);
        true = notIsPartial or isPartialFn;

        env_1 = Env.openScope(env, encflag, SOME(n), Env.restrictionToScopeType(r));

        ci_state = ClassInf.start(r,Env.getEnvName(env_1));
        (cache,env_3,ih,store,dae1,csets_1,ci_state_1,tys,bc_ty,oDA,equalityConstraint, graph)
          = instClassIn(cache, env_1, ih, store, mod, pre, csets, ci_state, c, SCode.PUBLIC(), inst_dims, impl, callscope, graph, NONE());
        (cache,fq_class) = makeFullyQualified(cache,env, Absyn.IDENT(n));
        //str = Absyn.pathString(fq_class); print("------------------- CLASS makeFullyQualified instClass-----------------\n");print(n); print("  ");print(str);print("\n===============================================\n");
        
        // is top level?
        callscope_1 = isTopCall(callscope);
        
        dae1_1 = DAEUtil.addComponentType(dae1, fq_class);
        
        reportUnitConsistency(callscope_1,store);
        //print("in class ");print(n);print(" generate equations for sets:");print(ConnectUtil.printSetsStr(csets_1));print("\n");
        //InnerOuter.checkMissingInnerDecl(dae1_1,callscope_1);
        (csets_1,_) = InnerOuter.retrieveOuterConnections(cache,env_3,ih,pre,csets_1,callscope_1);
        //print("updated sets: ");print(ConnectUtil.printSetsStr(csets_1));print("\n");
                
        // adrpo 2010-08-30: handle here the actualStream and inStream operators
        // dae1_1 = handleStreamConnectors(pre, csets_1, dae1_1);
        //print(Debug.bcallret1(callscope_1, ConnectUtil.printSetsStr, csets_1, ""));
        dae2 = Debug.bcallret1(callscope_1, ConnectUtil.equations, csets_1, DAEUtil.emptyDae);
        
        dae = DAEUtil.joinDaes(dae1_1, dae2);
        dae = handleStreamConnectors(callscope_1, csets_1, dae);

        ty = mktype(fq_class, ci_state_1, tys, bc_ty, equalityConstraint, c);
        // update Enumerationtypes in environment
        // (cache,env_4) = updateEnumerationEnvironment(cache,env_3,ty,c,ci_state_1);
        // print("\n---- DAE ----\n"); DAE.printDAE(DAE.DAE(dae));  //Print out flat modelica
        // dae = InnerOuter.renameUniqueVarsInTopScope(callscope_1,dae);
        dae = updateDeducedUnits(callscope_1,store,dae);

        // Fixes partial functions.
        ty = fixInstClassType(ty,isPartialFn);
      then
        (cache,env_3,ih,store,dae,csets_1,ty,ci_state_1,oDA,graph);

      /*  Classes with the keyword partial can not be instantiated. They can only be inherited */
    case (cache,env,ih,store,mod,pre,csets,SCode.CLASS(name = n,partialPrefix = SCode.PARTIAL(), info = info),_,(impl as false),_,graph)
      equation
        Error.addSourceMessage(Error.INST_PARTIAL_CLASS, {n}, info);
      then
        fail();

    case (_,_,ih,_,_,_,_,SCode.CLASS(name = n),_,impl,_,graph)
      equation
        Debug.fprintln("failtrace", "- Inst.instClass: " +& n +& " failed");
      then
        fail();
  end matchcontinue;
end instClass;

protected function fixInstClassType
"Fixes the type of a class if it is uniontype or function reference.
These are MetaModelica extensions."
  input DAE.Type ty;
  input Boolean isPartialFn;
  output DAE.Type outType;
algorithm
  outType := matchcontinue (ty,isPartialFn)
    local
      String name;
    case ((_,SOME(Absyn.FULLYQUALIFIED(Absyn.QUALIFIED("OpenModelica",Absyn.QUALIFIED("Code",Absyn.IDENT(name)))))),_)
      then Util.assoc(name,{
        ("TypeName",(DAE.T_CODE(DAE.C_TYPENAME()),NONE())),
        ("VariableName",(DAE.T_CODE(DAE.C_VARIABLENAME()),NONE())),
        ("VariableNames",(DAE.T_CODE(DAE.C_VARIABLENAMES()),NONE()))
        });
    case (ty,false) then ty;
    case (ty,true) then Types.makeFunctionPolymorphicReference(ty);
  end matchcontinue;
end fixInstClassType;

protected function updateEnumerationEnvironment
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Type inType;
  input SCode.Element inClass;
  input ClassInf.State inCi_State;
  output Env.Cache outCache;
  output Env.Env outEnv;
algorithm
  (outCache,outEnv) := matchcontinue(inCache,inEnv,inType,inClass,inCi_State)
    local
      Env.Cache cache;
      Env.Env env,env_1;
      DAE.Type ty;
      SCode.Element c;
      list<String> names;
      list<DAE.Var> vars;
      Absyn.Path p,pname;
    
    case (cache,env,ty as ((DAE.T_ENUMERATION(names = names, literalVarLst = vars)),SOME(p)),c,ClassInf.ENUMERATION(pname))
      equation
        (cache,env_1) = updateEnumerationEnvironment1(cache,env,Absyn.pathString(pname),names,vars,p);
      then
       (cache,env_1);
    
    case (cache,env,ty,c,_) then (cache,env);
  
  end matchcontinue;
end updateEnumerationEnvironment;

protected function updateEnumerationEnvironment1
"update enumeration value in environment" 
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Absyn.Ident inName;
  input list<String> inNames;
  input list<DAE.Var> inVars;
  input Absyn.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
algorithm
  (outCache,outEnv) := match(inCache,inEnv,inName,inNames,inVars,inPath)
    local
      Env.Cache cache;
      Env.Env env,env_1,env_2,compenv;
      String name,nn;
      list<String> names;
      list<DAE.Var> vars;
      DAE.Var var,  new_var;
      DAE.Type ty;
      Option<tuple<SCode.Element, DAE.Mod>> outTplSCodeElementTypesModOption;
      Env.InstStatus instStatus;
      Absyn.Path p;
      DAE.Attributes attributes;
      SCode.Visibility visibility;
      DAE.Binding binding;
      Option<DAE.Const> cnstOpt;
    
    case (cache,env,name,nn::names,(var as DAE.TYPES_VAR(_,_,_,ty,_,_))::vars,p) 
      equation
        // get Var
        (cache,DAE.TYPES_VAR(name,attributes,visibility,_,binding,cnstOpt),outTplSCodeElementTypesModOption,instStatus,compenv) = Lookup.lookupIdentLocal(cache, env, nn);
        // print("updateEnumerationEnvironment1 -> component: " +& name +& " ty: " +& Types.printTypeStr(ty) +& "\n");
        // change type
        new_var = DAE.TYPES_VAR(name,attributes,visibility,ty,binding,cnstOpt);
        // update
         env_1 = Env.updateFrameV(env, new_var, Env.VAR_DAE(), compenv)  ;
        // next
        (cache,env_2) = updateEnumerationEnvironment1(cache,env_1,name,names,vars,p);
      then
       (cache,env_2);
    case (cache,env,_,{},_,_) then (cache,env);
  end match;
end updateEnumerationEnvironment1;

protected function updateDeducedUnits "updates the deduced units in each DAE.VAR"
  input Boolean callScope;
  input UnitAbsyn.InstStore store;
  input DAE.DAElist dae;
  output DAE.DAElist outDae;
algorithm
  outDae := matchcontinue(callScope,store,dae)
    local
      HashTable.HashTable ht;
      Integer indx;
      array<Option<UnitAbsyn.Unit>> vec;
      String unitStr;
      UnitAbsyn.Unit unit;
      Option<DAE.VariableAttributes> varOpt;
      DAE.Element elt,v;
      list<DAE.Element> elts;
    case(false,_,dae) then dae;

      /* Only traverse on top scope */
    case(true,store as UnitAbsyn.INSTSTORE(UnitAbsyn.STORE(vec,_),ht,_),DAE.DAE((v as DAE.VAR(variableAttributesOption=varOpt as SOME(DAE.VAR_ATTR_REAL(unit = NONE()))))::elts)) equation
      indx = BaseHashTable.get(DAEUtil.varCref(v),ht);
      SOME(unit) = vec[indx];
      unitStr = UnitAbsynBuilder.unit2str(unit);
      varOpt = DAEUtil.setUnitAttr(varOpt,DAE.SCONST(unitStr));
      v = DAEUtil.setVariableAttributes(v,varOpt);
      DAE.DAE(elts) = updateDeducedUnits(true,store,DAE.DAE(elts));
      then DAE.DAE(v::elts);
        
    case(true,store,DAE.DAE(elt::elts)) equation
      DAE.DAE(elts) = updateDeducedUnits(true,store,DAE.DAE(elts));
    then DAE.DAE(elt::elts);
    case(true,store,DAE.DAE({})) then DAE.DAE({});

  end matchcontinue;
end updateDeducedUnits;

protected function reportUnitConsistency "reports CONSISTENT or INCOMPLETE error message depending on content of store"
  input Boolean topScope;
  input UnitAbsyn.InstStore store;
algorithm
  _ := matchcontinue(topScope,store)
  local Boolean complete; UnitAbsyn.Store st;
    case(_,_) equation
      false = OptManager.getOption("unitChecking");
    then ();
    case(true,UnitAbsyn.INSTSTORE(st,_,SOME(UnitAbsyn.CONSISTENT()))) equation
      (complete,_) = UnitChecker.isComplete(st);
      Error.addMessage(Util.if_(complete,Error.CONSISTENT_UNITS,Error.INCOMPLETE_UNITS),{});
    then();
    case(_,_) then ();

  end matchcontinue;
end reportUnitConsistency;

protected function extractConnectorPrefix "
Author: BZ, 2009-09
Extract the part before the conector ex: a.b.c.connector_d.e would return a.b.c
"
input DAE.ComponentRef connectorRef;
output DAE.ComponentRef prefixCon;
algorithm prefixCon := matchcontinue(connectorRef)
  local
    DAE.ComponentRef child;
    String name;
    list<DAE.Subscript> subs;
    DAE.ExpType ty;

  case(DAE.CREF_IDENT(name,_,_)) // If the bottom var is a connector, then it is not an outside connector. (spec 0.1.2)
    /*equation print(name +& " is not a outside connector \n");*/
    then fail();

  case(DAE.CREF_QUAL(name,(ty as DAE.ET_COMPLEX(complexClassType=ClassInf.CONNECTOR(_,_))),subs,_))
    then ComponentReference.makeCrefIdent(name,ty,subs);

  case(DAE.CREF_QUAL(name,ty,subs,child))
    equation
      child = extractConnectorPrefix(child);
    then
      ComponentReference.makeCrefQual(name,ty,subs,child);

end matchcontinue;
end extractConnectorPrefix;

protected function updateTypesInUnconnectedConnectors "
Author: BZ, 2009-09
Given a set of zeroequations (unconnected flow variables) and the subset dae containing flow-variable declaration:
Set same type to variable as the equations have.
Note: This is a hack to readd the typing of the variables.
"
  input DAE.DAElist zeroEqnDae;
  input DAE.DAElist fullDae;
  output DAE.DAElist outdae;
algorithm outdae := matchcontinue(zeroEqnDae,fullDae)
  local
    DAE.Element ze;
    DAE.Exp e;
    DAE.ComponentRef cr;
    list<DAE.Element> zeroEqns;
    DAE.FunctionTree funcs;
  
  case(DAE.DAE({}),fullDae) then fullDae;
  
  case(_, DAE.DAE({})) equation print(" error in updateTypesInUnconnectedConnectors\n"); then fail();
  
  case(DAE.DAE((ze as DAE.EQUATION(exp = (e as DAE.CREF(cr,_))))::zeroEqns), fullDae)
    equation
      //print(ComponentReference.printComponentRefStr(cr));
      cr = extractConnectorPrefix(cr);
      //print(" ===> " +& ComponentReference.printComponentRefStr(cr) +& "\n");
      fullDae = updateTypesInUnconnectedConnectors2(cr,fullDae);
      fullDae = updateTypesInUnconnectedConnectors(DAE.DAE(zeroEqns),fullDae);
    then
      fullDae;
  
  case(DAE.DAE((ze as DAE.EQUATION(scalar = (e as DAE.CREF(cr,_))))::zeroEqns), fullDae)
    equation
      //print(ComponentReference.printComponentRefStr(cr));
      cr = extractConnectorPrefix(cr);
      //print(" ===> " +& ComponentReference.printComponentRefStr(cr) +& "\n");
      fullDae = updateTypesInUnconnectedConnectors2(cr,fullDae);
      fullDae = updateTypesInUnconnectedConnectors(DAE.DAE(zeroEqns),fullDae);
    then
      fullDae;
  
  case(DAE.DAE((ze as DAE.EQUATION(exp = (e as DAE.CREF(cr,_))))::zeroEqns), fullDae)
    equation
      failure(cr = extractConnectorPrefix(cr));
      //print("Var is not a outside connector: " +& ComponentReference.printComponentRefStr(cr));
      fullDae = updateTypesInUnconnectedConnectors(DAE.DAE(zeroEqns),fullDae);
    then
      fullDae;
  
  case(DAE.DAE((ze as DAE.EQUATION(scalar = (e as DAE.CREF(cr,_))))::zeroEqns), fullDae)
    equation
      failure(cr = extractConnectorPrefix(cr));
      //print("Var is not a outside connector: " +& ComponentReference.printComponentRefStr(cr));
      fullDae = updateTypesInUnconnectedConnectors(DAE.DAE(zeroEqns),fullDae);
    then
      fullDae;
  
  case(_,_) equation print(" ERROR -- updateTypesInUnconnectedConnectors\n"); then fail();
  
  end matchcontinue;
end updateTypesInUnconnectedConnectors;

protected function updateTypesInUnconnectedConnectors2 "
Author: BZ, 2009-09
Helper function for updateTypesInUnconnectedConnectors
"
input DAE.ComponentRef inCr;
input DAE.DAElist elems;
output DAE.DAElist outelems;
algorithm outelems := matchcontinue(inCr, elems)
  local
    DAE.ComponentRef cr1,cr2;
    DAE.Element elem,elem2;
    DAE.FunctionTree funcs;
    list<DAE.Element> elts;
  
  case(cr1,DAE.DAE({}))
    equation
      // print("error updateTypesInUnconnectedConnectors2\n");
      // print(" no match for: " +& ComponentReference.printComponentRefStr(cr1) +& "\n");
    then
      DAE.DAE({});
  
  case(inCr,DAE.DAE((elem2 as DAE.VAR(componentRef = cr2))::elts))
    equation
      true = ComponentReference.crefPrefixOf(inCr,cr2);
      //print(" Found: " +& ComponentReference.printComponentRefStr(cr2) +& "\n");
      cr1 = updateCrefTypesWithConnectorPrefix(inCr,cr2);
      elem = DAEUtil.replaceCrefInVar(cr1,elem2);
      //print(" replaced to: " ); print(DAE.dump2str(DAE.DAE({elem}))); print("\n");
      DAE.DAE(elts) = updateTypesInUnconnectedConnectors2(inCr, DAE.DAE(elts));
    then
      DAE.DAE(elem::elts);
  
  case(cr1,DAE.DAE(elem2::elts))
    equation
      DAE.DAE(elts) = updateTypesInUnconnectedConnectors2(cr1, DAE.DAE(elts));
    then
      DAE.DAE(elem2::elts);
  
  case(_,_) equation print(" ERROR updateTypesInUnconnectedConnectors2\n"); then fail();
  
  end matchcontinue;
end updateTypesInUnconnectedConnectors2;

protected function updateCrefTypesWithConnectorPrefix "
Author: BZ, 2009-09
Helper function for updateTypesInUnconnectedConnectors2
"
input DAE.ComponentRef cr1,cr2;
output DAE.ComponentRef outCref;
algorithm outCref := matchcontinue(cr1,cr2)
  local
    String name,name2;
    DAE.ComponentRef child,child2;
    DAE.ExpType ty;
    list<DAE.Subscript> subs;
  case(DAE.CREF_IDENT(name,ty,subs),DAE.CREF_QUAL(name2,_,_,child2))
    equation
      true = stringEq(name,name2);
    then
      ComponentReference.makeCrefQual(name,ty,subs,child2);

  case(DAE.CREF_QUAL(name,ty,subs,child),DAE.CREF_QUAL(name2,_,_,child2))
    equation
      true = stringEq(name,name2);
      outCref = updateCrefTypesWithConnectorPrefix(child,child2);
    then
      ComponentReference.makeCrefQual(name,ty,subs,outCref);
  case(cr1,cr2)
    equation
      print(" ***** FAILURE with " +& ComponentReference.printComponentRefStr(cr1) +& " _and_ " +& ComponentReference.printComponentRefStr(cr2) +& "\n");
      then
        fail();
  end matchcontinue;
end updateCrefTypesWithConnectorPrefix;

protected function instClassBasictype
"function: instClassBasictype
  author: PA
  This function instantiates a basictype class, e.g. Real, Integer, Real[2],
  etc. This function has the same functionality as instClass except that
  it will create array types when needed. (instClass never creates array
  types). This is needed because this function is used to instantiate classes
  extending from basic types. See instBasictypeBaseclass.
  NOTE: This function should only be called from instBasictypeBaseclass.
  This is new functionality in Modelica v 2.2."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input SCode.Element inClass;
  input InstDims inInstDims;
  input Boolean inImplicit;
  input CallingScope inCallingScope;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output DAE.Type outType;
  output list<DAE.Var>  outTypeVars "attributes of builtin types";
  output ClassInf.State outState;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outType,outTypeVars,outState):=
  match (inCache,inEnv,inIH,store,inMod,inPrefix,inSets,inClass,inInstDims,inImplicit,inCallingScope)
    local
      list<Env.Frame> env_1,env_3,env;
      ClassInf.State ci_state,ci_state_1;
      SCode.Element c_1,c;
      DAE.DAElist dae1,dae1_1,dae;
      Connect.Sets csets_1,csets;
      list<DAE.Var> tys;
      Option<DAE.Type> bc_ty;
      Absyn.Path fq_class;
      SCode.Encapsulated encflag;
      Boolean impl;
      DAE.Type ty;
      DAE.Mod mod;
      Prefix.Prefix pre;
      String n;
      SCode.Restriction r;
      InstDims inst_dims;
      CallingScope callscope;
      Env.Cache cache;
      InstanceHierarchy ih;
    
    case (cache,env,ih,store,mod,pre,csets,(c as SCode.CLASS(name = n,encapsulatedPrefix = encflag,restriction = r)),inst_dims,impl,callscope) /* impl */
      equation
        env_1 = Env.openScope(env, encflag, SOME(n), Env.restrictionToScopeType(r));
        ci_state = ClassInf.start(r, Env.getEnvName(env_1));
        c_1 = SCode.classSetPartial(c, SCode.NOT_PARTIAL());
        (cache,env_3,ih,store,dae1,csets_1,ci_state_1,tys,bc_ty,_,_,_)
        = instClassIn(cache, env_1, ih, store, mod, pre, csets, ci_state, c_1, SCode.PUBLIC(), inst_dims, impl, INNER_CALL(), ConnectionGraph.EMPTY, NONE());
        (cache,fq_class) = makeFullyQualified(cache,env_3, Absyn.IDENT(n));
        dae1_1 = DAEUtil.addComponentType(dae1, fq_class);
        dae = dae1_1;
        ty = mktypeWithArrays(fq_class, ci_state_1, tys, bc_ty, c);
      then
        (cache,env_3,ih,store,dae,csets_1,ty,tys,ci_state_1);

    case (_,_,ih,_,_,_,_,SCode.CLASS(name = n),_,impl,_)
      equation
        //Debug.fprintln("failtrace", "- Inst.instClassBasictype: " +& n +& " failed");
      then
        fail();
    
  end match;
end instClassBasictype;

/*
public function instClassIn "
  This rule instantiates the contents of a class definition, with a new
  environment already setup.
  The *implicitInstantiation* boolean indicates if the class should be
  instantiated implicit, i.e. without generating DAE.
  The last option is a even stronger indication of implicit instantiation,
  used when looking up variables in packages. This must be used because
  generation of functions in implicit instanitation (according to
  *implicitInstantiation* boolean) can cause circular dependencies
  (e.g. if a function uses a constant in its body)"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input SCode.Element inClass;
  input SCode.Visbibility inVisiblity;
  input InstDims inInstDims;
  input Boolean implicitInstantiation;
  input ConnectionGraph.ConnectionGraph inGraph;
  input Option<DAE.ComponentRef> instSingleCref;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output Option<DAE.Type> outTypesTypeOption;
  output Option<SCode.Attributes> optDerAttr;
  output DAE.EqualityConstraint outEqualityConstraint;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inMod,inPrefix,inSets,inState,inClass,inVisiblity,inInstDims,implicitInstantiation,inGraph,instSingleCref)
    local
      Option<DAE.Type> bc;
      list<Env.Frame> env,env_1;
      DAE.Mod mods;
      Prefix.Prefix pre;
      list<DAE.ComponentRef> crs;
      ClassInf.State ci_state,ci_state_1;
      SCode.Element c,cls;
      InstDims inst_dims;
      Boolean impl;
      SCode.Visibility vis;
      String clsname,implstr,n;
      DAE.DAElist dae;
      Connect.Sets csets_1,csets;
      list<DAE.Var> tys;
      SCode.Restriction r,rCached;
      SCode.ClassDef d;
      Env.Cache cache;
      list<DAE.ComponentRef> dc;
      Real t1,t2,time; Boolean b;
      list<Connect.OuterConnect> oc;
      Option<SCode.Attributes> oDA;
      DAE.EqualityConstraint equalityConstraint;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      InstHashTable instHash;
      tuple<Env.Cache, Env, InstanceHierarchy, UnitAbsyn.InstStore, DAE.Mod, Prefix.Prefix,
            Connect.Sets, ClassInf.State, SCode.Element, Boolean, InstDims, Boolean,
            ConnectionGraph.ConnectionGraph, Option<DAE.ComponentRef>> inputs;
      tuple<Env, DAE.DAElist, Connect.Sets, ClassInf.State, list<DAE.Var>, Option<DAE.Type>,
            Option<SCode.Attributes>, DAE.EqualityConstraint> outputs;
      Absyn.Path fullEnvPathPlusClass;
      Option<Absyn.Path> envPathOpt;
      String className, str1, str2;

      DAE.Mod aa_1;
      Prefix.Prefix aa_2;
      Connect.Sets aa_3;
      ClassInf.State aa_4;
      SCode.Element aa_5;
      Boolean aa_6;
      InstDims aa_7;
      Boolean aa_8;
      Option<DAE.ComponentRef> aa_9;
      replaceable type Type_a subtypeof Any;
      Type_a bbx, bby;
      CachedInstItem partialFunc;
      Real t1, t2, t;

    //case (cache,env,ih,store,mods,pre,csets,ci_state,c as SCode.CLASS(name=className),vis,inst_dims,impl,graph,instSingleCref)
    //  equation
    //    print("\n" +& Dump.indentStr(System.getTimerStackIndex()) +& "(" +& className);
    //    System.startTimer();
    //  then
    //  fail();

    case (cache,env,ih,store,mods,pre,csets,ci_state,c as SCode.CLASS(name=className),vis,inst_dims,impl,graph,instSingleCref)
      equation        
        (cache,env,ih,store,dae,csets,ci_state,tys,bc,oDA,equalityConstraint,graph) = instClassIn2(cache,env,ih,store,mods,pre,csets,ci_state,c,vis,inst_dims,impl,graph,instSingleCref);
        //System.stopTimer();
        //print("\n" +& Dump.indentStr(System.getTimerStackIndex()) +& " " +& className +& ": " +& realString(System.getTimerIntervalTime()) +& ")");
      then 
        (cache,env,ih,store,dae,csets,ci_state,tys,bc,oDA,equalityConstraint,graph);
    
    case (cache,env,ih,store,mods,pre,csets,ci_state,c as SCode.CLASS(name=className),vis,inst_dims,impl,graph,instSingleCref)
      equation
        //System.stopTimer();
        //print("\n" +& Dump.indentStr(System.getTimerStackIndex()) +& " FAILED: " +& className +& ": " +& realString(System.getTimerIntervalTime()) +& ")");
      then
        fail();
 end matchcontinue;
end instClassIn;
*/

public function instClassIn "
  This rule instantiates the contents of a class definition, with a new
  environment already setup.
  The *implicitInstantiation* boolean indicates if the class should be
  instantiated implicit, i.e. without generating DAE.
  The last option is a even stronger indication of implicit instantiation,
  used when looking up variables in packages. This must be used because
  generation of functions in implicit instanitation (according to
  *implicitInstantiation* boolean) can cause circular dependencies
  (e.g. if a function uses a constant in its body)"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input SCode.Element inClass;
  input SCode.Visibility inVisibility;
  input InstDims inInstDims;
  input Boolean implicitInstantiation;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  input Option<DAE.ComponentRef> instSingleCref;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output Option<DAE.Type> outTypesTypeOption;
  output Option<SCode.Attributes> optDerAttr;
  output DAE.EqualityConstraint outEqualityConstraint;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inMod,inPrefix,inSets,inState,inClass,inVisibility,inInstDims,implicitInstantiation,inCallingScope,inGraph,instSingleCref)
    local
      Option<DAE.Type> bc;
      list<Env.Frame> env;
      DAE.Mod mods;
      Prefix.Prefix pre;
      ClassInf.State ci_state;
      SCode.Element c;
      InstDims inst_dims;
      Boolean impl;
      SCode.Visibility vis;
      String n;
      DAE.DAElist dae;
      Connect.Sets csets_1,csets;
      list<DAE.Var> tys;
      SCode.Restriction r,rCached;
      SCode.ClassDef d;
      Env.Cache cache;
      Option<SCode.Attributes> oDA;
      DAE.EqualityConstraint equalityConstraint;
      CallingScope callscope;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      InstHashTable instHash;
      tuple<Env.Cache, Env.Env, InstanceHierarchy, UnitAbsyn.InstStore, DAE.Mod, Prefix.Prefix,
            Connect.Sets, ClassInf.State, SCode.Element, SCode.Visibility, InstDims, Boolean,
            ConnectionGraph.ConnectionGraph, Option<DAE.ComponentRef>> inputs;
      tuple<Env.Env, DAE.DAElist,
            Connect.Sets, ClassInf.State, list<DAE.Var>, Option<DAE.Type>,
            Option<SCode.Attributes>, DAE.EqualityConstraint, ConnectionGraph.ConnectionGraph 
            > outputs;
      Absyn.Path fullEnvPathPlusClass;
      Option<Absyn.Path> envPathOpt;
      String className;

      DAE.Mod aa_1;
      Prefix.Prefix aa_2;
      Connect.Sets aa_3;
      ClassInf.State aa_4;
      SCode.Element aa_5;
      InstDims aa_7;
      Boolean aa_8;
      Option<DAE.ComponentRef> aa_9;
      tuple<InstDims,Boolean,DAE.Mod,Connect.Sets,ClassInf.State,SCode.Element,Option<DAE.ComponentRef>> bbx, bby;
      ConnectionGraph.ConnectionGraph graphCached;

    /* Partial packages can sometimes be instantiated here, but should really be done in partialInstClass, since
     * it filters out a lot of things. */
    case (cache,env,ih,store,mods,pre,csets,ci_state,
      c as SCode.CLASS(restriction = SCode.R_PACKAGE(), partialPrefix = SCode.PARTIAL()),
      vis,inst_dims,impl,_,graph,instSingleCref)
      equation
        (cache,env,ih,ci_state) = partialInstClassIn(cache, env, ih, mods, pre, csets, ci_state, c, vis, inst_dims);
      then 
        (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,{},NONE(),NONE(),NONE(),graph);
    
    /*  see if we have it in the cache */
    case (cache,env,ih,store,mods,pre,csets,ci_state,
      c as SCode.CLASS(name = className, restriction=r),
      vis,inst_dims,impl,_,graph,instSingleCref)
      equation
        false = RTOpts.debugFlag("noCache");
        instHash = getGlobalRoot(instHashIndex);
        envPathOpt = Env.getEnvPath(inEnv);
        fullEnvPathPlusClass = Absyn.selectPathsOpt(envPathOpt, Absyn.IDENT(className));
        {SOME(FUNC_instClassIn(inputs, outputs)),_} = BaseHashTable.get(fullEnvPathPlusClass, instHash);
        (_, _, _, _, aa_1, aa_2, aa_3, aa_4, aa_5 as SCode.CLASS(restriction=rCached), _, aa_7, aa_8, _, aa_9) = inputs;
        // are the important inputs the same??
        prefixEqualUnlessBasicType(aa_2, pre, c);
        bbx = (aa_7,      aa_8, aa_1, aa_3,  aa_4,     aa_5, aa_9);
        bby = (inst_dims, impl, mods, csets, ci_state, c,    instSingleCref);
        equality(bbx = bby);
        (env,dae,csets_1,ci_state,tys,bc,oDA,equalityConstraint,graphCached) = outputs;
        graph = ConnectionGraph.merge(graph, graphCached);
        /*
        Debug.fprintln("cache", "IIII->got from instCache: " +& Absyn.pathString(fullEnvPathPlusClass) +&
          "\n\tpre: " +& PrefixUtil.printPrefixStr(pre) +& " class: " +&  className +& 
          "\n\tmods: " +& Mod.printModStr(mods) +& 
          "\n\tenv: " +& Env.printEnvPathStr(inEnv) +&
          "\n\tsingle cref: " +& Expression.printComponentRefOptStr(instSingleCref) +&
          "\n\tdims: [" +& Util.stringDelimitList(Util.listMap1(inst_dims, DAEDump.unparseDimensions, true), ", ") +& "]" +& 
          "\n\tdae:\n" +& DAEDump.dump2str(dae));
        */
      then
        (inCache,env,ih,store,dae,csets_1,ci_state,tys,bc,oDA,equalityConstraint,graph);
    
    /* call the function and then add it in the cache */
    case (cache,env,ih,store,mods,pre,csets,ci_state,
      c as SCode.CLASS(restriction=r, name=className),
      vis,inst_dims,impl,callscope,graph,instSingleCref)
      equation
        //System.startTimer();
        (cache,env,ih,store,dae,csets,ci_state,tys,bc,oDA,equalityConstraint,graph) =
           instClassIn_dispatch(inCache,inEnv,inIH,store,inMod,inPrefix,inSets,inState,inClass,inVisibility,inInstDims,implicitInstantiation,callscope,inGraph,instSingleCref);
        
        envPathOpt = Env.getEnvPath(inEnv);
        fullEnvPathPlusClass = Absyn.selectPathsOpt(envPathOpt, Absyn.IDENT(className));
        
        inputs = (inCache,inEnv,inIH,store,inMod,inPrefix,inSets,inState,inClass,inVisibility,inInstDims,implicitInstantiation,inGraph,instSingleCref);
        outputs = (env,dae,csets,ci_state,tys,bc,oDA,equalityConstraint,graph);

        addToInstCache(fullEnvPathPlusClass,
           SOME(FUNC_instClassIn( // result for full instantiation
             inputs,
             outputs)),
           /*SOME(FUNC_partialInstClassIn( // result for partial instantiation
             (inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,inClass,inVisibility,inInstDims),
             (env,ci_state)))*/ NONE());
        /*
        Debug.fprintln("cache", "IIII->added to instCache: " +& Absyn.pathString(fullEnvPathPlusClass) +&
          "\n\tpre: " +& PrefixUtil.printPrefixStr(pre) +& " class: " +&  className +& 
          "\n\tmods: " +& Mod.printModStr(mods) +& 
          "\n\tenv: " +& Env.printEnvPathStr(inEnv) +&
          "\n\tsingle cref: " +& Expression.printComponentRefOptStr(instSingleCref) +&
          "\n\tdims: [" +& Util.stringDelimitList(Util.listMap1(inst_dims, DAEDump.unparseDimensions, true), ", ") +& "]" +& 
          "\n\tdae:\n" +& DAEDump.dump2str(dae));
        */
        //checkModelBalancingFilterByRestriction(r, envPathOpt, dae);
        //System.stopTimer();
        //_ = Database.query(0, "insert into Inst values(\"" +& Absyn.pathString(fullEnvPathPlusClass) +& "\", " +& realString(System.getTimerIntervalTime()) +& ");");
      then
        (cache,env,ih,store,dae,csets,ci_state,tys,bc,oDA,equalityConstraint,graph);

    // failure
    case (cache,env,ih,store,mods,pre,csets,ci_state,
      c as SCode.CLASS(name = n,restriction = r,classDef = d),
      vis,inst_dims,impl,_,graph,_)
      equation
        //print("instClassIn(");print(n);print(") failed\n");
        true = RTOpts.debugFlag("failtrace");
        Debug.fprintln("failtrace", "- Inst.instClassIn failed on class:" +&
           n +& " in environment: " +& Env.printEnvPathStr(env));
      then
        fail();
  end matchcontinue;
end instClassIn;

protected function checkClassEqual
  input SCode.Element c1;
  input SCode.Element c2;
  output Boolean areEqual;
algorithm
  areEqual := matchcontinue(c1, c2)
    local
      SCode.Restriction r;
      list<SCode.AlgorithmSection> normalAlgorithmLst1,normalAlgorithmLst2;
      list<SCode.AlgorithmSection> initialAlgorithmLst1,initialAlgorithmLst2;
      SCode.ClassDef cd1, cd2;
      
    // when +g=MetaModelica, check class equality!
    case (c1,c2)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        failure(equality(c1 = c2));
      then
        false;

    // check the types for equality!
    case (SCode.CLASS(restriction = SCode.R_TYPE()),_)
      equation
        failure(equality(c1 = c2));
      then
        false;

    // anything else but functions, do not check equality
    case (SCode.CLASS(restriction = r),_)
      equation
        failure(equality(r = SCode.R_FUNCTION()));
      then
        true;

    // check the class equality only for functions, made of parts
    case (SCode.CLASS(classDef=SCode.PARTS(normalAlgorithmLst=normalAlgorithmLst1, initialAlgorithmLst=initialAlgorithmLst1)),
          SCode.CLASS(classDef=SCode.PARTS(normalAlgorithmLst=normalAlgorithmLst2, initialAlgorithmLst=initialAlgorithmLst2)))
      equation
        // only check if algorithm list lengths are the same!
        true = intEq(listLength(normalAlgorithmLst1), listLength(normalAlgorithmLst2));
        true = intEq(listLength(initialAlgorithmLst1), listLength(initialAlgorithmLst2));
      then
        true;
    // check the class equality only for functions, made of derived
    case (SCode.CLASS(classDef=cd1 as SCode.DERIVED(typeSpec=_)),
          SCode.CLASS(classDef=cd2 as SCode.DERIVED(typeSpec=_)))
      equation
        // only check class definitions are the same!
        equality(cd1 = cd2);
      then
        true;
    // anything else, false!
    case (c1,c2) then false;
  end matchcontinue;
end checkClassEqual;

protected function prefixEqualUnlessBasicType
"Checks if two prefixes are equal, unless the class is a
 basic type, i.e. all reals, integers, enumerations with 
 the same name, etc. are equal."  
  input Prefix.Prefix pre1;
  input Prefix.Prefix pre2;
  input SCode.Element cls;
algorithm
  _ := match (pre1, pre2, cls)
    local

    // adrpo: TODO! FIXME!, I think here we should have pre1 = Prefix.CLASSPRE(variability1) == pre2 = Prefix.CLASSPRE(variability2) 

    // don't care about prefix for:
    // - enumerations
    // - types as they cannot have components    
    // - predefined types as they cannot have components
    case (_, _, SCode.CLASS(restriction = SCode.R_ENUMERATION())) then ();
    // case (_, _, SCode.CLASS(restriction = SCode.R_TYPE())) then ();
    case (_, _, SCode.CLASS(restriction = SCode.R_PREDEFINED_ENUMERATION())) then ();
    case (_, _, SCode.CLASS(restriction = SCode.R_PREDEFINED_INTEGER())) then ();
    case (_, _, SCode.CLASS(restriction = SCode.R_PREDEFINED_REAL())) then ();
    case (_, _, SCode.CLASS(restriction = SCode.R_PREDEFINED_STRING())) then ();
    case (_, _, SCode.CLASS(restriction = SCode.R_PREDEFINED_BOOLEAN())) then ();
    // don't care about prefix for:
    // - Real, String, Integer, Boolean
    case (_, _, SCode.CLASS(name = "Real")) then ();
    case (_, _, SCode.CLASS(name = "Integer")) then ();
    case (_, _, SCode.CLASS(name = "String")) then ();
    case (_, _, SCode.CLASS(name = "Boolean")) then ();
    
    // anything else, check for equality!
    case (pre1, pre2, _)
      equation
        equality(pre1 = pre2);
      then ();
  end match;
end prefixEqualUnlessBasicType;

public function instClassIn_dispatch
"function: instClassIn
  This rule instantiates the contents of a class definition, with a new
  environment already setup.
  The *implicitInstantiation* boolean indicates if the class should be
  instantiated implicit, i.e. without generating DAE.
  The last option is a even stronger indication of implicit instantiation,
  used when looking up variables in packages. This must be used because
  generation of functions in implicit instanitation (according to
  *implicitInstantiation* boolean) can cause circular dependencies
  (e.g. if a function uses a constant in its body)"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input SCode.Element inClass;
  input SCode.Visibility inVisibility;
  input InstDims inInstDims;
  input Boolean implicitInstantiation;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  input Option<DAE.ComponentRef> instSingleCref;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output Option<DAE.Type> outTypesTypeOption;
  output Option<SCode.Attributes> optDerAttr;
  output DAE.EqualityConstraint outEqualityConstraint;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inMod,inPrefix,inSets,inState,inClass,inVisibility,inInstDims,implicitInstantiation,inCallingScope,inGraph,instSingleCref)
    local
      Option<DAE.Type> bc;
      list<Env.Frame> env,env_1;
      DAE.Mod mods;
      Prefix.Prefix pre;
      ClassInf.State ci_state,ci_state_1;
      SCode.Element c,cls;
      InstDims inst_dims;
      Boolean impl;
      SCode.Visibility vis;
      String clsname,implstr,n;
      Connect.Sets csets_1,csets;
      list<DAE.Var> tys;
      SCode.Restriction r;
      SCode.ClassDef d;
      Env.Cache cache;
      Option<SCode.Attributes> oDA;
      CallingScope callscope;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      DAE.DAElist dae,dae1,dae1_1;
      Absyn.Info info;
      DAE.Type typ;
      list<Env.Frame> env_2, env_3;
      list<SCode.Element> els;
      list<tuple<SCode.Element, DAE.Mod>> comp;
      list<String> names;
      DAE.EqualityConstraint eqConstraint;
      DAE.Type ty, ty2;
      Absyn.Path fq_class;
      list<DAE.Var> tys1,tys2;
      SCode.Partial partialPrefix;
      SCode.Encapsulated encapsulatedPrefix;

    /*  Real class */
    case (cache,env,ih,store,mods,pre,csets, ci_state, 
        (c as SCode.CLASS(name = "Real",restriction = r,classDef = d)),vis,inst_dims,impl,_,graph,_)
      equation
        true = RTOpts.splitArrays();
        tys = instRealClass(cache,env,mods,pre,DAE.T_REAL_DEFAULT);
        bc = arrayBasictypeBaseclass(inst_dims, (DAE.T_REAL(tys),NONE()));
      then
        (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,tys,bc /* NONE() */,NONE(),NONE(),graph);

    /*  Real class, non-expanded arrays. Similar cases are needed for other built-in classes as well,
        I just want to make Reals work first */
    case (cache,env,ih,store,mods,pre,csets, ci_state, 
        (c as SCode.CLASS(name = "Real",restriction = r,classDef = d)),vis,inst_dims,impl,_,graph,_)
      equation
        false = RTOpts.splitArrays();
        typ = Types.liftArraySubscriptList(DAE.T_REAL_DEFAULT, Util.listFirst(inst_dims));
        tys = instRealClass(cache,env,mods,pre,typ);
        bc = arrayBasictypeBaseclass(inst_dims, (DAE.T_REAL(tys),NONE()));
      then
        (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,tys,bc /* NONE() */,NONE(),NONE(),graph);

    /* Integer class */
    case (cache,env,ih,store,mods,pre,csets,ci_state,
      (c as SCode.CLASS(name = "Integer",restriction = r,classDef = d)),vis,inst_dims,impl,_,graph,_)
      equation
        tys =  instIntegerClass(cache,env,mods,pre);
        bc = arrayBasictypeBaseclass(inst_dims, (DAE.T_INTEGER(tys),NONE()));
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,tys,bc /* NONE() */,NONE(),NONE(),graph);

    /* String class */
    case (cache,env,ih,store,mods,pre,csets, ci_state,
      (c as SCode.CLASS(name = "String",restriction = r,classDef = d)),vis,inst_dims,impl,_,graph,_)
      equation
        tys =  instStringClass(cache,env,mods,pre);
        bc = arrayBasictypeBaseclass(inst_dims, (DAE.T_STRING(tys),NONE()));
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,tys,bc /* NONE() */,NONE(),NONE(),graph);

    /* Boolean class */
    case (cache,env,ih,store,mods,pre,csets,ci_state,
      (c as SCode.CLASS(name = "Boolean",restriction = r,classDef = d)),vis,inst_dims,impl,_,graph,_)
      equation
        tys =  instBooleanClass(cache,env,mods,pre);
        bc = arrayBasictypeBaseclass(inst_dims, (DAE.T_BOOL(tys),NONE()));
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,tys,bc /* NONE() */,NONE(),NONE(),graph);

    // adrpo: 2010-09-27: here we do two things at once, but not correctly!
    // Instantiate enumeration class at top level Prefix.NOPRE() 
    //   when we are instantiating with no prefix, it means we are instantiating the enumeration class!
    //   and we don't care about modifications!
    // Instantiate enumeration VARIABLE with a prefix!  
    //   when we are instantiating with a prefix, it means we are instantiating a variable of an enumeration type!
    //   and we care about modifications!
    //   this does not work! 
    //   T = enumeration(x, y, z);
    //   T c(start = T.x) should generate an enumeration variable with and the type should contain the
    //                    start value, but we have no place to put it as the var list in the T_ENUMERATION is for names!
    case (cache,env,ih,store,mods,pre,csets, ci_state,
      (c as SCode.CLASS(name = n,restriction = SCode.R_ENUMERATION(),classDef = SCode.PARTS(elementLst = els),info = info)),vis,inst_dims,impl,callscope,graph,_)
      equation
        tys = instEnumerationClass(cache, env, mods, pre);
        /* uncomment this and see how checkAllModelsRecursive(Modelica.Electrical.Digital) looks like
           especially MUX.Or1.auxiliary doesn't get its start/fixed bindings
        print("Inst enumeration class (empty prefix) / variable (some pre): " +& n +&
          "\npre: " +& PrefixUtil.printPrefixStr(pre) +&
          "\nenv: " +& Env.printEnvPathStr(env) +&
          "\nmods: " +& Mod.printModStr(mods) +&
          "\ninst_dims: [" +& Util.stringDelimitList(Util.listMap1(inst_dims, DAEDump.unparseDimensions, true), ", ") +& "]" +& "\n");
        */
        ci_state_1 = ClassInf.trans(ci_state, ClassInf.NEWDEF());
        comp = addNomod(els);
        (cache,env_1,ih) = addComponentsToEnv(cache,env,ih, mods, pre, csets, ci_state_1, comp, comp, {}, inst_dims, impl);

        // we should instantiate with no modifications, they don't belong to the class, they belong to the component!
        (cache,env_2,ih,store,dae1,csets,ci_state_1,tys1,graph) = 
            instElementList(cache,env_1,ih,store, /* DAE.NOMOD() */ mods, pre, csets, ci_state_1, comp, inst_dims, impl,callscope,graph);
        
        (cache,fq_class) = makeFullyQualified(cache,env_2, Absyn.IDENT(n));
        eqConstraint = equalityConstraint(env_2, els, info);
        dae1_1 = DAEUtil.addComponentType(dae1, fq_class);
        names = SCode.componentNames(c);
        ty2 = (DAE.T_ENUMERATION(NONE(), fq_class, names, tys1, tys),NONE());
        bc = arrayBasictypeBaseclass(inst_dims, ty2);
        bc = Util.if_(Util.isSome(bc), bc, SOME(ty2));
        ty = mktype(fq_class, ci_state_1, tys1, bc, eqConstraint, c);
        // update Enumerationtypes in environment
        (cache,env_3) = updateEnumerationEnvironment(cache,env_2,ty,c,ci_state_1);
        tys2 = listAppend(tys, tys1); // <--- this is wrong as the tys belong to the component variable not the Enumeration Class!        
      then
        (cache,env_3,ih,store,DAEUtil.emptyDae,csets,ci_state_1,tys2,bc /* NONE() */,NONE(),NONE(),graph);

     /* Ignore functions if not implicit instantiation */
    case (cache,env,ih,store,mods,pre,csets,ci_state,cls,_,_,(impl as false),_,graph,_)
      equation
        true = SCode.isFunction(cls);
        clsname = SCode.className(cls);
        //print("Ignore function" +& clsname +& "\n");
      then
        (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,{},NONE(),NONE(),NONE(),graph);

    /* Instantiate a class definition made of parts */
    case (cache,env,ih,store,mods,pre,csets,ci_state,
          c as SCode.CLASS(name = n,restriction = r,classDef = d,info=info,partialPrefix = partialPrefix,encapsulatedPrefix = encapsulatedPrefix),
          vis,inst_dims,impl,callscope,graph,instSingleCref)
      equation
        false = isBuiltInClass(n) "If failed above, no need to try again";
        // Debug.fprint("insttr", "ICLASS [");
        implstr = Util.if_(impl, "impl] ", "expl] ");
        // Debug.fprint("insttr", implstr);
        // Debug.fprintln("insttr", Env.printEnvPathStr(env) +& "." +& n +& " mods: " +& Mod.printModStr(mods));
        // t1 = clock();
        (cache,env_1,ih,store,dae,csets_1,ci_state_1,tys,bc,oDA,eqConstraint,graph)
          = instClassdef(cache, env, ih, store, mods, pre, csets, ci_state, n, d, r, vis, partialPrefix, encapsulatedPrefix, inst_dims, impl, callscope, graph, instSingleCref, info);
        // t2 = clock();
        // time = t2 -. t1;
        // b=realGt(time,0.05);
        // s = realString(time);
        // Debug.fprintln("insttr", " -> ICLASS " +& n +& " inst time: " +& s +& " in env: " +& Env.printEnvPathStr(env) +& " mods: " +& Mod.printModStr(mods));
        cache = Env.addCachedEnv(cache,n,env_1);
      then
        (cache,env_1,ih,store,dae,csets_1,ci_state_1,tys,bc,oDA,eqConstraint,graph);

    // failure
    case (cache,env,ih,store,mods,pre,csets,ci_state,(c as SCode.CLASS(name = n,restriction = r,classDef = d)),vis,inst_dims,impl,_,graph,_)
      equation
        //print("instClassIn(");print(n);print(") failed\n");
        //Debug.fprintln("failtrace", "- Inst.instClassIn failed" +& n);
      then
        fail();
  end matchcontinue;
end instClassIn_dispatch;

public function isBuiltInClass "
Author: BZ, this function identifies built in classes."
  input String className;
  output Boolean b;
algorithm 
  b := matchcontinue(className)
    case("Real") then true;
    case("Integer") then true;
    case("String") then true;
    case("Boolean") then true;
    case(_) then false;
  end matchcontinue;
end isBuiltInClass;

protected constant DAE.Type stateSelectType = (DAE.T_ENUMERATION(NONE(),Absyn.IDENT(""),{"never","avoid","default","prefer","always"},
          {
          DAE.TYPES_VAR("never",DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),SCode.PUBLIC(),
             (DAE.T_ENUMERATION(SOME(1),Absyn.IDENT(""),{"never","avoid","default","prefer","always"},{},{}),NONE()),DAE.UNBOUND(),NONE()),
          DAE.TYPES_VAR("avoid",DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),SCode.PUBLIC(),
             (DAE.T_ENUMERATION(SOME(2),Absyn.IDENT(""),{"never","avoid","default","prefer","always"},{},{}),NONE()),DAE.UNBOUND(),NONE()),
          DAE.TYPES_VAR("default",DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),SCode.PUBLIC(),
             (DAE.T_ENUMERATION(SOME(3),Absyn.IDENT(""),{"never","avoid","default","prefer","always"},{},{}),NONE()),DAE.UNBOUND(),NONE()),
          DAE.TYPES_VAR("prefer",DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),SCode.PUBLIC(),
             (DAE.T_ENUMERATION(SOME(4),Absyn.IDENT(""),{"never","avoid","default","prefer","always"},{},{}),NONE()),DAE.UNBOUND(),NONE()),
          DAE.TYPES_VAR("always",DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),SCode.PUBLIC(),
             (DAE.T_ENUMERATION(SOME(5),Absyn.IDENT(""),{"never","avoid","default","prefer","always"},{},{}),NONE()),DAE.UNBOUND(),NONE())
          },{}),NONE());

protected function instRealClass
"function instRealClass
  Instantiation of the Real class"
  input Env.Cache cache;
  input Env.Env env;
  input DAE.Mod mods;
  input Prefix.Prefix pre;
  input DAE.Type inType "expected variable type; used for start, min and max in the case of non-expanded arrays";
  output list<DAE.Var> varLst;
algorithm
  varLst := matchcontinue(cache,env,mods,pre,inType)
    local
      SCode.Final f; 
      SCode.Each e; 
      list<DAE.SubMod> submods; 
      Option<DAE.EqMod> eqmod; 
      DAE.Exp exp;
      DAE.Var v; 
      DAE.Properties p;
      Option<Values.Value> optVal;
      DAE.Type ty;
      String s1;
      DAE.SubMod smod;
      DAE.Mod mym;
    
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("quantity",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"quantity",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("unit",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"unit",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("displayUnit",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"displayUnit",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("min",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        true = RTOpts.splitArrays();
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"min",optVal,exp,DAE.T_REAL_DEFAULT,p);
        then v::varLst;
    // min, the case of non-expanded arrays      
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("min",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        false = RTOpts.splitArrays();
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"min",optVal,exp,ty,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("max",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        true = RTOpts.splitArrays();
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"max",optVal,exp,DAE.T_REAL_DEFAULT,p);
        then v::varLst;
    // max, the case of non-expanded arrays      
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("max",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        false = RTOpts.splitArrays();
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"max",optVal,exp,ty,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("start",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        true = RTOpts.splitArrays();
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"start",optVal,exp,DAE.T_REAL_DEFAULT,p);
        then v::varLst;
    // start, the case of non-expanded arrays      
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("start",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        false = RTOpts.splitArrays();
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"start",optVal,exp,ty,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("fixed",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"fixed",optVal,exp,DAE.T_BOOL_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("nominal",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"nominal",optVal,exp,DAE.T_REAL_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("stateSelect",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre,ty)
      equation
        varLst = instRealClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre,ty);
        v = instBuiltinAttribute(cache,env,"stateSelect",optVal,exp,stateSelectType,p);
      then v::varLst;
    case(cache,env,( mym as DAE.MOD(f,e,smod::submods,eqmod)),pre,ty)
      equation
        s1 = Mod.prettyPrintSubmod(smod) +& ", not processed in the built-in class Real";
        Error.addMessage(Error.UNUSED_MODIFIER,{s1});
      then fail();
    case(cache,env,DAE.MOD(f,e,{},eqmod),pre,ty) then {};
    case(cache,env,DAE.NOMOD(),pre,ty) then {};
    case(cache,env,DAE.REDECL(_,_,_),pre,ty) then fail(); /*TODO, report error when redeclaring in Real*/
  end matchcontinue;
end instRealClass;

protected function instIntegerClass
"function instIntegerClass
  Instantiation of the Integer class"
  input Env.Cache cache;
  input Env.Env env;
  input DAE.Mod mods;
  input Prefix.Prefix pre;
  output list<DAE.Var> varLst;
algorithm
  varLst := matchcontinue(cache,env,mods,pre)
    local
      SCode.Final f; 
      SCode.Each e; 
      list<DAE.SubMod> submods; 
      Option<DAE.EqMod> eqmod; 
      DAE.Exp exp;
      DAE.Var v; 
      DAE.Properties p;
      Option<Values.Value> optVal;
      String s1;
      DAE.SubMod smod;
    
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("quantity",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instIntegerClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"quantity",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;

    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("min",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instIntegerClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"min",optVal,exp,DAE.T_INTEGER_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("max",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instIntegerClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"max",optVal,exp,DAE.T_INTEGER_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("start",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instIntegerClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"start",optVal,exp,DAE.T_INTEGER_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("fixed",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instIntegerClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"fixed",optVal,exp,DAE.T_BOOL_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("nominal",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instIntegerClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"nominal",optVal,exp,DAE.T_INTEGER_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,smod::submods,eqmod),pre)
      equation
        s1 = Mod.prettyPrintSubmod(smod) +& ", not processed in the built-in class Integer";
        Error.addMessage(Error.UNUSED_MODIFIER,{s1});
      then fail();
    case(cache,env,DAE.MOD(f,e,{},eqmod),pre) then {};
    case(cache,env,DAE.NOMOD(),pre) then {};
    case(cache,env,DAE.REDECL(_,_,_),pre) then fail(); /*TODO, report error when redeclaring in Real*/
  end matchcontinue;
end instIntegerClass;

protected function instStringClass
"function instStringClass
  Instantiation of the String class"
  input Env.Cache cache;
  input Env.Env env;
  input DAE.Mod mods;
  input Prefix.Prefix pre;
  output list<DAE.Var> varLst;
algorithm
  varLst := matchcontinue(cache,env,mods,pre)
    local 
      SCode.Final f; 
      SCode.Each e; 
      list<DAE.SubMod> submods; Option<DAE.EqMod> eqmod; DAE.Exp exp;
      DAE.Var v;
      DAE.Properties p;
      Option<Values.Value> optVal;
      String s1;
      DAE.SubMod smod;
    
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("quantity",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instStringClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"quantity",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("start",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instStringClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"start",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,smod::submods,eqmod),pre)
      equation
        s1 = Mod.prettyPrintSubmod(smod) +& ", not processed in the built-in class String";
        Error.addMessage(Error.UNUSED_MODIFIER,{s1});
      then fail();
    case(cache,env,DAE.MOD(f,e,{},eqmod),pre) then {};
    case(cache,env,DAE.NOMOD(),pre) then {};
    case(cache,env,DAE.REDECL(_,_,_),pre) then fail(); /*TODO, report error when redeclaring in Real*/
  end matchcontinue;
end instStringClass;

protected function instBooleanClass
"function instBooleanClass
  Instantiation of the Boolean class"
  input Env.Cache cache;
  input Env.Env env;
  input DAE.Mod mods;
  input Prefix.Prefix pre;
  output list<DAE.Var> varLst;
algorithm
  varLst := matchcontinue(cache,env,mods,pre)
    local
      SCode.Final f; 
      SCode.Each e; 
      list<DAE.SubMod> submods; 
      Option<DAE.EqMod> eqmod; 
      DAE.Exp exp;
      Option<Values.Value> optVal;
      DAE.Var v; 
      DAE.Properties p;
      String s1; 
      DAE.SubMod smod;
    
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("quantity",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instBooleanClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"quantity",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("start",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instBooleanClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"start",optVal,exp,DAE.T_BOOL_DEFAULT,p);
      then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("fixed",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instBooleanClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"fixed",optVal,exp,DAE.T_BOOL_DEFAULT,p);
      then v::varLst;
    case(cache,env,DAE.MOD(f,e,smod::submods,eqmod),pre)
      equation
        s1 = Mod.prettyPrintSubmod(smod) +& ", not processed in the built-in class Boolean";
        Error.addMessage(Error.UNUSED_MODIFIER,{s1});
      then fail();
    case(cache,env,DAE.MOD(f,e,{},eqmod),pre) then {};
    case(cache,env,DAE.NOMOD(),pre) then {};
    case(cache,env,DAE.REDECL(_,_,_),pre) then fail(); /*TODO, report error when redeclaring in Real*/
  end matchcontinue;
end instBooleanClass;

protected function instEnumerationClass
"function instEnumerationClass
  Instantiation of the Enumeration class"
  input Env.Cache cache;
  input Env.Env env;
  input DAE.Mod mods;
  input Prefix.Prefix pre;
  output list<DAE.Var> varLst;
algorithm
  varLst := matchcontinue(cache,env,mods,pre)
    local
      SCode.Final f;
      SCode.Each e;
      list<DAE.SubMod> submods;
      Option<DAE.EqMod> eqmod;
      DAE.Exp exp;
      Option<Values.Value> optVal;
      DAE.Var v;
      DAE.Properties p;
      String s1;
      DAE.SubMod smod;
    
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("quantity",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instEnumerationClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"quantity",optVal,exp,DAE.T_STRING_DEFAULT,p);
        then v::varLst;
   case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("min",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instEnumerationClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"min",optVal,exp,(DAE.T_ENUMERATION(NONE(),Absyn.IDENT(""),{},{},{}),NONE()),p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("max",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instEnumerationClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"max",optVal,exp,(DAE.T_ENUMERATION(NONE(),Absyn.IDENT(""),{},{},{}),NONE()),p);
        then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("start",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instEnumerationClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"start",optVal,exp,(DAE.T_ENUMERATION(NONE(),Absyn.IDENT(""),{},{},{}),NONE()),p);
      then v::varLst;
    case(cache,env,DAE.MOD(f,e,DAE.NAMEMOD("fixed",DAE.MOD(_,_,_,SOME(DAE.TYPED(exp,optVal,p,_))))::submods,eqmod),pre)
      equation
        varLst = instEnumerationClass(cache,env,DAE.MOD(f,e,submods,eqmod),pre);
        v = instBuiltinAttribute(cache,env,"fixed",optVal,exp,DAE.T_BOOL_DEFAULT,p);
      then v::varLst;
    case(cache,env,DAE.MOD(f,e,smod::submods,eqmod),pre)
      equation
        s1 = Mod.prettyPrintSubmod(smod) +& ", not processed in the built-in class Enumeration";
        Error.addMessage(Error.UNUSED_MODIFIER,{s1});
      then fail();
    case(cache,env,DAE.MOD(f,e,{},eqmod),pre) then {};
    case(cache,env,DAE.NOMOD(),pre) then {};
    case(cache,env,DAE.REDECL(_,_,_),pre) then fail(); /*TODO, report error when redeclaring in Real*/
  end matchcontinue;
end instEnumerationClass;

protected function instBuiltinAttribute
"function instBuiltinAttribute
  Help function to e.g. instRealClass, etc."
  input Env.Cache cache;
  input Env.Env env;
  input Ident id;
  input Option<Values.Value> optVal;
  input DAE.Exp bind;
  input DAE.Type expectedTp;
  input DAE.Properties bindProp;
  output DAE.Var var;
algorithm
  var := matchcontinue(cache,env,id,optVal,bind,expectedTp,bindProp)
    local
      Values.Value v;
      DAE.Type t_1,bindTp;
      DAE.Exp bind1;
      DAE.Const c;
      DAE.Dimension d;
      String s,s1,s2;
    case(cache,env,id,SOME(v),bind,expectedTp,DAE.PROP(bindTp,c))
      equation
        failure(equality(c=DAE.C_VAR()));
        (bind1,t_1) = Types.matchType(bind,bindTp,expectedTp,true);
      then DAE.TYPES_VAR(id,DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),
        SCode.PUBLIC(),t_1,DAE.EQBOUND(bind1,SOME(v),DAE.C_PARAM(),DAE.BINDING_FROM_DEFAULT_VALUE()),NONE());
        
    case(cache,env,id,SOME(v),bind,expectedTp,DAE.PROP(bindTp as (DAE.T_ARRAY(arrayDim = d),_),c))
      equation
        failure(equality(c=DAE.C_VAR()));
        true = OptManager.getOption("checkModel");
        expectedTp = Types.liftArray(expectedTp, d);
        (bind1,t_1) = Types.matchType(bind,bindTp,expectedTp,true);
      then DAE.TYPES_VAR(id,DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),
        SCode.PUBLIC(),t_1,DAE.EQBOUND(bind1,SOME(v),DAE.C_PARAM(),DAE.BINDING_FROM_DEFAULT_VALUE()),NONE());
        
    case(cache,env,id,_,bind,expectedTp,DAE.PROP(bindTp,c))
      equation
        failure(equality(c=DAE.C_VAR()));
        (bind1,t_1) = Types.matchType(bind,bindTp,expectedTp,true);
        (cache,v,_) = Ceval.ceval(cache,env, bind1, false,NONE(), NONE(), Ceval.NO_MSG());
      then DAE.TYPES_VAR(id,DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),
      SCode.PUBLIC(),t_1,DAE.EQBOUND(bind1,SOME(v),DAE.C_PARAM(),DAE.BINDING_FROM_DEFAULT_VALUE()),NONE());

    case(cache,env,id,_,bind,expectedTp,DAE.PROP(bindTp as (DAE.T_ARRAY(arrayDim = d),_),c))
      equation
        failure(equality(c=DAE.C_VAR()));
        true = OptManager.getOption("checkModel");
        expectedTp = Types.liftArray(expectedTp, d);
        (bind1,t_1) = Types.matchType(bind,bindTp,expectedTp,true);
        (cache,v,_) = Ceval.ceval(cache,env, bind1, false,NONE(), NONE(), Ceval.NO_MSG());
      then DAE.TYPES_VAR(id,DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),
      SCode.PUBLIC(),t_1,DAE.EQBOUND(bind1,SOME(v),DAE.C_PARAM(),DAE.BINDING_FROM_DEFAULT_VALUE()),NONE());
      
    case(cache,env,id,_,bind,expectedTp,DAE.PROP(bindTp,c))
      equation
        failure(equality(c=DAE.C_VAR()));
        (bind1,t_1) = Types.matchType(bind,bindTp,expectedTp,true);
      then DAE.TYPES_VAR(id,DAE.ATTR(SCode.NOT_FLOW(),SCode.NOT_STREAM(),SCode.PARAM(),Absyn.BIDIR(),Absyn.NOT_INNER_OUTER()),
      SCode.PUBLIC(),t_1,DAE.EQBOUND(bind1,NONE(),DAE.C_PARAM(),DAE.BINDING_FROM_DEFAULT_VALUE()),NONE());

    case(cache,env,id,_,bind,expectedTp,DAE.PROP(bindTp,c))
      equation
        equality(c=DAE.C_VAR());
        s = ExpressionDump.printExpStr(bind);
        Error.addMessage(Error.HIGHER_VARIABILITY_BINDING,{id,"PARAM",s,"VAR"});
      then fail();
      
    case(cache,env,id,_,bind,expectedTp,DAE.PROP(bindTp,_))
      equation
        failure((_,_) = Types.matchType(bind,bindTp,expectedTp,true));
        s1 = "builtin attribute " +& id +& " of type "+&Types.unparseType(bindTp);
        s2 = Types.unparseType(expectedTp);
        Error.addMessage(Error.TYPE_ERROR,{s1,s2});
      then fail();
    
    case(cache,env,id,SOME(v),bind,expectedTp,bindProp) equation
      true = RTOpts.debugFlag("failtrace");
      Debug.fprintln("failtrace", "instBuiltinAttribute failed for: " +& id +&
                                  " value binding: " +& ValuesUtil.printValStr(v) +&
                                  " binding: " +& ExpressionDump.printExpStr(bind) +&
                                  " expected type: " +& Types.printTypeStr(expectedTp) +&
                                  " type props: " +& Types.printPropStr(bindProp));
    then fail();
    case(cache,env,id,_,bind,expectedTp,bindProp) equation
      true = RTOpts.debugFlag("failtrace");
      Debug.fprintln("failtrace", "instBuiltinAttribute failed for: " +& id +&
                                  " value binding: NONE()" +&
                                  " binding: " +& ExpressionDump.printExpStr(bind) +&
                                  " expected type: " +& Types.printTypeStr(expectedTp) +&
                                  " type props: " +& Types.printPropStr(bindProp));
    then fail();
  end matchcontinue;
end instBuiltinAttribute;

protected function arrayBasictypeBaseclass
"function: arrayBasictypeBaseclass
  author: PA"
  input InstDims inInstDims;
  input DAE.Type inType;
  output Option<DAE.Type> outTypesTypeOption;
algorithm
  outTypesTypeOption := matchcontinue (inInstDims,inType)
    local
      DAE.Type tp,tp_1;
      list<DAE.Dimension> lst;
      InstDims inst_dims;
    case ({},tp) then NONE();
    case (inst_dims,tp)
      equation
        lst = instdimsIntOptList(Util.listLast(inst_dims));
        tp_1 = arrayBasictypeBaseclass2(lst, tp);
      then
        SOME(tp_1);
  end matchcontinue;
end arrayBasictypeBaseclass;

protected function instdimsIntOptList
"function: instdimsIntOptList
  author: PA"
  input list<DAE.Subscript> inInstDims;
  output list<DAE.Dimension> outIntegerOptionLst;
algorithm
  outIntegerOptionLst := matchcontinue (inInstDims)
    local
      list<DAE.Dimension> res;
      Integer i;
      list<DAE.Subscript> ss;
      DAE.Exp e;
    case ({}) then {};
    case (DAE.INDEX(exp = DAE.ICONST(integer = i)) :: ss)
      equation
        res = instdimsIntOptList(ss);
      then
        (DAE.DIM_INTEGER(i) :: res);
    case (DAE.WHOLEDIM() :: ss)
      equation
        true = OptManager.getOption("checkModel");
        res = instdimsIntOptList(ss);
      then
        DAE.DIM_UNKNOWN() :: res;
    // The case of non-expanded arrays.      
    case (DAE.WHOLE_NONEXP(exp=e) :: ss) 
      equation
        false = RTOpts.splitArrays();
        res = instdimsIntOptList(ss);
      then
        DAE.DIM_EXP(e) :: res;
    case (DAE.INDEX(exp = _) :: ss)
      equation
        true = OptManager.getOption("checkModel");
        res = instdimsIntOptList(ss);
      then
        DAE.DIM_UNKNOWN() :: res;
  end matchcontinue;
end instdimsIntOptList;

protected function arrayBasictypeBaseclass2
"function: arrayBasictypeBaseclass2
  author: PA"
  input list<DAE.Dimension> inDimensionLst;
  input DAE.Type inType;
  output DAE.Type outType;
algorithm
  outType := match (inDimensionLst,inType)
    local
      DAE.Type tp,tp_1,res;
      DAE.Dimension d;
      list<DAE.Dimension> ds;
    case ({},tp) then tp;
    case ((d :: ds),tp)
      equation
        tp_1 = Types.liftArray(tp, d);
        res = arrayBasictypeBaseclass2(ds, tp_1);
      then
        res;
  end match;
end arrayBasictypeBaseclass2;

public function partialInstClassIn
"function: partialInstClassIn
  This function is used when instantiating classes in lookup of other classes.
  The only work performed by this function is to instantiate local classes and
  inherited classes."
  input Env.Cache inCache;
  input .Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input SCode.Element inClass;
  input SCode.Visibility inVisibility;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output ClassInf.State outState;
algorithm
  (outCache,outEnv,outIH,outState) := matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,inClass,inVisibility,inInstDims)
    local
      list<Env.Frame> env;
      DAE.Mod mods;
      Prefix.Prefix pre;
      Connect.Sets csets;
      ClassInf.State ci_state,ci_state_1;
      SCode.Element c;
      String n;
      SCode.Restriction r, rCached;
      SCode.ClassDef d;
      SCode.Visibility vis;
      InstDims inst_dims;
      Env.Cache cache;
      InstanceHierarchy ih;
      InstHashTable instHash;
      tuple<Env.Cache, Env.Env, InstanceHierarchy, DAE.Mod, Prefix.Prefix, Connect.Sets,
            ClassInf.State, SCode.Element, SCode.Visibility, InstDims> inputs;
      tuple<Env.Env, ClassInf.State> outputs;
      Absyn.Path fullEnvPathPlusClass;
      Option<Absyn.Path> envPathOpt;
      String className;

      DAE.Mod aa_1;
      Prefix.Prefix aa_2;
      Connect.Sets aa_3;
      ClassInf.State aa_4;
      SCode.Element aa_5;
      InstDims aa_7;
      tuple<InstDims,DAE.Mod,Connect.Sets,ClassInf.State,SCode.Element> bbx,bby;

    // see if we find a partial class inst
    case (cache,env,ih,mods,pre,csets,ci_state,c as SCode.CLASS(name = className, restriction=r),vis,inst_dims)
      equation
        false = RTOpts.debugFlag("noCache");
        instHash = getGlobalRoot(instHashIndex);
        envPathOpt = Env.getEnvPath(inEnv);
        className = SCode.className(c);
        fullEnvPathPlusClass = Absyn.selectPathsOpt(envPathOpt, Absyn.IDENT(className));
        {_,SOME(FUNC_partialInstClassIn(inputs, outputs))} = BaseHashTable.get(fullEnvPathPlusClass, instHash);
        (_, _, _, aa_1, aa_2, aa_3, aa_4, aa_5 as SCode.CLASS(restriction=rCached), _, aa_7) = inputs;
        // are the important inputs the same??
        prefixEqualUnlessBasicType(aa_2, pre, c);
        bbx = (aa_7,      aa_1, aa_3,  aa_4,     aa_5);
        bby = (inst_dims, mods, csets, ci_state, c);
        equality(bbx = bby);
        (env,ci_state_1) = outputs;
        //Debug.fprintln("cache", "IIIIPARTIAL->got PARTIAL from instCache: " +& Absyn.pathString(fullEnvPathPlusClass));
      then
        (inCache,env,ih,ci_state_1);

    /*/ adrpo: TODO! FIXME! see if we find a full instantiation!
    // this fails for 2-3 examples, so disable it for now and check it later
    case (cache,env,ih,mods,pre,csets,ci_state,c as SCode.CLASS(name = className, restriction=r),vis,inst_dims)
      local
      tuple<Env.Cache, Env, InstanceHierarchy, UnitAbsyn.InstStore, DAE.Mod, Prefix.Prefix,
            Connect.Sets, ClassInf.State, SCode.Element, Boolean, InstDims, Boolean,
            ConnectionGraph.ConnectionGraph, Option<DAE.ComponentRef>> inputs;
      tuple<Env.Cache, Env, InstanceHierarchy, UnitAbsyn.InstStore, DAE.DAElist,
            Connect.Sets, ClassInf.State, list<DAE.Var>, Option<DAE.Type>,
            Option<SCode.Attributes>, DAE.EqualityConstraint,
            ConnectionGraph.ConnectionGraph> outputs;
      equation
        false = RTOpts.debugFlag("noCache");
        instHash = getGlobalRoot(instHashIndex);
        envPathOpt = Env.getEnvPath(inEnv);
        fullEnvPathPlusClass = Absyn.selectPathsOpt(envPathOpt, Absyn.IDENT(className));
        {SOME(FUNC_instClassIn(inputs, outputs)), _} = get(fullEnvPathPlusClass, instHash);
        (_, _, _, _, aa_1, aa_2, aa_3, aa_4, aa_5  as SCode.CLASS(restriction=rCached), _, aa_7, _, _, _) = inputs;
        // are the important inputs the same??
        equality(rCached = r); // restrictions should be the same
        prefixEqualUnlessBasicType(aa_2, pre, c); // check if class is enum as then prefix doesn't matter!        
        bbx = (aa_7,      aa_1, aa_4,     a5);
        bby = (inst_dims, mods, ci_state, c);
        equality(bbx = bby);
        // true = checkClassEqual(aa_5, c);
        (cache,env,_,_,_,_,ci_state_1,_,_,_,_,_) = outputs;
        //Debug.fprintln("cache", "IIIIPARTIAL->got FULL from instCache: " +& Absyn.pathString(fullEnvPathPlusClass));
      then
        (inCache,env,ih,ci_state_1);*/

    /* call the function and then add it in the cache */
    case (cache,env,ih,mods,pre,csets,ci_state,c,vis,inst_dims)
      equation
        (cache,env,ih,ci_state) =
           partialInstClassIn_dispatch(inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,inClass,vis,inInstDims);

        envPathOpt = Env.getEnvPath(inEnv);
        className = SCode.className(c);
        fullEnvPathPlusClass = Absyn.selectPathsOpt(envPathOpt, Absyn.IDENT(className));

        inputs = (inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,inClass,vis,inInstDims);
        outputs = (env,ci_state);

        addToInstCache(fullEnvPathPlusClass,
           NONE(),
           SOME(FUNC_partialInstClassIn( // result for partial instantiation
             inputs,outputs)));
        //Debug.fprintln("cache", "IIIIPARTIAL->added to instCache: " +& Absyn.pathString(fullEnvPathPlusClass));
      then
        (cache,env,ih,ci_state);

    case (cache,env,ih,mods,pre,csets,ci_state,(c as SCode.CLASS(name = n,restriction = r,classDef = d)),vis,inst_dims)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.partialInstClassIn failed on class:" +&
           n +& " in environment: " +& Env.printEnvPathStr(env));
      then
        fail();
  end matchcontinue;
end partialInstClassIn;

public function partialInstClassIn_dispatch
"function: partialInstClassIn
  This function is used when instantiating classes in lookup of other classes.
  The only work performed by this function is to instantiate local classes and
  inherited classes."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input SCode.Element inClass;
  input SCode.Visibility inVisibility;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output ClassInf.State outState;
algorithm
  (outCache,outEnv,outIH,outState) := matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,inClass,inVisibility,inInstDims)
    local
      list<Env.Frame> env,env_1;
      DAE.Mod mods;
      Prefix.Prefix pre;
      Connect.Sets csets;
      ClassInf.State ci_state,ci_state_1;
      SCode.Element c;
      String n;
      SCode.Restriction r;
      SCode.ClassDef d;
      SCode.Visibility vis;
      SCode.Partial partialPrefix;
      InstDims inst_dims;
      Env.Cache cache;
      InstanceHierarchy ih;
      Absyn.Info info;

    case (cache,env,ih,mods,pre,csets,ci_state,(c as SCode.CLASS(name = "Real")),_,_)
      then (cache,env,ih,ci_state);

    case (cache,env,ih,mods,pre,csets,ci_state,(c as SCode.CLASS(name = "Integer")),_,_)
      then (cache,env,ih,ci_state);

    case (cache,env,ih,mods,pre,csets,ci_state,(c as SCode.CLASS(name = "String")),_,_)
      then (cache,env,ih,ci_state);

    case (cache,env,ih,mods,pre,csets,ci_state,(c as SCode.CLASS(name = "Boolean")),_,_)
      then (cache,env,ih,ci_state);

    case (cache,env,ih,mods,pre,csets,ci_state,(c as SCode.CLASS(name = n,restriction = r,partialPrefix=partialPrefix,classDef = d, info = info)),vis,inst_dims)
      equation
        // t1 = clock();
        (cache,env_1,ih,ci_state_1) = partialInstClassdef(cache,env,ih, mods, pre, csets, ci_state, d, r, partialPrefix, vis, inst_dims, n, info);
        // t2 = clock();
        // time = t2 -. t1;
        //b=realGt(time,0.05);
        // s = realString(time);
        // s2 = Env.printEnvPathStr(env);
        // Debug.fprintln("insttr", "ICLASSPARTIAL " +& n +& " inst time: " +& s +& " in env " +& s2 +& " mods: " +& Mod.printModStr(mods));
        //print(Util.if_(b,s,""));
        //print("inCache:");print(Env.printCacheStr(cache));print("\n");
        cache = Env.addCachedEnv(cache,n,env_1);
        // print("outCache:");print(Env.printCacheStr(cache));print("\n");
        // print("partialInstClassDef, outenv:");print(Env.printEnvStr(env_1));
      then
        (cache,env_1,ih,ci_state_1);
  end matchcontinue;
end partialInstClassIn_dispatch;

protected function equalityConstraintOutputDimension
  input list<SCode.Element> inElements;
  output Integer outDimension;
algorithm
  outDimension := matchcontinue(inElements)
  local
    list<SCode.Element> tail;
    Integer dim;
    case({}) equation
      then 0;
    case(SCode.COMPONENT(attributes = SCode.ATTR(
        direction = Absyn.OUTPUT(),
        arrayDims = {Absyn.SUBSCRIPT(Absyn.INTEGER(dim))}
      )) :: _) equation
      then dim;
    case(_ :: tail) equation
      dim = equalityConstraintOutputDimension(tail);
      then dim;
  end matchcontinue;
end equalityConstraintOutputDimension;

protected function equalityConstraint
  "function: equalityConstraint
    Tests if the given elements contain equalityConstraint function and returns
    corresponding DAE.EqualityConstraint."
  input Env.Env inEnv;
  input list<SCode.Element> inCdefelts;
  input Absyn.Info info;
  output DAE.EqualityConstraint outResult;
algorithm
  outResult := matchcontinue(inEnv,inCdefelts,info)
  local
      list<SCode.Element> tail, els;
      Env.Env env;
      Absyn.Path path;
      Integer dimension;
      DAE.InlineType inlineType;
      SCode.Element el;
      
    case(env,{},_) then NONE();
    
    case(env, (el as SCode.CLASS(name = "equalityConstraint", restriction = SCode.R_FUNCTION(),
         classDef = SCode.PARTS(elementLst = els))) :: _, info)
      equation
        SOME(path) = Env.getEnvPath(env);
        path = Absyn.joinPaths(path, Absyn.IDENT("equalityConstraint"));
        /*(cache, env,_) = implicitFunctionTypeInstantiation(cache, env, classDef);
        (cache, types,_) = Lookup.lookupFunctionsInEnv(cache, env, path, info);
        length = listLength(types);
        print("type count: ");
        print(intString(length));
        print("\n");*/
        dimension = equalityConstraintOutputDimension(els);
        /*print("dimension: ");
        print(intString(dimension));
        print("\n");*/
        // adrpo: get the inline type of the function
        inlineType = isInlineFunc2(el);
      then 
        SOME((path, dimension, inlineType));
    
    case(env, _ :: tail, info)
      then 
        equalityConstraint(env, tail, info);
    
  end matchcontinue;
end equalityConstraint;

protected function handleUnitChecking
"@author: adrpo
 do this unit checking ONLY if we have the flag!"
  input Env.Cache cache;
  input Env.Env env;
  input UnitAbsyn.InstStore store;
  input Connect.Sets csets;
  input Prefix.Prefix pre;
  input DAE.DAElist compDAE;
  input list<DAE.DAElist> daes;
  input String className "for debugging";
  output Env.Cache outCache;
  output Env.Env outEnv;
  output UnitAbsyn.InstStore outStore;
algorithm
  (outCache,outEnv,outStore) := matchcontinue(cache,env,store,csets,pre,compDAE,daes,className)
    local
      DAE.DAElist daetemp;
      UnitAbsyn.UnitTerms ut;

    // do nothing if we don't have to do unit checking
    case (cache,env,store,csets,pre,compDAE,daes,className)
      equation
        false = OptManager.getOption("unitChecking");
      then
        (cache,env,store);

    case (cache,env,store,csets,pre,compDAE,daes,className)
      equation
        // Perform unit checking/dimensional analysis
        //(daetemp,_) = ConnectUtil.equations(csets,pre,false,ConnectionGraph.EMPTY); // ToDO. calculation of connect eqns done twice. remove in future.
        // equations from components (dae1) not considered, they are checked in resp recursive call
        // but bindings on scalar variables must be considered, therefore passing dae1 separately
        //daetemp = DAEUtil.joinDaeLst(daetemp::daes);
        daetemp = DAEUtil.joinDaeLst(daes);
        (store,ut)=  UnitAbsynBuilder.instBuildUnitTerms(env,daetemp,compDAE,store);

        //print("built store for "+&className+&"\n");
        //UnitAbsynBuilder.printInstStore(store);
        //print("terms for "+&className+&"\n");
        //UnitAbsynBuilder.printTerms(ut);

        UnitAbsynBuilder.registerUnitWeights(cache,env,compDAE);

        // perform the check
        store = UnitChecker.check(ut,store);

        //print("store for "+&className+&"\n");
        //UnitAbsynBuilder.printInstStore(store);
        //print("dae1="+&DAEDump.dumpDebugDAE(DAE.DAE(dae1))+&"\n");
     then
       (cache,env,store);
  end matchcontinue;
end  handleUnitChecking;

protected function instClassdef "
  There are two kinds of class definitions, either explicit
  definitions SCode.PARTS() or
  derived definitions SCode.DERIVED() or
  extended derived definitions SCode.CLASS_EXTENDS().

  When instantiating an explicit definition, the elements are first
  instantiated, using instElementList, and then the equations
  and finally the algorithms are instantiated using instEquation
  and instAlgorithm, respectively. The resulting lists of equations
  are concatenated to produce the result.
  The last two arguments are the same as for instClassIn:
  implicit instantiation and implicit package/function instantiation."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod2;
  input Prefix.Prefix inPrefix3;
  input Connect.Sets inSets4;
  input ClassInf.State inState5;
  input String className;
  input SCode.ClassDef inClassDef6;
  input SCode.Restriction inRestriction7;
  input SCode.Visibility inVisibility;
  input SCode.Partial inPartialPrefix;
  input SCode.Encapsulated inEncapsulatedPrefix;
  input InstDims inInstDims9;
  input Boolean inBoolean10;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  input Option<DAE.ComponentRef> instSingleCref;
  input Absyn.Info info;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output Option<DAE.Type> outTypesTypeOption;
  output Option<SCode.Attributes> optDerAttr;
  output DAE.EqualityConstraint outEqualityConstraint;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph):=
  instClassdef2(inCache,inEnv,inIH,store,inMod2,inPrefix3,inSets4,inState5,className,inClassDef6,inRestriction7,inVisibility,
                inPartialPrefix,inEncapsulatedPrefix,inInstDims9,inBoolean10,inCallingScope,inGraph,instSingleCref,info,Util.makeStatefulBoolean(false));
end instClassdef;


protected function checkExtendsRestrictionMatch
"see Modelica Specfification 3.1, 7.1.3 Restrictions on the Kind of Base Class"
  input SCode.Restriction r1;
  input SCode.Restriction r2;
algorithm
  _ := matchcontinue(r1, r2)
    // package can be extendended by package
    case (SCode.R_PACKAGE(), SCode.R_PACKAGE()) then ();
    // function -> function
    case (SCode.R_FUNCTION(), SCode.R_FUNCTION()) then ();
    // external function -> function
    case (SCode.R_EXT_FUNCTION(), SCode.R_FUNCTION()) then ();
    // type -> type
    case (SCode.R_TYPE(), SCode.R_TYPE()) then ();
    // record -> record
    case (SCode.R_RECORD(), SCode.R_RECORD()) then ();
    // connector -> type
    case (SCode.R_CONNECTOR(_), SCode.R_TYPE()) then ();
    // connector -> record
    case (SCode.R_CONNECTOR(_), SCode.R_RECORD()) then ();
    // connector -> connector
    case (SCode.R_CONNECTOR(_), SCode.R_CONNECTOR(_)) then ();
    // block -> record
    case (SCode.R_BLOCK(), SCode.R_RECORD()) then ();
    // block -> block
    case (SCode.R_BLOCK(), SCode.R_BLOCK()) then ();
    // model -> record
    case (SCode.R_MODEL(), SCode.R_RECORD()) then ();
    // model -> block
    case (SCode.R_MODEL(), SCode.R_BLOCK()) then ();
    // model -> model
    case (SCode.R_MODEL(), SCode.R_MODEL()) then ();
            
    // class??? same restrictions as model?
    // model -> class
    case (SCode.R_MODEL(), SCode.R_CLASS()) then ();
    // class -> model
    case (SCode.R_CLASS(), SCode.R_MODEL()) then ();
    // class -> record
    case (SCode.R_CLASS(), SCode.R_RECORD()) then ();
    // class -> block
    case (SCode.R_CLASS(), SCode.R_BLOCK()) then ();
    // class -> class
    case (SCode.R_CLASS(), SCode.R_CLASS()) then ();
    // operator -> operator
    case (SCode.R_OPERATOR(), SCode.R_OPERATOR()) then ();
    // operator function -> function 
    case (SCode.R_OPERATOR_FUNCTION(), SCode.R_FUNCTION()) then ();
    // operator function -> operator function
    case (SCode.R_OPERATOR_FUNCTION(), SCode.R_OPERATOR_FUNCTION()) then ();
    // operator record
    case (SCode.R_OPERATOR_RECORD(), SCode.R_OPERATOR_RECORD()) then ();
  end matchcontinue;
end checkExtendsRestrictionMatch;

protected function checkExtendsForTypeRestiction
"@author: adrpo
  This function will check extends for Modelica 3.1 restrictions"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Restriction inRestriction;
  input list<SCode.Element> inSCodeElementLst;
algorithm
  _ := matchcontinue(inCache, inEnv, inIH, inRestriction, inSCodeElementLst)
    local
      Absyn.Path p;
      SCode.Restriction r1, r2, r;
      String id;
    
    // check the basics ....
    // type or connector can be extended by a type
    case (_, _, _, r, {SCode.EXTENDS(baseClassPath=Absyn.IDENT(id))})
      equation
        true = listMember(r, {SCode.R_TYPE(), SCode.R_CONNECTOR(false), SCode.R_CONNECTOR(true)});
        true = listMember(id, {"Real", "Integer", "Boolean", "String"});
      then ();
      
    // we haven't found the class, do nothing
    case (inCache, inEnv, inIH, r1, {SCode.EXTENDS(baseClassPath=p)})
      equation
        failure((_, _, _) = Lookup.lookupClass(inCache, inEnv, p, false));
      then ();
     
    // we found te class, check the restriction
    case (inCache, inEnv, inIH, r1, {SCode.EXTENDS(baseClassPath=p)})
      equation
        (_,SCode.CLASS(restriction=r2),_) = Lookup.lookupClass(inCache,inEnv,p,false);
        checkExtendsRestrictionMatch(r1, r2);
      then ();

    // make some waves that this is not correct
    case (inCache, inEnv, inIH, r1, {SCode.EXTENDS(baseClassPath=p)})
      equation
        (_,SCode.CLASS(restriction=r2),_) = Lookup.lookupClass(inCache, inEnv, p, false);
        print("Error!: " +& SCodeDump.restrString(r1) +& " " +& Env.printEnvPathStr(inEnv) +& 
              " cannot be extended by " +& SCodeDump.restrString(r2) +& " " +& Absyn.pathString(p) +& " due to derived/base class restrictions.\n");
      then 
        fail();
  end matchcontinue;
end checkExtendsForTypeRestiction;

protected function instClassdefBasicType "
This function will try to instantiate the 
class definition as a it would extend a basic 
type"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod2;
  input Prefix.Prefix inPrefix3;
  input Connect.Sets inSets4;
  input ClassInf.State inState5;
  input String className;
  input SCode.ClassDef inClassDef6;
  input SCode.Restriction inRestriction7;
  input SCode.Visibility inVisibility;
  input InstDims inInstDims9;
  input Boolean inBoolean10;
  input ConnectionGraph.ConnectionGraph inGraph;
  input Option<DAE.ComponentRef> instSingleCref;
  input Absyn.Info info;
  input Util.StatefulBoolean stopInst "prevent instantiation of classes adding components to primary types";
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output Option<DAE.Type> outTypesTypeOption;
  output Option<SCode.Attributes> optDerAttr;
  output DAE.EqualityConstraint outEqualityConstraint;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inMod2,inPrefix3,inSets4,inState5,className,inClassDef6,inRestriction7,inVisibility,inInstDims9,inBoolean10,inGraph,instSingleCref,info,stopInst)
    local
      list<SCode.Element> cdefelts,compelts,extendselts,els;
      list<Env.Frame> env1,env2,env3,env;
      list<tuple<SCode.Element, DAE.Mod>> cdefelts_1,cdefelts_2;
      Connect.Sets csets,csets1;
      DAE.DAElist dae1,dae2,dae;
      ClassInf.State ci_state1,ci_state;
      list<DAE.Var> tys;
      Option<DAE.Type> bc;
      DAE.Mod mods;
      Prefix.Prefix pre;
      SCode.Restriction re;
      Boolean impl;
      SCode.Visibility vis;
      InstDims inst_dims;
      Env.Cache cache;
      DAE.EqualityConstraint eqConstraint;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;

    // This rule describes how to instantiate a class definition
    // that extends a basic type. (No equations or algorithms allowed)
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.PARTS(elementLst = els,
                      normalEquationLst = {}, initialEquationLst = {},
                      normalAlgorithmLst = {}, initialAlgorithmLst = {}),
          re,vis,inst_dims,impl,graph,instSingleCref,info,stopInst)
      equation
        // set this to get rid of the error messages that might happen and WE FAIL BEFORE we actually call instBasictypeBaseclass  
        ErrorExt.setCheckpoint("instClassdefBasicType1");
        
        // we should have just ONE extends, but it might have more like one class containing just annotations
        (cdefelts,{},extendselts as _::_ /*{one}*/,compelts) = splitElts(els) "components should be empty, checked in instBasictypeBaseclass type below";
        // adrpo: TODO! DO SOME CHECKS HERE!
        // 1. a type extending basic types cannot have components, and only a function definition (equalityConstraint!)
        // {} = compelts; // no components!
        
        // adrpo: VERY decisive check!
        //        only CONNECTOR and TYPE can be extended by basic types!
        // true = listMember(re, {SCode.R_TYPE, SCode.R_CONNECTOR(false), SCode.R_CONNECTOR(true)});
        
        // checkExtendsForTypeRestiction(cache, env, ih, re, extendselts);
        
        (env1,ih) = addClassdefsToEnv(env, ih, pre, cdefelts, impl, SOME(mods)) "1. CLASS & IMPORT nodes and COMPONENT nodes(add to env)" ;
        cdefelts_1 = addNomod(cdefelts) "instantiate CDEFS so redeclares are carried out" ;
        (cache,env2,ih,cdefelts_2,csets) = updateCompeltsMods(cache,env1,ih, pre, cdefelts_1, ci_state, csets, impl);

        //(cache, cdefelts_2) = removeConditionalComponents(cache, env2, cdefelts_2, pre);
        (cache,env3,ih,store,dae1,csets1,ci_state1,tys,graph) =
          instElementList(cache, env2, ih, store, mods , pre, csets, ci_state, cdefelts_2, inst_dims, impl, INNER_CALL(), graph);
        mods = Types.removeFirstSubsRedecl(mods);
        
        ErrorExt.rollBack("instClassdefBasicType1"); // rollback before going into instBasictypeBaseclass 
        
        // oh, the horror of backtracking! we need this to make sure that this case failed BEFORE or AFTER it went into instBasictypeBaseclass         
        (cache,ih,store,dae2,bc,tys)= instBasictypeBaseclass(cache, env3, ih, store, extendselts, compelts, mods, inst_dims, info, stopInst);
        // Search for equalityConstraint
        eqConstraint = equalityConstraint(env3, els, info);
        dae = DAEUtil.joinDaes(dae1,dae2);
      then
        (cache,env3,ih,store,dae,csets1,ci_state,tys,bc,NONE(),eqConstraint,graph);

    // VERY COMPLICATED CHECKPOINT! TODO! try to simplify it, maybe by sending Prefix.TYPE and checking in instVar!
    // did the previous 
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.PARTS(elementLst = els,
                      normalEquationLst = {}, initialEquationLst = {},
                      normalAlgorithmLst = {}, initialAlgorithmLst = {}),
          re,vis,inst_dims,impl,graph,instSingleCref,info,stopInst)
      equation
        true = ErrorExt.isTopCheckpoint("instClassdefBasicType1");
        ErrorExt.rollBack("instClassdefBasicType1");
      then
        fail();
  end matchcontinue;
end instClassdefBasicType;

protected function checkDerivedRestriction
  input SCode.Restriction parentRestriction;
  input SCode.Restriction childRestriction;
  input SCode.Ident childName;
  output Boolean b;
protected
  Boolean b1, b2, b3, b4;
algorithm
  b1 := listMember(childName, {"Real", "Integer", "String", "Boolean"});
  b2 := listMember(childRestriction, {SCode.R_TYPE(), SCode.R_PREDEFINED_INTEGER(), SCode.R_PREDEFINED_REAL(), SCode.R_PREDEFINED_STRING(), SCode.R_PREDEFINED_BOOLEAN()});
  b3 := valueEq(parentRestriction, SCode.R_TYPE());
  b4 := valueEq(parentRestriction, SCode.R_CONNECTOR(false)) or valueEq(parentRestriction, SCode.R_CONNECTOR(true));
  // basically if child or parent is a type or basic type or parent is a connector and child is a type
  b := boolOr(b1, boolOr(b2, boolOr(b3, boolAnd(boolOr(b1,b2), b4)))); 
end checkDerivedRestriction;

protected function instClassdef2 "
  There are two kinds of class definitions, either explicit
  definitions SCode.PARTS() or
  derived definitions SCode.DERIVED() or
  extended derived definitions SCode.CLASS_EXTENDS().

  When instantiating an explicit definition, the elements are first
  instantiated, using instElementList, and then the equations
  and finally the algorithms are instantiated using instEquation
  and instAlgorithm, respectively. The resulting lists of equations
  are concatenated to produce the result.
  The last two arguments are the same as for instClassIn:
  implicit instantiation and implicit package/function instantiation."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod2;
  input Prefix.Prefix inPrefix3;
  input Connect.Sets inSets4;
  input ClassInf.State inState5;
  input String className;
  input SCode.ClassDef inClassDef6;
  input SCode.Restriction inRestriction7;
  input SCode.Visibility inVisibility;
  input SCode.Partial inPartialPrefix;
  input SCode.Encapsulated inEncapsulatedPrefix;
  input InstDims inInstDims9;
  input Boolean inBoolean10;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  input Option<DAE.ComponentRef> instSingleCref;
  input Absyn.Info info;
  input Util.StatefulBoolean stopInst "prevent instantiation of classes adding components to primary types";
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output Option<DAE.Type> outTypesTypeOption;
  output Option<SCode.Attributes> optDerAttr;
  output DAE.EqualityConstraint outEqualityConstraint;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inMod2,inPrefix3,inSets4,inState5,className,inClassDef6,inRestriction7,inVisibility,inPartialPrefix,inEncapsulatedPrefix,inInstDims9,inBoolean10,inCallingScope,inGraph,instSingleCref,info,stopInst)
    local
      list<SCode.Element> cdefelts,compelts,extendselts,els,extendsclasselts;
      list<Env.Frame> env1,env2,env3,env,env4,env5,cenv,cenv_2,env_2;
      list<tuple<SCode.Element, DAE.Mod>> cdefelts_1,extcomps,compelts_1,compelts_2, comp_cond;
      list<SCode.Element> compelts_2_elem;
      Connect.Sets csets,csets1,csets_filtered,csets2,csets3,csets4,csets5,csets_1;
      DAE.DAElist dae1,dae2,dae3,dae4,dae5,dae;
      ClassInf.State ci_state1,ci_state,ci_state2,ci_state3,ci_state4,ci_state5,ci_state6,new_ci_state,ci_state_1;
      list<DAE.Var> vars;
      Option<DAE.Type> bc;
      DAE.Mod mods,emods,mod_1,mods_1,checkMods;
      Prefix.Prefix pre;
      list<SCode.Equation> eqs,initeqs,eqs2,initeqs2,eqs_1,initeqs_1;
      list<SCode.AlgorithmSection> alg,initalg,alg2,initalg2,alg_1,initalg_1;
      SCode.Restriction re,r;
      Boolean impl;
      SCode.Visibility vis;
      SCode.Encapsulated enc2;
      SCode.Partial partialPrefix;
      SCode.Encapsulated encapsulatedPrefix;
      InstDims inst_dims,inst_dims_1;
      list<DAE.Subscript> inst_dims2;
      String id,cn2,cns,scope_str,s,str;
      SCode.Element c;
      SCode.ClassDef classDef;
      Option<DAE.EqMod> eq;
      list<DAE.Dimension> dims;
      Absyn.Path cn;
      Option<list<Absyn.Subscript>> ad;
      SCode.Mod mod;
      Env.Cache cache;
      Option<SCode.Attributes> oDA;
      DAE.EqualityConstraint eqConstraint;
      CallingScope callscope;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      DAE.DAElist fdae;
      Boolean unrollForLoops;
      Absyn.Info info2;
      list<Absyn.TypeSpec> tSpecs;
      list<DAE.Type> tys;
      SCode.Attributes DA;
      DAE.Type ty;
      Absyn.TypeSpec tSpec;
      
    // This rule describes how to instantiate a class definition
    // that extends a basic type. (No equations or algorithms allowed)
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          inClassDef6 as SCode.PARTS(elementLst = els,
                      normalEquationLst = {}, initialEquationLst = {},
                      normalAlgorithmLst = {}, initialAlgorithmLst = {}),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        false = Util.getStatefulBoolean(stopInst);
        (cache,env,ih,store,fdae,csets,ci_state,vars,bc,oDA,eqConstraint,graph) = 
            instClassdefBasicType(cache,env,ih,store,mods,pre,csets,ci_state,className,inClassDef6,re,vis,inst_dims,impl,graph,instSingleCref,info,stopInst);
      then
        (cache,env,ih,store,fdae,csets,ci_state,vars,bc,oDA,eqConstraint,graph);

    // This case instantiates external objects. An external object inherits from ExternalOBject
    // and have two local functions: constructor and destructor (and no other elements).
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.PARTS(elementLst = els,
                      normalEquationLst = eqs, initialEquationLst = initeqs,
                      normalAlgorithmLst = alg, initialAlgorithmLst = initalg),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        false = Util.getStatefulBoolean(stopInst);
         true = isExternalObject(els);
         (cache,env,ih,dae,ci_state) = instantiateExternalObject(cache,env,ih,els,impl);
      then
        (cache,env,ih,store,dae,csets,ci_state,{},NONE(),NONE(),NONE(),graph);

    // This rule describes how to instantiate an explicit class definition
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.PARTS(elementLst = els,
                      normalEquationLst = eqs, initialEquationLst = initeqs,
                      normalAlgorithmLst = alg, initialAlgorithmLst = initalg),
          re,vis,_,_,inst_dims,impl,callscope,graph,instSingleCref,info,stopInst)
      equation
        false = Util.getStatefulBoolean(stopInst);
        UnitParserExt.checkpoint();
        //Debug.traceln(" Instclassdef for: " +& PrefixUtil.printPrefixStr(pre) +& "." +&  className +& " mods: " +& Mod.printModStr(mods));
        ci_state1 = ClassInf.trans(ci_state, ClassInf.NEWDEF());
        els = extractConstantPlusDeps(els,instSingleCref,{},className);
        
        // split elements
        (cdefelts,extendsclasselts,extendselts,compelts) = splitElts(els);

        (env1,ih) = addClassdefsToEnv(env, ih, pre, cdefelts, impl, SOME(mods))
        "1. CLASS & IMPORT nodes and COMPONENT nodes(add to env)" ;

        // adrpo: TODO! DO SOME CHECKS HERE!
        // restriction on what can inherit what, see 7.1.3 Restrictions on the Kind of Base Class
        // if a type   -> no components, can extends only another type
        // if a record -> components ok
        // checkRestrictionsOnTheKindOfBaseClass(cache, env, ih, re, extendselts);

        (cache,env2,ih,emods,extcomps,eqs2,initeqs2,alg2,initalg2) =
        InstExtends.instExtendsAndClassExtendsList(cache, env1, ih, mods, pre, extendselts, extendsclasselts, ci_state, className, impl, false)
        "2. EXTENDS Nodes inst_extends_list only flatten inhteritance structure. It does not perform component instantiations.";
        compelts_1 = addNomod(compelts)
        "Problem. Modifiers on inherited components are unelabed, loosing their
                  type information. This will not work, since the modifier type
                  can not always be found.
         For instance. 
          model B extends B2; end B; model B2 Integer ni=1; end B2;
          model test
            Integer n=2;
            B b(ni=n);
          end test;

         The modifier (n=n) will be untypes when B is instantiated
         and the variable n can not be found, since the component b
         is instantiated in env of B.

         Solution:
          Redesign instExtendsList to return (SCode.Element, Mod) list and
          convert other component elements to the same format, such that
          instElement can handle the new format uniformely." ;

        cdefelts_1 = addNomod(cdefelts);
        
        // Add components from base classes to be instantiated in 3 as well.
        compelts_1 = Util.listFlatten({extcomps,compelts_1,cdefelts_1});
                
        // Take the union of the equations in the current scope and equations
        // from extends, to filter out identical equations.
        eqs_1 = Util.listUnionComp(eqs, eqs2, SCode.equationEqual);
        initeqs_1 = Util.listUnionComp(initeqs, initeqs2, SCode.equationEqual);

        alg_1 = listAppend(alg, alg2);
        initalg_1 = listAppend(initalg, initalg2);

        //Only keep inside connections with matching prefix for this class.
        //csets will remain unfiltered for other components in "outer class"
        csets_filtered = filterConnectionSetCrefs(csets, pre);

        //Add connection crefs from equations to connection sets
        csets = addConnectionCrefs(csets, eqs_1);
        csets_filtered = addConnectionCrefs(csets_filtered, eqs_1);

        //Add filtered connection sets to env so ceval can reach it
        (env2,ih) = addConnectionSetToEnv(csets_filtered, pre, env2,ih);
        id = Env.printEnvPathStr(env);

        //Add variables to env, wihtout type and binding, which will be added
        //later in instElementList (where update_variable is called)"
        (cache,env3,ih) = addComponentsToEnv(cache, env2, ih, emods, pre, csets, ci_state, compelts_1, compelts_1, eqs_1, inst_dims, impl);
        //Update the modifiers of elements to typed ones, needed for modifiers
        //on components that are inherited.       
        (cache,env4,ih,compelts_2,csets) = updateCompeltsMods(cache, env3, ih, pre, extcomps, ci_state, csets, impl);
        compelts_1 = addNomod(compelts);
        cdefelts_1 = addNomod(cdefelts);
        compelts_2 = Util.listFlatten({compelts_2, compelts_1, cdefelts_1});
 
        // adrpo: MAKE SURE inner objects ARE FIRST in the list for instantiation!
        // TODO! FIXME! CHECKME! join this function with splitElts to make it faster
        compelts_2 =  sortInnerFirstTplLstElementMod(compelts_2);

        //Instantiate components
        compelts_2_elem = Util.listMap(compelts_2,Util.tuple21);
        
        // Debug.fprintln("innerouter", "Number of components: " +& intString(listLength(compelts_2_elem)));
        // Debug.fprintln("innerouter", Util.stringDelimitList(Util.listMap(compelts_2_elem, SCodeDump.printElementStr), "\n"));
        
        checkMods = Mod.merge(mods,emods,env4,Prefix.NOPRE());
        mods = checkMods;
        
        //print("To match modifiers,\n" +& Mod.printModStr(checkMods) +& "\n on components: ");
        //print(" (" +& Util.stringDelimitList(Util.listMap(compelts_2_elem,SCode.elementName),", ") +& ") \n");
        matchModificationToComponents(compelts_2_elem,checkMods,className);

        // Move any conditional components to the end of the component list, to
        // make sure that any dependencies of the condition are instantiated first.
        (comp_cond, compelts_2) = Util.listSplitOnTrue(compelts_2, componentHasCondition);
        compelts_2 = listAppend(compelts_2, comp_cond);

        (cache,env5,ih,store,dae1,csets1,ci_state2,vars,graph) = 
          instElementList(cache, env4, ih, store, mods, pre, csets, ci_state1, compelts_2, inst_dims, impl, callscope, graph);

        // If we are currently instantiating a connector, add all flow variables
        // in it as inside connectors.
        csets1 = addConnectorVariablesFromDAE(ci_state1, dae1, vars, csets1, info);

        // Reorder the connect equations to have non-expandable connect first:
        //   connect(non_expandable, non_expandable);
        //   connect(non_expandable, expandable);
        //   connect(expandable, non_expandable);
        //   connect(expandable, expandable);
        ErrorExt.setCheckpoint("expandableConnectorsOrder");
        (cache, eqs_1) = orderConnectEquationsPutNonExpandableFirst(cache, env5, ih, pre, eqs_1, impl);
        ErrorExt.rollBack("expandableConnectorsOrder");
        
        //Instantiate equations (see function "instEquation")
        (cache,env5,ih,dae2,csets2,ci_state3,graph) =
          instList(cache, env5, ih, mods, pre, csets1, ci_state2, InstSection.instEquation, eqs_1, impl, alwaysUnroll, graph) ;

        //Instantiate inital equations (see function "instInitialEquation")
        (cache,env5,ih,dae3,csets3,ci_state4,graph) =
          instList(cache, env5, ih, mods, pre, csets2, ci_state3, InstSection.instInitialEquation, initeqs_1, impl, alwaysUnroll, graph);

        // do NOT unroll for loops for functions!
        unrollForLoops = Util.if_(SCode.isFunctionOrExtFunction(re), neverUnroll, alwaysUnroll);
        
        //Instantiate algorithms  (see function "instAlgorithm")
        (cache,env5,ih,dae4,csets4,ci_state5,graph) = 
          instList(cache,env5,ih, mods, pre, csets3, ci_state4, InstSection.instAlgorithm, alg_1, impl, unrollForLoops, graph);

        //Instantiate algorithms  (see function "instInitialAlgorithm")
        (cache,env5,ih,dae5,csets5,ci_state6,graph) =
          instList(cache,env5,ih, mods, pre, csets4, ci_state5, InstSection.instInitialAlgorithm, initalg_1, impl, unrollForLoops, graph);

        //Collect the DAE's
        dae = DAEUtil.joinDaeLst({dae1,dae2,dae3,dae4,dae5});

        //Change outer references to corresponding inner reference
        // adrpo: TODO! FIXME! very very very expensive function, try to get rid of it!
        //t1 = clock();
        //(dae,csets5,ih,graph) = InnerOuter.changeOuterReferences(dae,csets5,ih,graph);
        //t2 = clock();
        //ti = t2 -. t1;
        //Debug.fprintln("innerouter", " INST_CLASS: (" +& realString(ti) +& ") -> " +& PrefixUtil.printPrefixStr(pre) +& "." +&  className +& " mods: " +& Mod.printModStr(mods) +& " in env: " +& Env.printEnvPathStr(env5));

        csets5 = InnerOuter.changeInnerOuterInOuterConnect(csets5);
        
        // adrpo: moved bunch of a lot of expensive unit checking operations to this function
        (cache,env5,store) = handleUnitChecking(cache,env5,store,csets5,pre,dae1,{dae2,dae3,dae4,dae5},className);

        UnitParserExt.rollback(); // print("rollback for "+&className+&"\n");

        // Search for equalityConstraint
        eqConstraint = equalityConstraint(env5, els, info);
      then
        (cache,env5,ih,store,dae,csets5,ci_state6,vars,MetaUtil.fixUniontype(ci_state6,NONE()/* no basictype bc*/,inClassDef6),NONE(),eqConstraint,graph);

    // This rule describes how to instantiate class definition derived from an enumeration 
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TPATH(path = cn,arrayDim = ad),modifications = mod,attributes=DA),
          re,vis,partialPrefix,encapsulatedPrefix,inst_dims,impl,callscope,graph,instSingleCref,info,stopInst)
      equation
        false = Util.getStatefulBoolean(stopInst);

        (cache,(c as SCode.CLASS(name=cn2,info=info2,encapsulatedPrefix=enc2,restriction=r as SCode.R_ENUMERATION())), cenv) =
          Lookup.lookupClass(cache, env, cn, true);
        
        // keep the old behaviour 
        env3 = Env.openScope(cenv, enc2, SOME(cn2), SOME(Env.CLASS_SCOPE()));
        ci_state2 = ClassInf.start(r, Env.getEnvName(env3));
        new_ci_state = ClassInf.start(r, Env.getEnvName(env3));
        
        // print("Enum Env: " +& Env.printEnvPathStr(env3) +& "\n");
        
        (cache,cenv_2,_,_,_,_,_,_,_,_,_,_) =
        instClassIn(
          cache,env3,InnerOuter.emptyInstHierarchy,UnitAbsyn.noStore,
          DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet,
          ci_state2, c, SCode.PUBLIC(), {}, false, callscope, ConnectionGraph.EMPTY,NONE());


        (cache,mod_1) = Mod.elabMod(cache, cenv_2, ih, pre, mod, impl, info);
        
        mods_1 = Mod.merge(mods, mod_1, cenv_2, pre);
        eq = Mod.modEquation(mods_1) "instantiate array dimensions" ;
        (cache,dims) = elabArraydimOpt(cache,cenv_2, Absyn.CREF_IDENT("",{}),cn, ad, eq, impl,NONE(),true,pre,info,inst_dims) "owncref not valid here" ;
        inst_dims2 = instDimExpLst(dims, impl);
        inst_dims_1 = Util.listListAppendLast(inst_dims, inst_dims2);
        (cache,env_2,ih,store,dae,csets_1,ci_state_1,vars,bc,oDA,eqConstraint,graph) = instClassIn(cache, cenv_2, ih, store, mods_1, pre, csets, new_ci_state, c, vis,
                    inst_dims_1, impl, callscope, graph, instSingleCref) "instantiate class in opened scope.";
        ClassInf.assertValid(ci_state_1, re, info) "Check for restriction violations";
        oDA = SCode.mergeAttributes(DA,oDA);
      then
        (cache,env_2,ih,store,dae,csets_1,ci_state_1,vars,bc,oDA,eqConstraint,graph);

    // This rule describes how to instantiate a derived class definition from basic types 
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TPATH(path = cn,arrayDim = ad),modifications = mod,attributes=DA),
          re,vis,partialPrefix,encapsulatedPrefix,inst_dims,impl,callscope,graph,instSingleCref,info,stopInst)
      equation
        false = Util.getStatefulBoolean(stopInst);

        (cache,(c as SCode.CLASS(name=cn2,encapsulatedPrefix=enc2,restriction=r,classDef=classDef)),cenv) = Lookup.lookupClass(cache, env, cn, true);

        // if is a basic type or derived from it, follow the normal path
        true = checkDerivedRestriction(re, r, cn2);

        cenv_2 = Env.openScope(cenv, enc2, SOME(cn2), Env.classInfToScopeType(ci_state));
        new_ci_state = ClassInf.start(r, Env.getEnvName(cenv_2));
        
        (cache,mod_1) = Mod.elabMod(cache, env, ih, pre, mod, impl, info);
        mods_1 = Mod.merge(mods, mod_1, cenv_2, pre);
        eq = Mod.modEquation(mods_1) "instantiate array dimensions" ;
        (cache,dims) = elabArraydimOpt(cache,cenv_2, Absyn.CREF_IDENT("",{}),cn, ad, eq, impl,NONE(),true,pre,info,inst_dims) "owncref not valid here" ;
        inst_dims2 = instDimExpLst(dims, impl);
        inst_dims_1 = Util.listListAppendLast(inst_dims, inst_dims2);
        (cache,env_2,ih,store,dae,csets_1,ci_state_1,vars,bc,oDA,eqConstraint,graph) = instClassIn(cache, cenv_2, ih, store, mods_1, pre, csets, new_ci_state, c, vis,
                    inst_dims_1, impl, callscope, graph, instSingleCref) "instantiate class in opened scope. " ;
        ClassInf.assertValid(ci_state_1, re, info) "Check for restriction violations" ;
        oDA = SCode.mergeAttributes(DA,oDA);
      then
        (cache,env_2,ih,store,dae,csets_1,ci_state_1,vars,bc,oDA,eqConstraint,graph);

    // This rule describes how to instantiate a derived class definition 
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TPATH(path = cn,arrayDim = ad),modifications = mod,attributes=DA),
          re,vis,partialPrefix,encapsulatedPrefix,inst_dims,impl,callscope,graph,instSingleCref,info,stopInst)
      equation
        false = Util.getStatefulBoolean(stopInst);

        (cache,(c as SCode.CLASS(name=cn2,encapsulatedPrefix=enc2,restriction=r,classDef=classDef)),cenv) = Lookup.lookupClass(cache, env, cn, true);

        // not a basic type, change class name! 
        false = checkDerivedRestriction(re, r, cn2);

        // change the class name to className!!
        // package A2=A
        // package A3=A(mods)
        // will get you different function implementations for the different packages!
        c = SCode.setClassName(className, c);

        // do not open a new env!
        //cenv_2 = env;
        //new_ci_state = ci_state;
        cenv_2 = Env.openScope(cenv, enc2, SOME(className), Env.classInfToScopeType(ci_state));
        new_ci_state = ClassInf.start(r, Env.getEnvName(cenv_2));
        
        //print("Derived Env: " +& Env.printEnvPathStr(cenv_2) +& "\n");
        
        (cache,mod_1) = Mod.elabMod(cache, env, ih, pre, mod, impl, info);
        mods_1 = Mod.merge(mods, mod_1, cenv_2, pre);
        eq = Mod.modEquation(mods_1) "instantiate array dimensions" ;
        (cache,dims) = elabArraydimOpt(cache,cenv_2, Absyn.CREF_IDENT("",{}), cn, ad, eq, impl,NONE(),true,pre,info,inst_dims) "owncref not valid here" ;
        inst_dims2 = instDimExpLst(dims, impl);
        inst_dims_1 = Util.listListAppendLast(inst_dims, inst_dims2);
        (cache,env_2,ih,store,dae,csets_1,ci_state_1,vars,bc,oDA,eqConstraint,graph) = instClassIn(cache, cenv_2, ih, store, mods_1, pre, csets, new_ci_state, c, vis,
                    inst_dims_1, impl, callscope, graph, instSingleCref) "instantiate class in opened scope. " ;
        ClassInf.assertValid(ci_state_1, re, info) "Check for restriction violations" ;
        oDA = SCode.mergeAttributes(DA,oDA);
      then
        (cache,env_2,ih,store,dae,csets_1,ci_state_1,vars,bc,oDA,eqConstraint,graph);

    // MetaModelica extension
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TCOMPLEX(path=_),modifications = mod),
          re,vis,partialPrefix,encapsulatedPrefix,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        false = Mod.emptyModOrEquality(mods) and SCode.emptyModOrEquality(mod);
        Error.addSourceMessage(Error.META_COMPLEX_TYPE_MOD, {}, info);
      then fail();

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT("list"),{tSpec},NONE()),modifications = mod, attributes=DA),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        false = Util.getStatefulBoolean(stopInst);
        true = Mod.emptyModOrEquality(mods) and SCode.emptyModOrEquality(mod);
        (cache,cenv,ih,tys,csets,oDA) =
        instClassDefHelper(cache,env,ih,{tSpec},pre,inst_dims,impl,{},csets);
        ty = Util.listFirst(tys);
        ty = Types.boxIfUnboxedType(ty);
        bc = SOME((DAE.T_LIST(ty),NONE()));
        oDA = SCode.mergeAttributes(DA,oDA);
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ClassInf.META_LIST(Absyn.IDENT("")),{},bc,oDA,NONE(),graph);

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT("Option"),{tSpec},NONE()),modifications = mod, attributes=DA),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        false = Util.getStatefulBoolean(stopInst);
        true = Mod.emptyModOrEquality(mods) and SCode.emptyModOrEquality(mod);
        (cache,cenv,ih,{ty},csets,oDA) =
        instClassDefHelper(cache,env,ih,{tSpec},pre,inst_dims,impl,{},csets);
        ty = Types.boxIfUnboxedType(ty);
        bc = SOME((DAE.T_METAOPTION(ty),NONE()));
        oDA = SCode.mergeAttributes(DA,oDA);
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ClassInf.META_OPTION(Absyn.IDENT("")),{},bc,oDA,NONE(),graph);

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT("tuple"),tSpecs,NONE()),modifications = mod, attributes=DA),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        false = Util.getStatefulBoolean(stopInst);
        true = Mod.emptyModOrEquality(mods) and SCode.emptyModOrEquality(mod);
        (cache,cenv,ih,tys,csets,oDA) = instClassDefHelper(cache,env,ih,tSpecs,pre,inst_dims,impl,{},csets);
        tys = Util.listMap(tys, Types.boxIfUnboxedType);
        bc = SOME((DAE.T_METATUPLE(tys),NONE()));
        oDA = SCode.mergeAttributes(DA,oDA);
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ClassInf.META_TUPLE(Absyn.IDENT("")),{},bc,oDA,NONE(),graph);

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT("array"),{tSpec},NONE()),modifications = mod, attributes=DA),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        false = Util.getStatefulBoolean(stopInst);
        true = Mod.emptyModOrEquality(mods) and SCode.emptyModOrEquality(mod);
        (cache,cenv,ih,{ty},csets,oDA) = instClassDefHelper(cache,env,ih,{tSpec},pre,inst_dims,impl,{},csets);
        ty = Types.boxIfUnboxedType(ty);
        bc = SOME((DAE.T_META_ARRAY(ty),NONE()));
        oDA = SCode.mergeAttributes(DA,oDA);
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ClassInf.META_ARRAY(Absyn.IDENT(className)),{},bc,oDA,NONE(),graph);

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT("polymorphic"),{Absyn.TPATH(Absyn.IDENT("Any"),NONE())},NONE()),modifications = mod, attributes=DA),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        false = Util.getStatefulBoolean(stopInst);
        true = Mod.emptyModOrEquality(mods) and SCode.emptyModOrEquality(mod);
        (cache,cenv,ih,tys,csets,oDA) = instClassDefHelper(cache,env,ih,{},pre,inst_dims,impl,{},csets);
        bc = SOME((DAE.T_POLYMORPHIC(className),NONE()));
        oDA = SCode.mergeAttributes(DA,oDA);
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ClassInf.META_POLYMORPHIC(Absyn.IDENT(className)),{},bc,oDA,NONE(),graph);

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(typeSpec=Absyn.TCOMPLEX(path=Absyn.IDENT("polymorphic")),modifications=mod),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        true = Mod.emptyModOrEquality(mods) and SCode.emptyModOrEquality(mod);
        Error.addSourceMessage(Error.META_POLYMORPHIC, {className}, info);
      then fail();

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(typeSpec=tSpec as Absyn.TCOMPLEX(arrayDim=SOME(_)),modifications=mod),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        cns = Dump.unparseTypeSpec(tSpec);
        Error.addSourceMessage(Error.META_INVALID_COMPLEX_TYPE, {cns}, info);
      then fail();

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT(str),tSpecs,NONE()),modifications = mod, attributes=DA),
          re,vis,partialPrefix,encapsulatedPrefix,inst_dims,impl,inCallingScope,graph,instSingleCref,info,stopInst)
      equation
        str = Util.assoc(str,{("List","list"),("Tuple","tuple"),("Array","array")});
        (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph)
        =instClassdef2(cache,env,ih,store,mods,pre,csets,ci_state,className,SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT(str),tSpecs,NONE()),mod,DA,NONE()),re,vis,partialPrefix,encapsulatedPrefix,inst_dims,impl,inCallingScope,graph,instSingleCref,info,stopInst);
      then (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outTypesTypeOption,optDerAttr,outEqualityConstraint,outGraph);

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(typeSpec=tSpec as Absyn.TCOMPLEX(path=cn,typeSpecs=tSpecs),modifications=mod),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        false = listMember((Absyn.pathString(cn),listLength(tSpecs)==1), {("tuple",false),("array",true),("Option",true),("list",true)});
        cns = Dump.unparseTypeSpec(tSpec);
        Error.addSourceMessage(Error.META_INVALID_COMPLEX_TYPE, {cns}, info);
      then fail();

    /* ----------------------- */

    /* If the class is derived from a class that can not be found in the environment, this rule prints an error message. */
    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TPATH(path = cn, arrayDim = ad),modifications = mod),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        false = Util.getStatefulBoolean(stopInst);
        failure((_,_,_) = Lookup.lookupClass(cache,env, cn, false));
        cns = Absyn.pathString(cn);
        scope_str = Env.printEnvPathStr(env);
        Error.addSourceMessage(Error.LOOKUP_ERROR, {cns,scope_str}, info);
      then
        fail();

    case (cache,env,ih,store,mods,pre,csets,ci_state,className,
          SCode.DERIVED(Absyn.TPATH(path = cn, arrayDim = ad),modifications = mod),
          re,vis,_,_,inst_dims,impl,_,graph,instSingleCref,info,stopInst)
      equation
        true = RTOpts.debugFlag("failtrace");
        failure((_,_,_) = Lookup.lookupClass(cache,env, cn, false));
        Debug.fprint("failtrace", "- Inst.instClassdef DERIVED( ");
        Debug.fprint("failtrace", Absyn.pathString(cn));
        Debug.fprint("failtrace", ") lookup failed\n ENV:");
        Debug.fprint("failtrace",Env.printEnvStr(env));
      then
        fail();

    case (_,env,ih,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,instSingleCref,info,stopInst)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.instClassdef failed");
        s = Env.printEnvPathStr(env);
        Debug.traceln("  class :" +& s);
        // Debug.traceln("  Env :" +& Env.printEnvStr(env));
      then
        fail();
  end matchcontinue;
end instClassdef2;

protected function matchModificationToComponents "
Author: BZ, 2009-05
This function is called from instClassDef, recursivly remove modifers on each component.
What ever is left in modifier is printed as a warning. That means that we have modifiers on a component that does not exist."
  input list<SCode.Element> elems;
  input DAE.Mod inmod;
  input String callingScope;
algorithm 
  _ := matchcontinue(elems, inmod,callingScope)
    local
      SCode.Element elem;
      String cn,s1,s2;
    
    case({},DAE.NOMOD(),_) then ();
    case({},DAE.MOD(subModLst={}),_) then ();
    
    case({},inmod,callingScope)
      equation
        s1 = Mod.prettyPrintMod(inmod,0);
        s2 = s1 +& " not found in <" +& callingScope +& ">";
        // Line below can be used for testing test-suite for dangeling modifiers when getErrorString() is not called.
        //print(" *** ERROR Unused modifer...: " +& s2 +& "\n");
        Error.addMessage(Error.UNUSED_MODIFIER,{s2});
      then fail();
    
    case((elem as SCode.COMPONENT(name=cn))::elems,inmod,callingScope)
      equation
        inmod = Types.removeMod(inmod,cn);
        matchModificationToComponents(elems,inmod,callingScope);
      then
        ();
    
    case((elem as SCode.EXTENDS(modifications=_))::elems,inmod,callingScope)
      equation matchModificationToComponents(elems,inmod,callingScope); then ();
        //TODO: only remove modifiers on replaceable classes, make special case for redeclaration of local classes
    
    case((elem as SCode.CLASS(name=cn,prefixes=SCode.PREFIXES(replaceablePrefix=_/*SCode.REPLACEABLE(_)*/)))::elems,inmod,callingScope)
      equation
        inmod = Types.removeMod(inmod,cn);
        matchModificationToComponents(elems,inmod,callingScope);
      then ();
    
    case((elem as SCode.IMPORT(imp=_))::elems,inmod,callingScope)
      equation 
        matchModificationToComponents(elems,inmod,callingScope); 
      then ();
        
    case( (elem as SCode.CLASS(prefixes=SCode.PREFIXES(replaceablePrefix=SCode.NOT_REPLACEABLE())))::elems,inmod,callingScope)
      equation
        matchModificationToComponents(elems,inmod,callingScope);
      then ();
  end matchcontinue;
end matchModificationToComponents;

protected function extractConstantPlusDeps "
Author: BZ, 2009-04
This function filters the list of elements to instantiate depending on optional(DAE.ComponentRef), the
optional argument is set in Lookup.lookupVarInPackages.
If it is set, we are only looking for one variable in current scope hence we are not interested in
instantiating more then nescessary.

The actuall action of this function is to compare components to the DAE.ComponentRef name
if it is found return that component and any dependant components(modifiers), this is done by calling the function recursivly.

If the component specified in argument 2 is not found, we return all extend and import statements.
TODO: search import and extends statements for specified variable.
      this includes to check class definitions to so that we do not need to instantiate local class definitions while looking for a constant."
  input list<SCode.Element> inComps;
  input Option<DAE.ComponentRef> ocr;
  input list<SCode.Element> allComps;
  input String className;
  output list<SCode.Element> outComps;
algorithm 
  outComps := matchcontinue(inComps, ocr, allComps, className)
    local 
      DAE.ComponentRef cr;
    
    // handle empty!
    // case({}, _, allComps, className) then {};
    
    // handle none
    case(inComps,NONE(), allComps, className) then inComps;

    // handle StateSelect as we will NEVER find it! 
    // case(inComps, SOME(DAE.CREF_QUAL(ident="StateSelect")), allComps, className) then inComps;

    // handle some
    case(inComps, ocr as SOME(cr), allComps, className)
      equation
        outComps = extractConstantPlusDeps2(inComps, ocr, allComps, className,{});
        true = listLength(outComps) >= 1;
        outComps = listReverse(outComps);
      then
        outComps;
  
    case(inComps, SOME(cr), allComps, className)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprint("failtrace", "- Inst.extractConstantPlusDeps failure to find " +& ComponentReference.printComponentRefStr(cr) +& ", returning \n");
        Debug.fprint("failtrace", "- Inst.extractConstantPlusDeps elements to instantiate:" +& intString(listLength(inComps)) +& "\n");
      then
        inComps;
  end matchcontinue;
end extractConstantPlusDeps;

protected function extractConstantPlusDeps2 "
Author: BZ, 2009-04
Helper function for extractConstantPlusDeps"
  input list<SCode.Element> inComps;
  input Option<DAE.ComponentRef> ocr;
  input list<SCode.Element> allComps;
  input String className;
  input list<String> existing;
  output list<SCode.Element> outComps;
algorithm
  outComps := matchcontinue(inComps, ocr,allComps,className,existing)
    local
      SCode.Element compMod;
      list<SCode.Element> recDeps;
      SCode.Element selem;
      String name,name2;
      SCode.Mod scmod;
      DAE.ComponentRef cr;
      list<Absyn.ComponentRef> crefs;
      Absyn.Path p;

    case({},SOME(cr),_,_,_)
      equation
        //print(" failure to find: " +& ComponentReference.printComponentRefStr(cr) +& " in scope: " +& className +& "\n");
      then {};
    case({},_,_,_,_) then fail();
    case(inComps,NONE(),_,_,_) then inComps;
      /*
    case( (selem as SCode.CLASS(name=name2))::inComps,SOME(DAE.CREF_IDENT(ident=name)),allComps,className,existing)
      equation
        true = stringEq(name,name2);
        outComps = extractConstantPlusDeps2(inComps,ocr,allComps,className,existing);
      then
        selem::outComps;
        */
    case( ((selem as SCode.CLASS(name=name2)))::inComps,SOME(DAE.CREF_IDENT(ident=name)),allComps,className,existing)
      equation
        //false = stringEq(name,name2);
        allComps = selem::allComps;
        existing = name2::existing;
        outComps = extractConstantPlusDeps2(inComps,ocr,allComps,className,existing);
      then //extractConstantPlusDeps2(inComps,ocr,allComps,className,existing);
         selem::outComps;

    case((selem as SCode.COMPONENT(name=name2,modifications=scmod))::inComps,SOME(DAE.CREF_IDENT(ident=name)),allComps,className,existing)
      equation
        true = stringEq(name,name2);
        crefs = getCrefFromMod(scmod);
        allComps = listAppend(inComps,allComps);
        existing = name2::existing;
        recDeps = extractConstantPlusDeps3(crefs,allComps,className,existing);
      then
        selem::recDeps;

    case( ( (selem as SCode.COMPONENT(name=name2)))::inComps,SOME(DAE.CREF_IDENT(ident=name)),allComps,className,existing)
      equation
        false = stringEq(name,name2);
        allComps = selem::allComps;
      then extractConstantPlusDeps2(inComps,ocr,allComps,className,existing);

    case((compMod as SCode.EXTENDS(baseClassPath=p))::inComps,(ocr as SOME(DAE.CREF_IDENT(ident=_))),allComps,className,existing)
      equation
        allComps = compMod::allComps;
        recDeps = extractConstantPlusDeps2(inComps,ocr,allComps,className,existing);
        then
          compMod::recDeps;
    case((compMod as SCode.IMPORT(imp=_))::inComps,(ocr as SOME(DAE.CREF_IDENT(ident=_))),allComps,className,existing)
      equation
        allComps = compMod::allComps;
        recDeps = extractConstantPlusDeps2(inComps,ocr,allComps,className,existing);
      then
        compMod::recDeps;

    case((compMod as SCode.DEFINEUNIT(name=_))::inComps,(ocr as SOME(DAE.CREF_IDENT(ident=_))),allComps,className,existing)
      equation
        allComps = compMod::allComps;
        recDeps = extractConstantPlusDeps2(inComps,ocr,allComps,className,existing);
      then
        compMod::recDeps;
    case(inComps, ocr, allComps, className, existing)
      equation
        //debug_print("all",  (inComps, ocr, allComps, className, existing));
        print(" failure in get_Constant_PlusDeps \n");
      then fail();
end matchcontinue;
end extractConstantPlusDeps2;

protected function extractConstantPlusDeps3 "
Author: BZ, 2009-04
Helper function for extractConstantPlusDeps
"
input list<Absyn.ComponentRef> acrefs;
input list<SCode.Element> remainingComps;
input String className;
input list<String> existing;
output list<SCode.Element> outComps;
algorithm outComps := matchcontinue(acrefs,remainingComps,className,existing)
  local
    String s1,s2;
    Absyn.ComponentRef acr;
    list<SCode.Element> localComps;
    list<String> names;
    DAE.ComponentRef cref_;
  case({},_,_,_) then {};

  case (Absyn.CREF_FULLYQUALIFIED(acr) :: acrefs, remainingComps, className, existing)
    then extractConstantPlusDeps3(acr :: acrefs, remainingComps, className, existing);

  case(Absyn.CREF_QUAL(s1,_,(acr as Absyn.CREF_IDENT(s2,_)))::acrefs,remainingComps,className,existing)
    equation
      true = stringEq(className,s1); // in same scope look up.
      acrefs = acr::acrefs;
    then
      extractConstantPlusDeps3(acrefs,remainingComps,className,existing);
  case((acr as Absyn.CREF_QUAL(s1,_,_))::acrefs,remainingComps,className,existing)
    equation
      false = stringEq(className,s1);
      outComps = extractConstantPlusDeps3(acrefs,remainingComps,className,existing);
    then
      outComps;
  case(Absyn.CREF_IDENT(s1,_)::acrefs,remainingComps,className,existing) // modifer dep already added
    equation
      true = Util.listContainsWithCompareFunc(s1,existing,stringEq);
    then
      extractConstantPlusDeps3(acrefs,remainingComps,className,existing);
  case(Absyn.CREF_IDENT(s1,_)::acrefs,remainingComps,className,existing)
    equation
      cref_ = ComponentReference.makeCrefIdent(s1,DAE.ET_OTHER(),{});
      localComps = extractConstantPlusDeps2(remainingComps,SOME(cref_),{},className,existing);
      names = SCode.componentNamesFromElts(localComps);
      existing = listAppend(names,existing);
      outComps = extractConstantPlusDeps3(acrefs,remainingComps,className,existing);
      outComps = listAppend(localComps,outComps);
    then
      outComps;
  end matchcontinue;
end extractConstantPlusDeps3;

public function removeSelfReference
"@author adrpo
 Removes self reference from a path if it exists.
 Examples:
   removeSelfReference('Icons', 'Icons.BaseLibrary') => 'BaseLibrary'
   removeSelfReference('Icons', 'BlaBla.BaseLibrary') => 'BlaBla.BaseLibrary'"
  input  String     className;
  input  Absyn.Path path;
  output Absyn.Path outPath;
algorithm
  outPath := matchcontinue (className, path)
    local
      String clsName;
      Absyn.Path p, newPath;
    case(clsName, p) // self reference, remove the first.
      equation
        true = stringEq(clsName, Absyn.pathFirstIdent(p));
        newPath = Absyn.removePrefix(Absyn.IDENT(clsName), p);
      then
        newPath;
    case(clsName, p) // not self reference, return the same.
      equation
        false = stringEq(clsName, Absyn.pathFirstIdent(p));
      then
        p;
  end matchcontinue;
end removeSelfReference;

protected function instClassDefHelper
"Function: instClassDefHelper
 MetaModelica extension. KS TODO: Document this function!!!!"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input list<Absyn.TypeSpec> inSpecs;
  input Prefix.Prefix inPre;
  input InstDims inDims;
  input Boolean inImpl;
  input list<DAE.Type> accTypes;
  input Connect.Sets inCSets;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output list<DAE.Type> outType;
  output Connect.Sets outSets;
  output Option<SCode.Attributes> outAttr;
algorithm
  (outCache,outEnv,outIH,outType,outSets,outAttr) :=
  matchcontinue (inCache,inEnv,inIH,inSpecs,inPre,inDims,inImpl,accTypes,inCSets)
    local
      Env.Cache cache;
      Env.Env env,cenv;
      Prefix.Prefix pre;
      InstDims dims;
      Boolean impl;
      list<DAE.Type> localAccTypes;
      list<Absyn.TypeSpec> restTypeSpecs;
      Connect.Sets csets;
      Absyn.Path cn;
      DAE.Type ty;
      Absyn.Path p;
      SCode.Element c;
      Absyn.Ident id;
      Absyn.TypeSpec tSpec;
      Option<SCode.Attributes> oDA;
      InstanceHierarchy ih;

    case (cache,env,ih,{},_,_,_,localAccTypes,csets)
      then (cache,env,ih,listReverse(localAccTypes),csets,NONE());

    case (cache,env,ih, Absyn.TPATH(cn,_) :: restTypeSpecs,pre,dims,impl,localAccTypes,csets)
      equation
        (cache,(c as SCode.CLASS(name = _)),cenv) = Lookup.lookupClass(cache,env, cn, true);
        false = SCode.isFunction(c);
        (cache,cenv,ih,_,_,csets,ty,_,oDA,_)=instClass(cache,cenv,ih,UnitAbsyn.noStore,DAE.NOMOD(),pre,csets,c,dims,impl,INNER_CALL(), ConnectionGraph.EMPTY);
        localAccTypes = ty::localAccTypes;
        (cache,env,ih,localAccTypes,csets,_) =
        instClassDefHelper(cache,env,ih,restTypeSpecs,pre,dims,impl,localAccTypes,csets);
      then (cache,env,ih,localAccTypes,csets,oDA);

    case (cache,env,ih, Absyn.TPATH(cn,_) :: restTypeSpecs,pre,dims,impl,localAccTypes,csets)
      equation
        (cache,ty,_) = Lookup.lookupType(cache,env,cn,NONE()) "For functions, etc";
        localAccTypes = ty::localAccTypes;
        (cache,env,ih,localAccTypes,csets,_) =
        instClassDefHelper(cache,env,ih,restTypeSpecs,pre,dims,impl,localAccTypes,csets);
      then (cache,env,ih,localAccTypes,csets,NONE());

    case (cache,env,ih, (tSpec as Absyn.TCOMPLEX(p,_,_)) :: restTypeSpecs,pre,dims,impl,localAccTypes,csets)
      equation
        id=Absyn.pathString(p);
        c = SCode.CLASS(id,SCode.defaultPrefixes,
                        SCode.NOT_ENCAPSULATED(),
                        SCode.NOT_PARTIAL(),
                        SCode.R_TYPE(),
                        SCode.DERIVED(
                          tSpec,SCode.NOMOD(),
                          SCode.ATTR({}, SCode.NOT_FLOW(), SCode.NOT_STREAM(),  SCode.VAR(), Absyn.BIDIR()),
                          NONE()),
                        Absyn.dummyInfo);
        (cache,cenv,ih,_,_,csets,ty,_,oDA,_)=instClass(cache,env,ih,UnitAbsyn.noStore,DAE.NOMOD(),pre,csets,c,dims,impl,INNER_CALL(), ConnectionGraph.EMPTY);
        localAccTypes = ty::localAccTypes;
        (cache,env,ih,localAccTypes,csets,_) = instClassDefHelper(cache,env,ih,restTypeSpecs,pre,dims,impl,localAccTypes,csets);
      then (cache,env,ih,localAccTypes,csets,oDA);
  end matchcontinue;
end instClassDefHelper;

protected function instantiateExternalObject
"instantiate an external object.
 This is done by instantiating the destructor and constructor
 functions and create a DAE element containing these two."
  input Env.Cache inCache;
  input Env.Env env "environment";
  input InstanceHierarchy inIH;
  input list<SCode.Element> els "elements";
  input Boolean impl;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist dae "resulting dae";
  output ClassInf.State ciState;
algorithm
  (outCache,outEnv,outIH,dae,ciState) := matchcontinue(inCache,env,inIH,els,impl)
    local
      SCode.Element destr,constr;
      DAE.Function destr_dae,constr_dae;
      Env.Env env1;
      Env.Cache cache;
      Ident className;
      Absyn.Path classNameFQ;
      DAE.Type functp;
      Env.Frame f;
      list<Env.Frame> fs,fs1;
      InstanceHierarchy ih;
      DAE.ElementSource source "the origin of the element";
      // Explicit instantiation, generate constructor and destructor and the function type.
    case  (cache,env,ih,els,false)
      equation
        destr = getExternalObjectDestructor(els);
        constr = getExternalObjectConstructor(els);
        (cache,ih) = instantiateExternalObjectDestructor(cache,env,ih,destr);
        (cache,ih,functp) = instantiateExternalObjectConstructor(cache,env,ih,constr);
        className=Env.getClassName(env); // The external object classname is in top frame of environment.
        SOME(classNameFQ)= Env.getEnvPath(env); // Fully qualified classname
        // Extend the frame with the type, one frame up at the same place as the class.
        f::fs = env;
        fs1 = Env.extendFrameT(fs,className,functp);
        env1 = f::fs1;
        
        // set the  of this element
       source = DAEUtil.addElementSourcePartOfOpt(DAE.emptyElementSource, Env.getEnvPath(env));
      then
        (cache,env1,ih,DAE.DAE({DAE.EXTOBJECTCLASS(classNameFQ,source)}),ClassInf.EXTERNAL_OBJ(classNameFQ));

    // Implicit, do not instantiate constructor and destructor.
    case (cache,env,ih,els,true)
      equation
        SOME(classNameFQ)= Env.getEnvPath(env); // Fully qualified classname
      then
        (cache,env,ih,DAEUtil.emptyDae,ClassInf.EXTERNAL_OBJ(classNameFQ));

    // failed
    case (cache,env,ih,els,impl)
      equation
        print("Inst.instantiateExternalObject failed\n");
      then fail();
  end matchcontinue;
end instantiateExternalObject;

protected function instantiateExternalObjectDestructor
"instantiates the destructor function of an external object"
  input Env.Cache inCache;
  input Env.Env env;
  input InstanceHierarchy inIH;
  input SCode.Element cl;
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
algorithm  
  (outCache,outIH) := matchcontinue (inCache,env,inIH,cl)
    local
      Env.Cache cache;
      Env.Env env1;
      InstanceHierarchy ih;

    case (cache,env,ih,cl)
      equation
        (cache,env1,ih) = implicitFunctionInstantiation(cache,env,ih,DAE.NOMOD(),Prefix.NOPRE(),Connect.emptySet,cl,{});
      then
        (cache,ih);
    // failure
    case (cache,env,ih,cl)
      equation
        print("Inst.instantiateExternalObjectDestructor failed\n");
      then fail();
   end matchcontinue;
end instantiateExternalObjectDestructor;

protected function instantiateExternalObjectConstructor
"instantiates the constructor function of an external object"
  input Env.Cache inCache;
  input Env.Env env;
  input InstanceHierarchy inIH;
  input SCode.Element cl;
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
  output DAE.Type ty;
algorithm
  (outCache,outIH,ty) := matchcontinue (inCache,env,inIH,cl)
    local
      Env.Cache cache;
      Env.Env env1;
      DAE.Type ty;
      InstanceHierarchy ih;

    case (cache,env,ih,cl)
      equation
        (cache,env1,ih) = implicitFunctionInstantiation(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, cl, {});
        (cache,ty,_) = Lookup.lookupType(cache,env1,Absyn.IDENT("constructor"),NONE());
      then
        (cache,ih,ty);
    case (cache,env,ih,cl)
      equation
        print("Inst.instantiateExternalObjectConstructor failed\n");
      then fail();
  end matchcontinue;
end instantiateExternalObjectConstructor;

public function classIsExternalObject
"returns true if a Class fulfills the requirements of an external object"
  input SCode.Element cl;
  output Boolean res;
algorithm
  res := matchcontinue (cl)
  local list<SCode.Element> els;
    case SCode.CLASS(classDef=SCode.PARTS(elementLst=els))
      equation
        res = isExternalObject(els);
     then res;
    case (_) then false;
  end matchcontinue;
end classIsExternalObject;

public function isExternalObject
"Returns true if the element list fulfills the condition of an External Object.
An external object extends the builtinClass ExternalObject, and has two local
functions, destructor and constructor. "
input  list<SCode.Element> els;
output Boolean res;
algorithm
 res := matchcontinue(els)
 case (els)
   equation
    true = hasExtendsOfExternalObject(els);
    true = hasExternalObjectDestructor(els);
    true = hasExternalObjectConstructor(els);
    3 = listLength(els);
  then true;
  case (_) then false;
  end matchcontinue;
end isExternalObject;

protected function hasExtendsOfExternalObject
"returns true if element list contains 'extends ExternalObject;'"
  input list<SCode.Element> els;
  output Boolean res;
algorithm
  res:= matchcontinue(els)
    case SCode.EXTENDS(baseClassPath = Absyn.IDENT("ExternalObject"))::_ then true;
    case _::els then hasExtendsOfExternalObject(els);
    case _ then false;
  end matchcontinue;
end hasExtendsOfExternalObject;

protected function hasExternalObjectDestructor
"returns true if element list contains 'function destructor .. end destructor'"
  input list<SCode.Element> els;
  output Boolean res;
algorithm
  res:= matchcontinue(els)
    case SCode.CLASS(name="destructor")::_ then true;
    case _::els then hasExternalObjectDestructor(els);
    case _ then false;
  end matchcontinue;
end hasExternalObjectDestructor;

protected function hasExternalObjectConstructor
"returns true if element list contains 'function constructor ... end constructor'"
  input list<SCode.Element> els;
  output Boolean res;
algorithm
  res:= matchcontinue(els)
    case SCode.CLASS(name="constructor")::_ then true;
    case _::els then hasExternalObjectConstructor(els);
    case _ then false;
  end matchcontinue;
end hasExternalObjectConstructor;

protected function getExternalObjectDestructor
"returns the class 'function destructor .. end destructor' from element list"
  input list<SCode.Element> els;
  output SCode.Element cl;
algorithm
  cl:= matchcontinue(els)
    case ((cl as SCode.CLASS(name="destructor"))::_) then cl;
    case (_::els) then getExternalObjectDestructor(els);
  end matchcontinue;
end getExternalObjectDestructor;

protected function getExternalObjectConstructor
"returns the class 'function constructor ... end constructor' from element list"
input list<SCode.Element> els;
output SCode.Element cl;
algorithm
  cl:= matchcontinue(els)
    case ((cl as SCode.CLASS(name="constructor"))::_) then cl;
    case (_::els) then getExternalObjectConstructor(els);
  end matchcontinue;
end getExternalObjectConstructor;

public function printExtcomps
"prints the tuple of elements and modifiers to stdout"
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst;
algorithm
  _ := matchcontinue (inTplSCodeElementModLst)
    local
      String s;
      SCode.Element el;
      DAE.Mod mod;
      list<tuple<SCode.Element, DAE.Mod>> els;
    case ({}) then ();
    case (((el,mod) :: els))
      equation
        s = SCodeDump.printElementStr(el);
        print(s);
        print(", "); 
        print(Mod.printModStr(mod));
        print("\n");
        printExtcomps(els);
      then
        ();
  end matchcontinue;
end printExtcomps;

protected function instBasictypeBaseclass
"function: instBasictypeBaseclass
  This function finds the type of classes that extends a basic type.
  For instance,
  connector RealSignal
    extends SignalType;
    replaceable type SignalType = Real;
  end RealSignal;
  Such classes can not have any other components,
  and can only inherit one basic type."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input list<SCode.Element> inSCodeElementLst2;
  input list<SCode.Element> inSCodeElementLst3;
  input DAE.Mod inMod4;
  input InstDims inInstDims5;
  input Absyn.Info info;
  input Util.StatefulBoolean stopInst "prevent instantiation of classes adding components to primary types";
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae "contain functions";
  output Option<DAE.Type> outTypesTypeOption;
  output list<DAE.Var> outTypeVars;
algorithm
  (outCache,outIH,outStore,outDae,outTypesTypeOption,outTypeVars) :=
  matchcontinue (inCache,inEnv,inIH,store,inSCodeElementLst2,inSCodeElementLst3,inMod4,inInstDims5,info,stopInst)
    local
      DAE.Mod m_1,m_2,mods;
      SCode.Element cdef;
      list<Env.Frame> cenv,env_1,env;
      DAE.DAElist dae;
      DAE.Type ty;
      list<DAE.Var> tys;
      ClassInf.State st;
      Boolean b1,b2,b3;
      Absyn.Path path;
      SCode.Mod mod;
      InstDims inst_dims;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,env,ih,store,{SCode.EXTENDS(baseClassPath = path,modifications = mod)},{},mods,inst_dims,info,stopInst)
      equation        
        //Debug.traceln("Try instbasic 1 " +& Absyn.pathString(path));
        ErrorExt.setCheckpoint("instBasictypeBaseclass");
        (cache,m_1) = Mod.elabModForBasicType(cache, env, ih, Prefix.NOPRE(), mod, true, info);
        m_2 = Mod.merge(mods, m_1, env, Prefix.NOPRE());
        (cache,cdef,cenv) = Lookup.lookupClass(cache,env, path, true);
        //Debug.traceln("Try instbasic 2 " +& Absyn.pathString(path) +& " " +& Mod.printModStr(m_2));
        (cache,env_1,ih,store,dae,_,ty,tys,st) = instClassBasictype(cache,cenv,ih, store,m_2, Prefix.NOPRE(), Connect.emptySet, cdef, inst_dims, false, INNER_CALL());
        //Debug.traceln("Try instbasic 3 " +& Absyn.pathString(path) +& " " +& Mod.printModStr(m_2));
        b1 = Types.basicType(ty);
        b2 = Types.arrayType(ty);
        b3 = Types.extendsBasicType(ty);
        true = Util.boolOrList({b1, b2, b3});
        
        ErrorExt.rollBack("instBasictypeBaseclass");
      then
        (cache,ih,store,dae,SOME(ty),tys);
    case (cache,env,ih,store,{SCode.EXTENDS(baseClassPath = path,modifications = mod)},{},mods,inst_dims,info,stopInst)
      equation
        rollbackCheck(path) "only rollback errors affecting basic types";
      then fail();

    /* Inherits baseclass -and- has components */
    case (cache,env,ih,store,{SCode.EXTENDS(baseClassPath = path,modifications = mod)},inSCodeElementLst3,mods,inst_dims,info,stopInst)
      equation
        true = (listLength(inSCodeElementLst3) > 0);
        ErrorExt.setCheckpoint("instBasictypeBaseclass2") "rolled back or deleted inside call below";
        instBasictypeBaseclass2(cache,env,ih,store,inSCodeElementLst2,inSCodeElementLst3,mods,inst_dims,info,stopInst);
      then
        fail();
  end matchcontinue;
end instBasictypeBaseclass;

protected function rollbackCheck "
Author BZ 2009-08
Rollsback errors on builtin classes and deletes checkpoint for other classes.
"
  input Absyn.Path p;
algorithm _ := matchcontinue(p)
  local String n;
  case (p)
    equation
      n = Absyn.pathString(p);
      true = isBuiltInClass(n);
      ErrorExt.rollBack("instBasictypeBaseclass");
    then ();
  case _
    equation
      ErrorExt.rollBack("instBasictypeBaseclass"); // ErrorExt.delCheckpoint("instBasictypeBaseclass");
    then ();
end matchcontinue;
end rollbackCheck;

protected function instBasictypeBaseclass2 "
Author: BZ, 2009-02
Helper function for instBasictypeBaseClass
Handles the fail case rollbacks/deleteCheckpoint of errors."
  input Env.Cache inCache;
  input Env.Env inEnv1;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input list<SCode.Element> inSCodeElementLst2;
  input list<SCode.Element> inSCodeElementLst3;
  input DAE.Mod inMod4;
  input InstDims inInstDims5;
  input Absyn.Info info;
  input Util.StatefulBoolean stopInst "prevent instantiation of classes adding components to primary types";
algorithm _ := matchcontinue(inCache,inEnv1,inIH,store,inSCodeElementLst2,inSCodeElementLst3,inMod4,inInstDims5,info,stopInst)
  local
      DAE.Mod m_1,mods;
      SCode.Element cdef,cdef_1;
      list<Env.Frame> cenv,env_1,env;
      DAE.DAElist dae;
      DAE.Type ty;
      ClassInf.State st;
      Boolean b1,b2;
      Absyn.Path path;
      SCode.Mod mod;
      InstDims inst_dims;
      String classname;
      Env.Cache cache;
      InstanceHierarchy ih;
    
    case (cache,env,ih,store,{SCode.EXTENDS(baseClassPath = path,modifications = mod)},(_ :: _),mods,inst_dims,info,stopInst) /* Inherits baseclass -and- has components */
      equation
        (cache,m_1) = Mod.elabModForBasicType(cache, env, ih, Prefix.NOPRE(), mod, true, info);
        (cache,cdef,cenv) = Lookup.lookupClass(cache,env, path, true);
        cdef_1 = SCode.classSetPartial(cdef, SCode.NOT_PARTIAL());
        (cache,env_1,ih,_,dae,_,ty,st,_,_) = instClass(cache,cenv,ih,store, m_1, Prefix.NOPRE(), Connect.emptySet, cdef_1, inst_dims, false, INNER_CALL(), ConnectionGraph.EMPTY) "impl" ;
        b1 = Types.basicType(ty);
        b2 = Types.arrayType(ty);
        true = boolOr(b1, b2);
        classname = Env.printEnvPathStr(env);
        ErrorExt.rollBack("instBasictypeBaseclass2");
        Error.addSourceMessage(Error.INHERIT_BASIC_WITH_COMPS, {classname}, info);
        Util.setStatefulBoolean(stopInst,true);
      then
        ();
    
    // if not error above, then do not report error at all, try another case in instClassdef.
    case (_,_,_,_,_,_,_,_,_,_)
      equation
        ErrorExt.rollBack("instBasictypeBaseclass2");
      then ();
    end matchcontinue;
end instBasictypeBaseclass2;

protected function addConnectionSetToEnv
"function: addConnectionSetToEnv
  Adds the connection set and Prefix to the environment such that Ceval can reach it.
  It is required to evaluate cardinality."
  input Connect.Sets inSets;
  input Prefix.Prefix prefix;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outEnv,outIH) := matchcontinue (inSets,prefix,inEnv,inIH)
    local
      list<DAE.ComponentRef> crs;
      Option<String> n;
      Option<Env.ScopeType> st;
      Env.AvlTree bt2;
      Env.AvlTree bt1;
      list<Env.Item> imp;
      DAE.ComponentRef prefix_cr,cref_;
      list<Env.Frame> fs;
      SCode.Encapsulated enc;
      InstanceHierarchy ih;
      list<SCode.Element> defineUnits;

    case (Connect.SETS(connection = crs),prefix,
      (Env.FRAME( n,st,bt1,bt2,imp,_,enc,defineUnits) :: fs),ih)
      equation
        prefix_cr = PrefixUtil.prefixToCref(prefix);
      then (Env.FRAME(n,st,bt1,bt2,imp,(crs,prefix_cr),enc,defineUnits) :: fs,ih);
    
    case (Connect.SETS(connection = crs),prefix,
        (Env.FRAME(n,st,bt1,bt2,imp,_,enc,defineUnits) :: fs),ih)
      equation
        cref_ = ComponentReference.makeCrefIdent("",DAE.ET_OTHER(),{});
      then (Env.FRAME(n,st,bt1,bt2,imp,(crs,cref_),enc,defineUnits) :: fs,ih);

  end matchcontinue;
end addConnectionSetToEnv;

protected function addConnectionCrefs
"function: addConnectionCrefs
  author: PA
  This function adds the connection component references
  from local equations to the connection sets."
  input Connect.Sets inSets;
  input list<SCode.Equation> inSCodeEquationLst;
  output Connect.Sets outSets;
algorithm
  outSets := matchcontinue (inSets,inSCodeEquationLst)
    local
      Connect.Sets sets;
      DAE.ComponentRef cr1_1,cr2_1;
      Absyn.ComponentRef cr1,cr2;
      list<SCode.Equation> es;

    case (sets,{}) then sets;
    case (sets, (SCode.EQUATION(eEquation = SCode.EQ_CONNECT(crefLeft = cr1,crefRight = cr2)) :: es))
      equation
        cr1_1 = ComponentReference.toExpCref(cr1);
        cr2_1 = ComponentReference.toExpCref(cr2);
        sets = ConnectUtil.addConnectionCrefs(sets, {cr1_1, cr2_1});
        sets = addConnectionCrefs(sets, es);
      then
        sets;
    case (sets,(_ :: es))
      equation
        sets = addConnectionCrefs(sets, es);
      then
        sets;
  end matchcontinue;
end addConnectionCrefs;

protected function filterConnectionSetCrefs
"function: filterConnectionSetCrefs
  author: PA
  This function investigates Prefix and filters all connectRefs
  to only contain references starting with actual prefix."
  input Connect.Sets inSets;
  input Prefix.Prefix inPrefix;
  output Connect.Sets outSets;
algorithm
  outSets := matchcontinue (inSets,inPrefix)
    local
      Connect.Sets s;
      Prefix.Prefix first_pre,pre;
      DAE.ComponentRef cr;
      list<DAE.ComponentRef> crs;
    case (s,Prefix.NOPRE()) then s;  /* no Prefix, nothing to filter */
    case (Connect.SETS(connection = crs),pre)
      equation
        first_pre = PrefixUtil.prefixFirst(pre);
        cr = PrefixUtil.prefixToCref(first_pre);
        crs = Util.listSelect1R(crs, cr, ComponentReference.crefPrefixOf);
        s = ConnectUtil.setConnectionCrefs(inSets, crs);
      then
        s;
  end matchcontinue;
end filterConnectionSetCrefs;

protected function partialInstClassdef
"function: partialInstClassdef
  This function is used by partialInstClassIn for instantiating local
  class definitons and inherited class definitions only."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input SCode.ClassDef inClassDef;
  input SCode.Restriction inRestriction;
  input SCode.Partial inPartialPrefix;
  input SCode.Visibility inVisibility;
  input InstDims inInstDims;
  input String inClassName "the class name that contains the elements we are instanting";
  input Absyn.Info info;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output ClassInf.State outState;
algorithm
  (outCache,outEnv,outIH,outState):=
  matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,inClassDef,inRestriction,inPartialPrefix,inVisibility,inInstDims,inClassName,info)
    local
      ClassInf.State ci_state1,ci_state,new_ci_state,new_ci_state_1,ci_state2;
      list<SCode.Element> cdefelts,extendselts,els,cdefelts2,classextendselts;
      list<Env.Frame> env1,env2,env,cenv,cenv_2,env_2,env3;
      DAE.Mod emods,mods,mod_1,mods_1;
      list<tuple<SCode.Element, DAE.Mod>> extcomps,lst_constantEls;
      list<SCode.Equation> eqs,initeqs;
      list<SCode.AlgorithmSection> alg,initalg;
      Prefix.Prefix pre;
      Connect.Sets csets;
      SCode.Restriction re,r;
      SCode.Visibility vis;
      SCode.Encapsulated enc2;
      SCode.Partial partialPrefix;
      InstDims inst_dims;
      SCode.Element c;
      String cn2,cns,scope_str,className;
      Absyn.Path cn;
      Option<list<Absyn.Subscript>> ad;
      SCode.Mod mod;
      Env.Cache cache;
      InstanceHierarchy ih;

      /* long class definition */  /* the normal case, a class with parts */
      /*
    case (cache,env,ih,mods,pre,csets,ci_state,
          SCode.PARTS(elementLst = els,
                      normalEquationLst = eqs, initialEquationLst = initeqs,
                      normalAlgorithmLst = alg, initialAlgorithmLst = initalg),
          re,vis,inst_dims,className)
      equation
        ci_state1 = ClassInf.trans(ci_state, ClassInf.NEWDEF());
        (cdefelts,classextendselts,extendselts,_) = splitElts(els);
        (env1,ih) = addClassdefsToEnv(env, ih, pre, cdefelts, true,NONE()) " CLASS & IMPORT nodes are added to env" ;
        (cache,env2,ih,emods,extcomps,eqs2,initeqs2,alg2,initalg2) =
        partialInstExtendsAndClassExtendsList(cache,env1,ih, mods, extendselts, classextendselts, ci_state, className, true)
        "2. EXTENDS Nodes inst_Extends_List only flatten inhteritance structure. It does not perform component instantiations." ;
        lst_constantEls = addNomod(constantEls(els)) " Retrieve all constants";
        *//*
         Since partial instantiation is done in lookup, we need to add inherited classes here.
         Otherwise when looking up e.g. A.B where A inherits the definition of B, and without having a
         base class context (since we do not have any element to find it in), the class must be added
         to the environment here.
        *//*
        cdefelts2 = classdefElts2(extcomps);
        (env2,ih) = addClassdefsToEnv(env2, ih, pre, cdefelts2,true,NONE()); // Add inherited classes to env
        (cache,env3,ih) = addComponentsToEnv(cache, env2, ih, mods, pre, csets, ci_state,
                                             lst_constantEls, lst_constantEls, {},
                                             inst_dims, false);
      then
        (cache,env3,ih,ci_state1);
    */

      case (cache,env,ih,mods,pre,csets,ci_state,
          SCode.PARTS(elementLst = els,
            normalEquationLst = eqs, initialEquationLst = initeqs,
            normalAlgorithmLst = alg, initialAlgorithmLst = initalg),
            re,partialPrefix,vis,inst_dims,className,info)
      equation
        // Debug.traceln(" Partialinstclassdef for: " +& PrefixUtil.printPrefixStr(pre) +& "." +&  className +& " mods: " +& Mod.printModStr(mods));
        partialPrefix = isPartial(partialPrefix, mods);
        ci_state1 = ClassInf.trans(ci_state, ClassInf.NEWDEF());
        (cdefelts,classextendselts,extendselts,_) = splitElts(els);
        (env1,ih) = addClassdefsToEnv(env, ih, pre, cdefelts, true, NONE()) " CLASS & IMPORT nodes are added to env" ;
        (cache,env2,ih,emods,extcomps,_,_,_,_) =
        InstExtends.instExtendsAndClassExtendsList(cache, env1, ih, mods, pre, extendselts, classextendselts, ci_state, className, true, true)
        "2. EXTENDS Nodes inst_Extends_List only flatten inhteritance structure. It does not perform component instantiations." ;
        els = Util.if_(SCode.partialBool(partialPrefix), {}, els);
        // If we partially instantiate a partial package, we filter out constants (maybe we should also filter out functions) /sjoelund
        lst_constantEls = listAppend(extcomps,addNomod(constantEls(els))) " Retrieve all constants";
        /*
         Since partial instantiation is done in lookup, we need to add inherited classes here.
         Otherwise when looking up e.g. A.B where A inherits the definition of B, and without having a
         base class context (since we do not have any element to find it in), the class must be added
         to the environment here.
        */
        (cdefelts2,extcomps) = classdefElts2(extcomps, partialPrefix);
        (env2,ih) = addClassdefsToEnv(env2, ih, pre, cdefelts2, true, NONE()); // Add inherited classes to env
        (cache,env3,ih) = addComponentsToEnv(cache, env2, ih, mods, pre, csets, ci_state,
                                             lst_constantEls, lst_constantEls, {},
                                             inst_dims, false); // adrpo: here SHOULD BE IMPL=TRUE! not FALSE!
        (cache,env3,ih,lst_constantEls,csets) = updateCompeltsMods(cache,env3,ih, pre, lst_constantEls, ci_state, csets, true);

        //lst_constantEls = listAppend(extcomps,lst_constantEls);
        (cache,env3,ih,_,_,_,ci_state2,_,_) =
           instElementList(cache, env3, ih, UnitAbsyn.noStore, mods, pre, csets, ci_state1, lst_constantEls,
                          inst_dims, true, INNER_CALL(), ConnectionGraph.EMPTY) "instantiate constants";
        // Debug.traceln("partialInstClassdef OK " +& className);
      then
        (cache,env3,ih,ci_state2);

    // Short class definition, derived from basic types!
    case (cache,env,ih,mods,pre,csets,ci_state,
          SCode.DERIVED(Absyn.TPATH(path = cn, arrayDim = ad),modifications = mod),
          re,partialPrefix,vis,inst_dims,className,info)
      equation
        (cache,(c as SCode.CLASS(name=cn2,encapsulatedPrefix=enc2,restriction=r)),cenv) = Lookup.lookupClass(cache, env, cn, true);
        
        // if is a basic type, or enum follow the normal path 
        true = checkDerivedRestriction(re, r, cn2);
        
        cenv_2 = Env.openScope(cenv, enc2, SOME(cn2), Env.restrictionToScopeType(r));
        new_ci_state = ClassInf.start(r, Env.getEnvName(cenv_2));

        (cache,mod_1) = Mod.elabMod(cache, env, ih, pre, mod, false, info);

        mods_1 = Mod.merge(mods, mod_1, cenv_2, pre);
        (cache,env_2,ih,new_ci_state_1) = partialInstClassIn(cache, cenv_2, ih, mods_1, pre, csets, new_ci_state, c, vis, inst_dims);
      then
        (cache,env_2,ih,new_ci_state_1);

    // Short class definition, not derived from basic types!
    case (cache,env,ih,mods,pre,csets,ci_state,
          SCode.DERIVED(Absyn.TPATH(path = cn, arrayDim = ad),modifications = mod),
          re,partialPrefix,vis,inst_dims,className,info)
      equation
        (cache,(c as SCode.CLASS(name=cn2,encapsulatedPrefix=enc2,restriction=r)),cenv) = Lookup.lookupClass(cache, env, cn, true);
        
        // if is not a basic type 
        false = checkDerivedRestriction(re, r, cn2);        
        
        // change the class name to className!!
        // package A2=A
        // package A3=A(mods)
        // will get you different function implementations for the different packages!
        c = SCode.setClassName(className, c);

        // do not open a new env!
        //cenv_2 = env;
        //ci_state2 = ci_state;
        //new_ci_state = ci_state;
        cenv_2 = Env.openScope(cenv, enc2, SOME(className), Env.restrictionToScopeType(r));
        new_ci_state = ClassInf.start(r, Env.getEnvName(cenv_2));
        
        //print("Partial Derived Env: " +& Env.printEnvPathStr(cenv_2) +& "\n");

        (cache,mod_1) = Mod.elabMod(cache, env, ih, pre, mod, false, info);

        mods_1 = Mod.merge(mods, mod_1, cenv_2, pre);
        (cache,env_2,ih,new_ci_state_1) = partialInstClassIn(cache, cenv_2, ih, mods_1, pre, csets, new_ci_state, c, vis, inst_dims);
      then
        (cache,env_2,ih,new_ci_state_1);

    /* If the class is derived from a class that can not be found in the environment,
     * this rule prints an error message.
     */
    case (cache,env,ih,mods,pre,csets,ci_state,
          SCode.DERIVED(Absyn.TPATH(path = cn, arrayDim = ad),modifications = mod),
          re,partialPrefix,vis,inst_dims,className,info)
      equation
        failure((_,_,_) = Lookup.lookupClass(cache,env, cn, false));
        cns = Absyn.pathString(cn);
        scope_str = Env.printEnvPathStr(env);
        Error.addSourceMessage(Error.LOOKUP_ERROR, {cns,scope_str},info);
      then
        fail();
  end matchcontinue;
end partialInstClassdef;

protected function constantEls
"Returns only elements that are constants.
author: PA
Used buy partialInstClassdef to instantiate constants in packages."
  input list<SCode.Element> elements;
  output list<SCode.Element> outElements;
algorithm
  outElements := matchcontinue (elements)
    local
      SCode.Attributes attr;
      SCode.Element el;
      list<SCode.Element> els,els1;
    
    case ({}) then {};

    case ((el as SCode.COMPONENT(attributes=attr))::els)
     equation
        SCode.CONST() = SCode.attrVariability(attr);
        els1 = constantEls(els);
    then (el::els1);

    case (_::els)
      equation
        els1 = constantEls(els);
     then els1;
  end matchcontinue;
end constantEls;

protected function getModsForDep "
Author: BZ, 2009-08
Extract modifer for dependent variables(dep)."
  input Absyn.ComponentRef dep;
  input list<tuple<SCode.Element, DAE.Mod>> elems;
  output DAE.Mod omods;
algorithm 
  omods := matchcontinue(dep,elems)
    local
      String name1,name2;
      DAE.Mod cmod;
      tuple<SCode.Element, DAE.Mod> tpl;
  
    case(_,{}) then DAE.NOMOD();
    case(dep,( tpl as (SCode.COMPONENT(name=name1),DAE.NOMOD()))::elems)
      then getModsForDep(dep,elems);
    case(dep,( tpl as (SCode.COMPONENT(name=name1),cmod))::elems)
      equation
        name2 = Absyn.printComponentRefStr(dep);
        true = stringEq(name2,name1);
        cmod = DAE.MOD(SCode.NOT_FINAL(),SCode.NOT_EACH(),{DAE.NAMEMOD(name2,cmod)},NONE());
      then
        cmod;
    case(dep,tpl::elems)
      equation
        cmod = getModsForDep(dep,elems);
      then
        cmod;
  end matchcontinue;
end getModsForDep;

protected function updateCompeltsMods
"function: updateCompeltsMods
  author: PA
  This function updates component modifiers to typed modifiers.
  Typed modifiers are needed  to merge modifiers and to be able to
  fully instantiate a component."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst;
  input ClassInf.State inState;
  input Connect.Sets inSets;
  input Boolean inBoolean;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output list<tuple<SCode.Element, DAE.Mod>> outTplSCodeElementModLst;
  output Connect.Sets outSets;
algorithm
  (outCache,outEnv,outIH,outTplSCodeElementModLst,outSets):=
  matchcontinue (inCache,inEnv,inIH,inPrefix,inTplSCodeElementModLst,inState,inSets,inBoolean)
    local
      list<Env.Frame> env,env2,env3;
      Prefix.Prefix pre;
      Connect.Sets csets;
      SCode.Mod umod;
      list<Absyn.ComponentRef> crefs,crefs_1;
      Absyn.ComponentRef cref;
      DAE.Mod cmod_1,cmod,cmod2,redMod;
      list<DAE.Mod> ltmod;
      list<tuple<SCode.Element, DAE.Mod>> res,xs;
      tuple<SCode.Element, DAE.Mod> elMod;
      SCode.Element comp,redComp;
      ClassInf.State ci_state;
      Boolean impl;
      Env.Cache cache;
      InstanceHierarchy ih;
      String name;
      Absyn.Info info;

    case (cache,env,ih,pre,{},_,csets,_) then (cache,env,ih,{},csets);
      // Special case for components beeing redeclared, we might instantiate partial classes when instantiating var(-> instVar2->instClass) to update component in env.
    case (cache,env,ih,pre,((comp,(cmod as DAE.REDECL(_,_,{(redComp,redMod)}))) :: xs),ci_state,csets,impl)
      equation
        info = Absyn.dummyInfo; // TODO: Get info from the comp? Is it always a COMPONENT?
        umod = Mod.unelabMod(cmod);
        crefs = getCrefFromMod(umod);
        crefs_1 = getCrefFromCompDim(comp) "get crefs from dimension arguments";
        crefs = Util.listUnionOnTrue(crefs,crefs_1,Absyn.crefEqual);
        name = SCode.elementName(comp);
        cref = Absyn.CREF_IDENT(name,{});
        ltmod = Util.listMap1(crefs,getModsForDep,xs);
        cmod2 = Util.listFold_3(cmod::ltmod,Mod.merge,DAE.NOMOD(),env,pre);

        //print("("+&intString(listLength(ltmod))+&")UpdateCompeltsMods_(" +& Util.stringDelimitList(Util.listMap(crefs2,Absyn.printComponentRefStr),",") +& ") subs: " +& Util.stringDelimitList(Util.listMap(crefs,Absyn.printComponentRefStr),",")+& "\n");
        //print("REDECL     acquired mods: " +& Mod.printModStr(cmod2) +& "\n");
        (cache,env2,ih,csets) = updateComponentsInEnv(cache, env, ih, pre, cmod2, crefs, ci_state, csets, impl);
        ErrorExt.setCheckpoint("updateCompeltsMods");
        (cache,env2,ih,csets) = updateComponentsInEnv(cache, env2, ih, pre, DAE.MOD(SCode.NOT_FINAL(),SCode.NOT_EACH(),{DAE.NAMEMOD(name, cmod)},NONE()), {cref}, ci_state, csets, impl);
        ErrorExt.rollBack("updateCompeltsMods") "roll back any errors";
        (cache,cmod_1) = Mod.updateMod(cache, env2, ih, pre, cmod, impl, info);
        (cache,env3,ih,res,csets) = updateCompeltsMods(cache, env2, ih, pre, xs, ci_state, csets, impl);
      then
        (cache,env3,ih,((comp,cmod_1) :: res),csets);

      /* No need to update a mod unless there's actually anything there. */
    case (cache,env,ih,pre,((elMod as (_,DAE.NOMOD())) :: xs),ci_state,csets,impl)
      equation
        (cache,env,ih,res,csets) = updateCompeltsMods(cache, env, ih, pre, xs, ci_state, csets, impl);
      then
        (cache,env,ih,elMod::res,csets);

    case (cache,env,ih,pre,((comp, cmod as DAE.MOD(subModLst = _)) :: xs),ci_state,csets,impl)
      equation
        info = Absyn.dummyInfo; // TODO: Get info from the comp? Is it always a COMPONENT?
        umod = Mod.unelabMod(cmod);
        crefs = getCrefFromMod(umod);
        crefs_1 = getCrefFromCompDim(comp);
        crefs = Util.listUnionOnTrue(crefs,crefs_1,Absyn.crefEqual);
        name = SCode.elementName(comp);
        cref = Absyn.CREF_IDENT(name,{});

        ltmod = Util.listMap1(crefs,getModsForDep,xs);
        cmod2 = Util.listFold_3(ltmod,Mod.merge,DAE.NOMOD(),env,pre);

        //print("("+&intString(listLength(ltmod))+&")UpdateCompeltsMods_(" +& Util.stringDelimitList(Util.listMap(crefs,Absyn.printComponentRefStr),",") +& ") subs: " +& Util.stringDelimitList(Util.listMap(crefs,Absyn.printComponentRefStr),",")+& "\n");
        //print("     acquired mods: " +& Mod.printModStr(cmod2) +& "\n");

        (cache,env2,ih,csets) = updateComponentsInEnv(cache, env, ih, pre, cmod2, crefs, ci_state, csets, impl);
        (cache,env2,ih,csets) = updateComponentsInEnv(cache, env2, ih, pre, DAE.MOD(SCode.NOT_FINAL(),SCode.NOT_EACH(),{DAE.NAMEMOD(name, cmod)},NONE()), {cref}, ci_state, csets, impl);

        (cache,cmod_1) = Mod.updateMod(cache, env2, ih, pre, cmod, impl, info);
        (cache,env3,ih,res,csets) = updateCompeltsMods(cache, env2, ih, pre, xs, ci_state, csets, impl);
      then
        (cache,env3,ih,((comp,cmod_1) :: res),csets);

  end matchcontinue;
end updateCompeltsMods;

protected function getOptionArraydim
"function: getOptionArraydim
  Return the Arraydim of an optional arradim.
  Empty list returned if no arraydim present."
  input Option<Absyn.ArrayDim> inAbsynArrayDimOption;
  output Absyn.ArrayDim outArrayDim;
algorithm
  outArrayDim := match (inAbsynArrayDimOption)
    local list<Absyn.Subscript> dim;
    case (SOME(dim)) then dim;
    case (NONE()) then {};
  end match;
end getOptionArraydim;

public function addNomod
"function: addNomod
  This function takes an SCode.Element list and tranforms it into a
  (SCode.Element Mod) list by inserting DAE.NOMOD() for each element.
  Used to transform elements into a uniform list combined from inherited
  elements and ordinary elements."
  input list<SCode.Element> inSCodeElementLst;
  output list<tuple<SCode.Element, DAE.Mod>> outTplSCodeElementModLst;
algorithm
  outTplSCodeElementModLst := match (inSCodeElementLst)
    local
      list<tuple<SCode.Element, DAE.Mod>> res;
      SCode.Element x;
      list<SCode.Element> xs;
    case {} then {};
    case ((x :: xs))
      equation
        res = addNomod(xs);
      then
        ((x,DAE.NOMOD()) :: res);
  end match;
end addNomod;

public function instElementList
  "Instantiates a list of elements."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input list<tuple<SCode.Element, DAE.Mod>> inElements;
  input InstDims inInstDims;
  input Boolean inImplInst;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output ConnectionGraph.ConnectionGraph outGraph;
protected
  list<tuple<SCode.Element, DAE.Mod>> el;
algorithm
  el := sortElementList(inElements, inEnv);
  (outCache, outEnv, outIH, outStore, outDae, outSets, outState, outTypesVarLst, outGraph) := 
    instElementList2(inCache, inEnv, inIH, store, inMod, inPrefix, inSets,
      inState, el, inInstDims, inImplInst, inCallingScope, inGraph);
end instElementList;

protected function sortElementList
  "Sorts constants and parameters by dependencies, so that they are instantiated
  before they are used."
  input list<Element> inElements;
  input Env.Env inEnv;
  output list<Element> outElements;
  type Element = tuple<SCode.Element, DAE.Mod>;
protected
  list<tuple<Element, list<Element>>> cycles;
algorithm
  (outElements, cycles) := Graph.topologicalSort(
    Graph.buildGraph(inElements, getElementDependencies, inElements),
    isElementEqual);
  checkCyclicalComponents(cycles, inEnv);
end sortElementList;

protected function getElementDependencies
  "Returns the dependencies given an element."
  input tuple<SCode.Element, DAE.Mod> inElement;
  input list<tuple<SCode.Element, DAE.Mod>> inAllElements;
  output list<tuple<SCode.Element, DAE.Mod>> outDependencies;
algorithm
  outDependencies := matchcontinue(inElement, inAllElements)
    local
      SCode.Variability var;
      Absyn.Exp bind_exp, cond_exp;
      list<tuple<SCode.Element, DAE.Mod>> deps;

    // For constants and parameters we check the binding modification.
    case ((SCode.COMPONENT(condition = SOME(cond_exp), attributes = SCode.ATTR(variability = var),
        modifications = SCode.MOD(binding = SOME((bind_exp, _)))), _), _)
      equation
        true = SCode.isParameterOrConst(var);
        (_, (_, _, (_, deps))) = Absyn.traverseExpBidir(bind_exp,
          (getElementDependenciesTraverserEnter,
           getElementDependenciesTraverserExit,
           (inAllElements, {})));
        (_, (_, _, (_, deps))) = Absyn.traverseExpBidir(cond_exp,
          (getElementDependenciesTraverserEnter,
           getElementDependenciesTraverserExit,
           (inAllElements, deps)));
      then
        deps;

    case ((SCode.COMPONENT(condition = NONE(), attributes = SCode.ATTR(variability = var),
        modifications = SCode.MOD(binding = SOME((bind_exp, _)))), _), _)
      equation
        true = SCode.isParameterOrConst(var);
        (_, (_, _, (_, deps))) = Absyn.traverseExpBidir(bind_exp,
          (getElementDependenciesTraverserEnter,
           getElementDependenciesTraverserExit,
           (inAllElements, {})));
      then
        deps;

    // For other variables we check the condition, since they might be
    // conditional on a constant or parameter.
    case ((SCode.COMPONENT(condition = SOME(cond_exp)), _), _)
      equation
        (_, (_, _, (_, deps))) = Absyn.traverseExpBidir(cond_exp,
          (getElementDependenciesTraverserEnter,
           getElementDependenciesTraverserExit,
           (inAllElements, {})));
      then
        deps;

    else then {};
  end matchcontinue;
end getElementDependencies;

protected function getElementDependenciesTraverserEnter
  "Traverse function used by getElementDependencies to collect all dependencies
  for an element. The first ElementList in the input argument is a list of all
  elements, and the second is a list of accumulated dependencies."
  input tuple<Absyn.Exp, tuple<ElementList, ElementList>> inTuple;
  output tuple<Absyn.Exp, tuple<ElementList, ElementList>> outTuple;
  type ElementList = list<tuple<SCode.Element, DAE.Mod>>;
algorithm
  outTuple := matchcontinue(inTuple)
    local
      Absyn.Exp exp;
      String id;
      ElementList all_el, accum_el;
      tuple<SCode.Element, DAE.Mod> e;

    case ((exp as Absyn.CREF(componentRef = Absyn.CREF_IDENT(name = id)), 
        (all_el, accum_el)))
      equation
        // Try and delete the element with the given name from the list of all
        // elements. If this succeeds, add it to the list of elements. This
        // ensures that we don't add any dependency more than once.
        (all_el, SOME(e)) = Util.listDeleteMemberOnTrue(id, all_el,
          isElementNamed);
      then
        ((exp, (all_el, e :: accum_el)));

    else then inTuple;
  end matchcontinue;
end getElementDependenciesTraverserEnter;

protected function getElementDependenciesTraverserExit
  "Dummy traversal function used by getElementDependencies."
  input tuple<Absyn.Exp, tuple<ElementList, ElementList>> inTuple;
  output tuple<Absyn.Exp, tuple<ElementList, ElementList>> outTuple;
  type ElementList = list<tuple<SCode.Element, DAE.Mod>>;
algorithm
  outTuple := inTuple;
end getElementDependenciesTraverserExit;

protected function isElementNamed
  "Returns true if the given element has the same name as the given string,
  otherwise false."
  input String inName;
  input tuple<SCode.Element, DAE.Mod> inElement;
  output Boolean isNamed;
algorithm
  isNamed := matchcontinue(inName, inElement)
    local
      String name;

    case (_, (SCode.COMPONENT(name = name), _))
      equation
        true = stringEqual(name, inName);
      then
        true;

    else false;
  end matchcontinue;
end isElementNamed;

protected function isElementEqual
  "Checks that two elements are equal, i.e. has the same name."
  input tuple<SCode.Element, DAE.Mod> inElement1;
  input tuple<SCode.Element, DAE.Mod> inElement2;
  output Boolean isEqual;
algorithm
  isEqual := matchcontinue(inElement1, inElement2)
    local
      String id1, id2;

    case ((SCode.COMPONENT(name = id1), _), 
          (SCode.COMPONENT(name = id2), _))
      then stringEqual(id1, id2);

    else then false;
  end matchcontinue;
end isElementEqual;

protected function checkCyclicalComponents
  "Checks the return value from Graph.topologicalSort. If the list of cycles is
  not empty, print an error message and fail, since it's not allowed for
  constants or parameters to have cyclic dependencies."
  input list<tuple<Element, list<Element>>> inCycles;
  input Env.Env inEnv;
  type Element = tuple<SCode.Element, DAE.Mod>;
algorithm
  _ := match(inCycles, inEnv)
    local
      list<list<Element>> cycles;
      list<list<String>> names;
      list<String> cycles_strs;
      String cycles_str, scope_str;

    case ({}, _) then ();

    else
      equation
        cycles = Graph.findCycles(inCycles, isElementEqual);
        names = Util.listListMap(cycles, elementName);
        cycles_strs = Util.listMap1(names, Util.stringDelimitList, ",");
        cycles_str = Util.stringDelimitList(cycles_strs, "}, {");
        cycles_str = "{" +& cycles_str +& "}";
        scope_str = Env.printEnvPathStr(inEnv);
        Error.addMessage(Error.CIRCULAR_COMPONENTS, {scope_str, cycles_str});
      then
        fail();
  end match;
end checkCyclicalComponents;

protected function elementName
  "Returns the name of the given element."
  input tuple<SCode.Element, DAE.Mod> inElement;
  output String outName;
protected
  SCode.Element elem;
algorithm
  (elem, _) := inElement;
  outName := SCode.elementName(elem);
end elementName;

public function instElementList2
"function: instElementList
  Moved to instClassdef, FIXME: Move commments later
  Instantiate elements one at a time, and concatenate the resulting
  lists of equations.
  P.A, Modelica1.4: (allows declare before use)
  1. 'First names of declared local classes (and components) are found.
      Redeclarations are performed.'
      This means that we first handle all CLASS nodes and apply modifiers and
      declarations to them and also COMPONENT nodes to add the variables to the
      environment.
  2.  Second, 'base-classes are looked up, flattened and inserted into the class.'
      This means that all EXTENDS nodes are handled.
  3.  Third, 'Flatten the class, apply modifiers and instantiate all local elements.'
      This handles COMPONENT nodes."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input DAE.Mod inMod2;
  input Prefix.Prefix inPrefix3;
  input Connect.Sets inSets4;
  input ClassInf.State inState5;
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst6;
  input InstDims inInstDims7;
  input Boolean inImplicit;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outTypesVarLst;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outState,outTypesVarLst,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inMod2,inPrefix3,inSets4,inState5,inTplSCodeElementModLst6,inInstDims7,inImplicit,inCallingScope,inGraph)
    local
      list<Env.Frame> env,env_1,env_2;
      Connect.Sets csets,csets_1,csets_2;
      ClassInf.State ci_state,ci_state_1,ci_state_2;
      DAE.DAElist dae1,dae2,dae;
      list<DAE.Var> tys1,tys2,tys;
      DAE.Mod mod;
      Prefix.Prefix pre;
      tuple<SCode.Element, DAE.Mod> el;
      list<tuple<SCode.Element, DAE.Mod>> els;
      InstDims inst_dims;
      Boolean impl;
      Env.Cache cache;
      Absyn.Info info;
      CallingScope callscope;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      String elementName;
      SCode.Element ele;
      String comp_name;
      DAE.ComponentRef comp_cr;

    case (cache,env,ih,store,_,_,csets,ci_state,{},_,_,_,graph)
      then (cache,env,ih,store,DAEUtil.emptyDae,csets,ci_state,{},graph);

    // Don't instantiate conditional components with condition = false.
    case (cache, env, ih, store, mod, pre, csets, ci_state, 
        (el as (SCode.COMPONENT(name = comp_name, info = info, condition=SOME(_)), _)) :: els, inst_dims,
        impl, callscope, graph)
      equation
        // check for duplicate modifications
        ele = Util.tuple21(el);
        (elementName, info) = extractCurrentName(ele);
        Mod.verifySingleMod(mod,pre,elementName,info);
        
        (true, cache) = isConditionalComponent(cache, env, ele, pre, info);

        // Add the deleted component to the connection set, so that we know
        // which connections to ignore.
        comp_cr = ComponentReference.makeCrefIdent(comp_name, DAE.ET_OTHER(), {});
        (cache, comp_cr) = PrefixUtil.prefixCref(cache, env, ih, pre, comp_cr);
        csets = ConnectUtil.addDeletedComponent(comp_cr, csets);

        (cache, env, ih, store, dae, csets, ci_state, tys, graph) =
          instElementList2(cache, env, ih, store, mod, pre, csets, ci_state, els,
            inst_dims, impl, callscope, graph);
      then
        (cache, env, ih, store, dae, csets, ci_state, tys, graph);

    /* most work done in inst_element. */
    case (cache,env,ih,store,mod,pre,csets,ci_state,el :: els,inst_dims,impl,callscope,graph)
      equation
        // check for duplicate modifications
        ele = Util.tuple21(el);
        (elementName, info) = extractCurrentName(ele);
        Mod.verifySingleMod(mod,pre,elementName,info);
        
        /*
        classmod = Mod.lookupModificationP(mods, t);
        mm = Mod.lookupCompModification(mods, n);
        */
        // A frequent used debugging line
        //print("Instantiating element: " +& str +& " in scope " +& Env.getScopeName(env) +& ", elements to go: " +& intString(listLength(els)) +&
        //"\t mods: " +& Mod.printModStr(mod) +&  "\n");

                 
        (cache,env_1,ih,store,dae1,csets_1,ci_state_1,tys1,graph) =
          instElement(cache,env,ih,store, mod, pre, csets, ci_state, el, inst_dims, impl, callscope, graph);
        /*s1 = Util.if_(stringEq("n", str),DAE.dumpElementsStr(dae1),"");
        print(s1) "To print what happened to a specific var";*/
        Error.updateCurrentComponent("",Absyn.dummyInfo);
        (cache,env_2,ih,store,dae2,csets_2,ci_state_2,tys2,graph) =
          instElementList2(cache,env_1,ih,store, mod, pre, csets_1, ci_state_1, els, inst_dims, impl, callscope, graph);
        tys = listAppend(tys1, tys2);
        dae = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,env_2,ih,store,dae,csets_2,ci_state_2,tys,graph);

    case (_,_,_,_,_,_,_,_,els,_,_,_,_)
      equation
        //print("instElementList2 failed\n ");
        // no need for this line as we already printed the crappy element that we couldn't instantiate
        // Debug.fprintln("failtrace", "- Inst.instElementList failed");
      then
        fail();
  end matchcontinue;
end instElementList2;

protected function classdefElts2
"function: classdeElts2
  author: PA
  This function filters out the class definitions (ElementMod) list."
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst;
  input SCode.Partial partialPrefix;
  output list<SCode.Element> outSCodeElementLst;
  output list<tuple<SCode.Element, DAE.Mod>> outConstEls;
algorithm
  (outSCodeElementLst,outConstEls) := matchcontinue (inTplSCodeElementModLst,partialPrefix)
    local
      list<SCode.Element> cdefs;
      SCode.Element cdef;
      tuple<SCode.Element, DAE.Mod> el;
      list<tuple<SCode.Element, DAE.Mod>> xs, els;
      SCode.Attributes attr;
    case ({},_) then ({},{});
    case ((cdef as SCode.CLASS(restriction = SCode.R_PACKAGE()),_) :: xs,SCode.PARTIAL())
      equation
        (cdefs,els) = classdefElts2(xs,partialPrefix);
      then
        (cdef::cdefs,els);
    case (((cdef as SCode.CLASS(name = _),_)) :: xs,SCode.NOT_PARTIAL())
      equation
        (cdefs,els) = classdefElts2(xs,partialPrefix);
      then
        (cdef::cdefs,els);
    case((el as (SCode.COMPONENT(attributes=attr),_))::xs,SCode.NOT_PARTIAL())
       equation
        SCode.CONST() = SCode.attrVariability(attr);
         (cdefs,els) = classdefElts2(xs,partialPrefix);
       then (cdefs,el::els);
    case ((_ :: xs),_)
      equation
        (cdefs,els) = classdefElts2(xs,partialPrefix);
      then
        (cdefs,els);
  end matchcontinue;
end classdefElts2;

public function classdefAndImpElts
"function: classdefAndImpElts
  author: PA
  This function filters out the class definitions
  and import statements of an Element list."
  input list<SCode.Element> elts;
  output list<SCode.Element> cdefElts;
  output list<SCode.Element> restElts;
algorithm
  (cdefElts,restElts) := matchcontinue (elts)
    local
      list<SCode.Element> res,xs;
      SCode.Element cdef,imp,e;
    
    case ({}) then ({},{});
    
    case (((cdef as SCode.CLASS(name = _)) :: xs))
      equation
        (cdefElts,restElts) = classdefAndImpElts(xs);
      then
        (cdef :: restElts,restElts);
    
    case (((imp as SCode.IMPORT(imp = _)) :: xs))
      equation
        (cdefElts,restElts) = classdefAndImpElts(xs);
      then
        (imp :: cdefElts,restElts);
    
    case ((e :: xs))
      equation
        (cdefElts,restElts) = classdefAndImpElts(xs);
      then
        (cdefElts,e::restElts);
  end matchcontinue;
end classdefAndImpElts;

/*
protected function extendsElts
"function: extendsElts
  author: PA
  This function filters out the extends Element in an Element list"
  input list<SCode.Element> inSCodeElementLst;
  output list<SCode.Element> outSCodeElementLst;
algorithm
  outSCodeElementLst := matchcontinue (inSCodeElementLst)
    local
      list<SCode.Element> res,xs;
      SCode.Element cdef;
    case ({}) then {};
    case (((cdef as SCode.EXTENDS(baseClassPath = _)) :: xs))
      equation
        res = extendsElts(xs);
      then
        (cdef :: res);
    case ((_ :: xs))
      equation
        res = extendsElts(xs);
      then
        res;
  end matchcontinue;
end extendsElts;
*/

public function componentElts
"function: componentElts
  author: PA
  This function filters out the component Element in an Element list"
  input list<SCode.Element> inSCodeElementLst;
  output list<SCode.Element> outSCodeElementLst;
algorithm
  outSCodeElementLst := matchcontinue (inSCodeElementLst)
    local
      list<SCode.Element> res,xs;
      SCode.Element cdef;
    case ({}) then {};
    case (((cdef as SCode.COMPONENT(name = _)) :: xs))
      equation
        res = componentElts(xs);
      then
        (cdef :: res);
    case ((_ :: xs))
      equation
        res = componentElts(xs);
      then
        res;
  end matchcontinue;
end componentElts;

public function addClassdefsToEnv
"function: addClassdefsToEnv
  author: PA

  This function adds classdefinitions and
  import statements to the  environment."
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input list<SCode.Element> inSCodeElementLst;
  input Boolean inBoolean;
  input Option<DAE.Mod> redeclareMod;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outEnv,outIH) := matchcontinue (inEnv,inIH,inPrefix,inSCodeElementLst,inBoolean,redeclareMod)
    local
      list<Env.Frame> env,env_1,env_2;
      list<SCode.Element> els;
      Boolean impl;
      Prefix.Prefix pre;
      
    case (env,inIH,pre,els,impl,redeclareMod)
      equation
        (env_1,inIH) = addClassdefsToEnv2(env,inIH,pre,els,impl,redeclareMod);
        env_2 = Env.updateEnvClasses(env_1,env_1)
        "classes added with correct env.
        This is needed to store the correct env in Env.CLASS.
        It is required to get external objects to work";
       then (env_2,inIH);
    case(_,_,_,_,_,_)
      equation
        Debug.fprint("failtrace", "- Inst.addClassdefsToEnv failed\n");
        then
          fail();
  end matchcontinue;
end addClassdefsToEnv;

protected function addClassdefsToEnv2
"function: addClassdefsToEnv2
  author: PA
  Helper relation to addClassdefsToEnv"
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input list<SCode.Element> inSCodeElementLst;
  input Boolean inBoolean;
  input Option<DAE.Mod> redeclareMod;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outEnv,outIH) := matchcontinue (inEnv,inIH,inPrefix,inSCodeElementLst,inBoolean,redeclareMod)
    local
      list<Env.Frame> env,env_1,env_2,env1;
      SCode.Element cl,cl2,enumclass;
      SCode.Element sel1,elt;
      list<SCode.Element> xs;
      list<SCode.Enum> enumLst;
      Boolean impl;
      Absyn.Import imp;
      InstanceHierarchy ih;
      Absyn.Info info;
      Prefix.Prefix pre;
      String s;
      Option<SCode.Comment> cmt;

    case (env,ih,pre,{},_,_) then (env,ih);
    
    // we do have a redeclaration of class.
    case (env,ih,pre,( (sel1 as SCode.CLASS(name = s)) :: xs),impl,redeclareMod)
      equation
        (env1,ih,cl2) = addClassdefsToEnv3(env, ih, pre, redeclareMod, sel1);
        env_1 = Env.extendFrameC(env1, cl2);
        (env_2,ih) = addClassdefsToEnv2(env_1, ih, pre, xs, impl, redeclareMod);
      then
        (env_2,ih);

    // adrpo: see if is an enumeration! then extend frame with in class.
    case (env,ih,pre,( (sel1 as SCode.CLASS(name = s, classDef=SCode.ENUMERATION(enumLst,cmt),info=info)) :: xs),impl,redeclareMod)
      equation
        enumclass = instEnumeration(s, enumLst, cmt, info);
        env_1 = Env.extendFrameC(env, enumclass);
        (env_2,ih) = addClassdefsToEnv2(env_1, ih, pre, xs, impl, redeclareMod);
      then
        (env_2,ih);

    // otherwise, extend frame with in class.
    case (env,ih,pre,( (sel1 as SCode.CLASS(classDef = _)) :: xs),impl,redeclareMod)
      equation
        // Debug.traceln("Extend frame " +& Env.printEnvPathStr(env) +& " with " +& SCode.className(cl));
        env_1 = Env.extendFrameC(env, sel1);
        (env_2, ih) = addClassdefsToEnv2(env_1, ih, pre, xs, impl, redeclareMod);
      then
        (env_2,ih);

    case (env,ih,pre,(SCode.IMPORT(imp = imp) :: xs),impl,redeclareMod)
      equation
        env_1 = Env.extendFrameI(env, imp);
        (env_2,ih) = addClassdefsToEnv2(env_1, ih, pre, xs, impl, redeclareMod);
      then
        (env_2,ih);
    case(env,ih,pre,((elt as SCode.DEFINEUNIT(name=_))::xs), impl,redeclareMod)
      equation
        env_1 = Env.extendFrameDefunit(env,elt);
        (env_2,ih) = addClassdefsToEnv2(env_1, ih, pre, xs, impl, redeclareMod);
      then (env_2,ih);

    case(env,ih,pre,_,_,_)
      equation
        Debug.fprint("failtrace", "- Inst.addClassdefsToEnv2 failed\n");
      then
        fail();
  end matchcontinue;
end addClassdefsToEnv2;

protected function isStructuralParameter
"function: isStructuralParameter
  author: PA
  This function investigates a component to find out if it is a structural parameter.
  This is achieved by looking at the restriction to find if it is a parameter
  and by investigating all components to find it is used in array dimensions
  of the component. A parameter can also be structural if is is used
  in an if equation with different number of equations in each branch."
  input SCode.Variability inVariability;
  input Absyn.ComponentRef inComponentRef;
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst;
  input list<SCode.Equation> inSCodeEquationLst;
  output Boolean outBoolean;
algorithm
  outBoolean := matchcontinue (inVariability,inComponentRef,inTplSCodeElementModLst,inSCodeEquationLst)
    local
      list<Absyn.ComponentRef> crefs;
      Boolean b1,b2,res;
      SCode.Variability param;
      Absyn.ComponentRef compname;
      list<tuple<SCode.Element, DAE.Mod>> allcomps;
      list<SCode.Equation> eqns;
    /* constants does not need to be checked.
   * Must return false here to prevent constants from be outputed
   * as structural parameters, i.e. \"parameter\" in DAE, which is
   * incorrect
   */
    case (SCode.CONST(),_,_,_) then false;

    /* Check if structural:
   * 1. By investigating array dimensions.
   * 2. By investigating if-equations.
   */
    case (param,compname,allcomps,eqns)
      equation
        true = SCode.isParameterOrConst(param);
        crefs = getCrefsFromCompdims(allcomps);
        b1 = memberCrefs(compname, crefs);
        b2 = isStructuralIfEquationParameter(compname, eqns);
        res = boolOr(b1, b2);
      then
        res;
    case (_,_,_,_) then false;
  end matchcontinue;
end isStructuralParameter;

protected function isStructuralIfEquationParameter
"function isStructuralIfEquationParameter
  author: PA
  This function checks if a parameter is structural because
  it is present in the condition expression of an if equation."
  input Absyn.ComponentRef inComponentRef;
  input list<SCode.Equation> inSCodeEquationLst;
  output Boolean outBoolean;
algorithm
  outBoolean := matchcontinue (inComponentRef,inSCodeEquationLst)
    local
      list<Absyn.ComponentRef> crefs;
      Absyn.ComponentRef compname;
      list<Absyn.Exp> conds;
      Boolean res;
      list<SCode.Equation> eqns;
    case (_,{}) then false;
    case (compname,(SCode.EQUATION(eEquation = SCode.EQ_IF(condition = conds)) :: _))
      equation
        crefs = Util.listFlatten(Util.listMap1(conds,Absyn.getCrefFromExp,false));
        true = memberCrefs(compname, crefs);
      then
        true;
    case (compname,(_ :: eqns))
      equation
        res = isStructuralIfEquationParameter(compname, eqns);
      then
        res;
  end matchcontinue;
end isStructuralIfEquationParameter;

public function addComponentsToEnv
"function: addComponentsToEnv
  author: PA
  Since Modelica has removed the declare before use limitation, all
  components are intially added untyped to the environment, i.e. the
  SCode.Element is added. This is performed by this function. Later,
  during the second pass of the instantiation of components, the components
  are updated  in the environment. This is done by the function
  update_components_in_env. This function is also responsible for
  changing parameters into structural  parameters if they are affecting
  the number of variables or equations. This is needed because Modelica has
  no language construct for structural parameters, i.e. they must be
  detected by the compiler.

  Structural parameters are identified by investigating array dimension
  sizes of components and by investigating if-equations. If an if-equation
  has a boolean expression controlled by parameter(s), these are structural
  parameters."
  input Env.Cache inCache;
  input Env.Env inEnv1;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod2;
  input Prefix.Prefix inPrefix3;
  input Connect.Sets inSets4;
  input ClassInf.State inState5;
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst6;
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst7;
  input list<SCode.Equation> inSCodeEquationLst8;
  input InstDims inInstDims9;
  input Boolean inBoolean10;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outCache,outEnv,outIH) := matchcontinue (inCache,inEnv1,inIH,inMod2,inPrefix3,inSets4,inState5,inTplSCodeElementModLst6,inTplSCodeElementModLst7,inSCodeEquationLst8,inInstDims9,inBoolean10)
    local
      list<Env.Frame> env,env_1,env_2;
      DAE.Mod mod,cmod;
      Prefix.Prefix pre;
      Connect.Sets csets;
      ClassInf.State cistate;
      SCode.Element comp;
      String n, ns;
      SCode.Final finalPrefix;
      SCode.Replaceable repl;
      SCode.Visibility vis;
      SCode.Flow flowPrefix;
      SCode.Stream streamPrefix;
      Boolean impl;
      SCode.Redeclare redecl;
      Absyn.InnerOuter io;
      SCode.Attributes attr;
      list<Absyn.Subscript> ad;
      SCode.Variability param;
      Absyn.Direction dir;
      Absyn.TypeSpec t;
      SCode.Mod m;
      Option<SCode.Comment> comment;
      list<tuple<SCode.Element, DAE.Mod>> xs,allcomps,comps;
      list<SCode.Equation> eqns;
      InstDims instdims;
      Option<Absyn.Exp> aExp;
      Absyn.Info aInfo;
      Option<Absyn.ConstrainClass> cc;
      InstanceHierarchy ih;
      Env.Cache cache;
      Absyn.TypeSpec tss;
      Absyn.Path tpp;
      SCode.Element selem;
      DAE.Mod smod,compModLocal;
      

    /* no more components. */
    case (cache,env,ih,_,_,_,_,{},_,_,_,_) then (cache,env,ih);

    // adrpo: moved this check from instElement here as we should check this as early as possible!
    // Check if component's name is the same as its type's name
    case (cache,env,ih,mod,pre,csets,cistate,
          ((comp as SCode.COMPONENT(name = n,typeSpec = (tss as Absyn.TPATH(tpp, _)), info = aInfo)),cmod)::xs, _, _, instdims,impl)
      equation
        true = stringEq(n, Absyn.pathLastIdent(tpp));
        ns = Absyn.pathString(tpp);
        Error.addSourceMessage(Error.COMPONENT_NAME_SAME_AS_TYPE_NAME, {n,ns}, aInfo);
      then
        fail();

    /* A TPATH component */
    case (cache,env,ih,mod,pre,csets,cistate,
        (((comp as SCode.COMPONENT(name = n,
                                   prefixes = SCode.PREFIXES(
                                     visibility = vis,
                                     redeclarePrefix = redecl,
                                     finalPrefix = finalPrefix,
                                     innerOuter=io,
                                     replaceablePrefix = repl
                                   ),
                                   attributes = (attr as SCode.ATTR(arrayDims = ad,flowPrefix = flowPrefix,
                                                                    streamPrefix = streamPrefix,
                                                                    variability = param,direction = dir)),
                                   typeSpec = (tss as Absyn.TPATH(tpp, _)),
                                   modifications = m,
                                   comment = comment,
                                   condition = aExp,
                                   info = aInfo)),cmod) :: xs),
        allcomps,eqns,instdims,impl)
      equation
        compModLocal = Mod.lookupModificationP(mod, tpp);
        m = traverseModAddFinal(m, finalPrefix);

        // compModLocal = Mod.lookupCompModification12(mod,n);
        // print(" \t comp: " +& n +& " " +& " compModLocal: " +& Mod.printModStr(compModLocal) +& "\n");
        (cache,env,ih,selem,smod,csets) = redeclareType(cache,env,ih,compModLocal,
        /*comp,*/ SCode.COMPONENT(n,SCode.PREFIXES(vis,redecl,finalPrefix,io,repl),attr,tss,m,comment,aExp, aInfo),
        pre, cistate, csets, impl,cmod);
        // Debug.traceln(" adding comp: " +& n +& " " +& Mod.printModStr(mod) +& " cmod: " +& Mod.printModStr(cmod) +& " cmL: " +& Mod.printModStr(compModLocal) +& " smod: " +& Mod.printModStr(smod));
        // print(" \t comp: " +& n +& " " +& "selem: " +& SCodeDump.printElementStr(selem) +& " smod: " +& Mod.printModStr(smod) +& "\n");
        (cache,env_1,ih) = addComponentsToEnv2(cache, env, ih, mod, pre, csets, cistate, {(selem,smod)}, instdims, impl);
        (cache,env_2,ih) = addComponentsToEnv(cache, env_1, ih, mod, pre, csets, cistate, xs, allcomps, eqns, instdims, impl);
      then
        (cache,env_2,ih);

    /* A TCOMPLEX component */
    case (cache,env,ih,mod,pre,csets,cistate,
        (((comp as SCode.COMPONENT(name = n,
                                   prefixes = SCode.PREFIXES(
                                     visibility = vis,
                                     redeclarePrefix = redecl,
                                     finalPrefix = finalPrefix,
                                     innerOuter=io,
                                     replaceablePrefix = repl
                                   ),
                                   attributes = (attr as SCode.ATTR(arrayDims = ad,flowPrefix = flowPrefix,
                                                                    streamPrefix = streamPrefix,
                                                                    variability = param,direction = dir)),
                                   typeSpec = (t as Absyn.TCOMPLEX(_,_,_)),
                                   modifications = m,
                                   comment = comment,
                                   condition = aExp,
                                   info = aInfo)),cmod as DAE.NOMOD()) :: xs),
        allcomps,eqns,instdims,impl)
      equation
        m = traverseModAddFinal(m, finalPrefix);
        comp = SCode.COMPONENT(n,SCode.PREFIXES(vis,redecl,finalPrefix,io,repl),attr,t,m,comment,aExp,aInfo);
        (cache,env_1,ih) = addComponentsToEnv2(cache, env, ih, mod, pre, csets, cistate, {(comp,cmod)}, instdims, impl);
        (cache,env_2,ih) = addComponentsToEnv(cache, env_1, ih, mod, pre, csets, cistate, xs, allcomps, eqns, instdims, impl);
      then
        (cache,env_2,ih);

    /* Import statement */
    case (cache,env,ih,mod,pre,csets,cistate,((SCode.IMPORT(imp = _),_) :: xs),allcomps,eqns,instdims,impl)
      equation
        (cache,env_2,ih) = addComponentsToEnv(cache, env, ih, mod, pre, csets, cistate, xs, allcomps, eqns, instdims, impl);
      then
        (cache,env_2,ih);

    /* Extends elements */
    case (cache,env,ih,mod,pre,csets,cistate,((SCode.EXTENDS(info=_),_) :: xs),allcomps,eqns,instdims,impl)
      equation
        (cache,env_2,ih) = addComponentsToEnv(cache,env, ih, mod, pre, csets, cistate, xs, allcomps, eqns, instdims, impl);
      then
        (cache,env_2,ih);
        
    /* Class definitions */
    case (cache,env,ih,mod,pre,csets,cistate,((SCode.CLASS(name = _),_) :: xs),allcomps,eqns,instdims,impl)
      equation
        (cache,env_2,ih) = addComponentsToEnv(cache, env, ih, mod, pre, csets, cistate, xs, allcomps, eqns, instdims, impl);
      then
        (cache,env_2,ih);

    case (_,env,_,_,_,_,_,comps,_,_,_,_)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.addComponentsToEnv failed");
      then
        fail();
  end matchcontinue;
end addComponentsToEnv;

protected function addComponentsToEnv2
"function addComponentsToEnv2
  Helper function to addComponentsToEnv.
  Extends the environment with an untyped variable for the component."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst;
  input InstDims inInstDims;
  input Boolean inBoolean;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outCache,outEnv,outIH) := matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,inTplSCodeElementModLst,inInstDims,inBoolean)
    local
      DAE.Mod compmod,cmod_1,mods,cmod;
      list<Env.Frame> env_1,env_2,env;
      Prefix.Prefix pre;
      Connect.Sets csets;
      ClassInf.State ci_state;
      SCode.Element comp;
      String n;
      SCode.Final finalPrefix;
      SCode.Replaceable repl;
      SCode.Visibility vis;
      SCode.Flow flowPrefix;
      SCode.Stream streamPrefix;
      Boolean impl;
      SCode.Redeclare redecl;
      Absyn.InnerOuter io;
      SCode.Attributes attr;
      list<Absyn.Subscript> ad;
      SCode.Variability param;
      Absyn.Direction dir;
      Absyn.TypeSpec t;
      SCode.Mod m;
      Option<SCode.Comment> comment;
      list<tuple<SCode.Element, DAE.Mod>> xs,comps;
      InstDims inst_dims;
      Absyn.Info info;
      Option<Absyn.Exp> condition;
      Option<Absyn.ConstrainClass> cc;
      InstanceHierarchy ih;
      Env.Cache cache;

    // a component
    case (cache,env,ih,mods,pre,csets,ci_state,
          ((comp as SCode.COMPONENT(n,SCode.PREFIXES(vis,redecl,finalPrefix,io,repl),
                                    attr as SCode.ATTR(ad,flowPrefix,streamPrefix,param,dir),
                                    t,m,comment,condition,info),cmod) :: xs),
          inst_dims,impl)
      equation
        compmod = Mod.lookupCompModification(mods, n)
        "PA: PROBLEM, Modifiers should be merged in this phase, but
         since undeclared components can not be found (is done in this phase)
         the modifiers can not be elaborated to get a variable binding.
         Thus, we need to store the merged modifier for elaboration in
         the next stage.

         Solution: Save all modifiers in environment...
         Use type T_NOTYPE instead of as earier trying to instantiate,
         since instanitation might fail without having correct
         modifications, e.g. when instanitating a partial class that must
         be redeclared through a modification" ;
        cmod_1 = Mod.merge(compmod, cmod, env, pre);

        /*
        print("Inst.addCompToEnv: " +&
          n +& " in env " +&
          Env.printEnvPathStr(env) +& " with mod: " +& Mod.printModStr(cmod_1) +& " in element: " +&
          SCodeDump.printElementStr(comp) +& "\n");
        */

        // Debug.traceln("  extendFrameV comp " +& n +& " m:" +& Mod.printModStr(cmod_1) +& " compm: " +& Mod.printModStr(compmod) +& " cm: " +& Mod.printModStr(cmod));
        env_1 = Env.extendFrameV(env,
          DAE.TYPES_VAR(n,DAE.ATTR(flowPrefix,streamPrefix,param,dir,io),vis,
          (DAE.T_NOTYPE(),NONE()),DAE.UNBOUND(),NONE()), SOME((comp,cmod_1)), Env.VAR_UNTYPED(), {});
        (cache,env_2,ih) = addComponentsToEnv2(cache, env_1, ih, mods, pre, csets, ci_state, xs, inst_dims, impl);
        // adpro: this was twice!
        // (cache,env_2,ih) = addComponentsToEnv2(cache, env_1, ih, mods, pre, csets, ci_state, xs, inst_dims, impl);
      then
        (cache,env_2,ih);
    // no components in list
    case (cache,env,ih,_,_,_,_,{},_,_) then (cache,env,ih);
    // failtrace
    case (cache,env,ih,_,_,_,_,comps,_,_)
      equation
        Debug.fprint("failtrace", "- Inst.addComponentsToEnv2 failed\n");
        Debug.fprint("failtrace", "\n\n");
      then
        fail();
  end matchcontinue;
end addComponentsToEnv2;

protected function getCrefsFromCompdims
"function: getCrefsFromCompdims
  author: PA
  This function collects all variables from the dimensionalities of
  component elements. These variables are candidates for structural
  parameters."
  input list<tuple<SCode.Element, DAE.Mod>> inTplSCodeElementModLst;
  output list<Absyn.ComponentRef> outAbsynComponentRefLst;
algorithm
  outAbsynComponentRefLst := matchcontinue (inTplSCodeElementModLst)
    local
      list<Absyn.ComponentRef> crefs1,crefs2,crefs;
      list<Absyn.Subscript> arraydim;
      list<tuple<SCode.Element, DAE.Mod>> xs;
    case ({}) then {};
    case (((SCode.COMPONENT(attributes = SCode.ATTR(arrayDims = arraydim)),_) :: xs))
      equation
        crefs1 = getCrefFromDim(arraydim);
        crefs2 = getCrefsFromCompdims(xs);
        crefs = listAppend(crefs1, crefs2);
      then
        crefs;
    case ((_ :: xs))
      equation
        crefs = getCrefsFromCompdims(xs);
      then
        crefs;
  end matchcontinue;
end getCrefsFromCompdims;

protected function memberCrefs
"function memberCrefs
  author: PA
  This function checks if a componentreferece is a member of
  a list of component references, disregarding subscripts."
  input Absyn.ComponentRef inComponentRef;
  input list<Absyn.ComponentRef> inAbsynComponentRefLst;
  output Boolean outBoolean;
algorithm
  outBoolean := matchcontinue (inComponentRef,inAbsynComponentRefLst)
    local
      Absyn.ComponentRef cr,cr1;
      list<Absyn.ComponentRef> xs;
      Boolean res;
    case (cr,(cr1 :: xs))
      equation
        true = Absyn.crefEqualNoSubs(cr, cr1);
      then
        true;
    case (cr,(cr1 :: xs))
      equation
        false = Absyn.crefEqualNoSubs(cr, cr1);
        res = memberCrefs(cr, xs);
      then
        res;
    case (_,_) then false;
  end matchcontinue;
end memberCrefs;

public function instElement "
  This monster function instantiates an element of a class definition.  An
  element is either a class definition, a variable, or an import clause."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore inUnitStore;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input tuple<SCode.Element, DAE.Mod> inElement;
  input InstDims inInstDims;
  input Boolean inImplicit;
  input CallingScope inCallingScope;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outUnitStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output list<DAE.Var> outVars;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache, outEnv, outIH, outUnitStore, outDae, outSets, outState, outVars, outGraph):=
  matchcontinue (inCache, inEnv, inIH, inUnitStore, inMod, inPrefix, inSets, 
      inState, inElement, inInstDims, inImplicit, inCallingScope, inGraph)
    local
      Absyn.ComponentRef own_cref;
      Absyn.Direction dir;
      Absyn.Info info;
      Absyn.InnerOuter io;
      Absyn.Path t, type_name;
      Absyn.TypeSpec ts;
      Boolean already_declared, impl, is_function_input;
      CallingScope callscope;
      ClassInf.State ci_state;
      ConnectionGraph.ConnectionGraph graph, graph_new;
      Connect.Sets csets;
      DAE.Attributes dae_attr;
      DAE.Binding binding;
      DAE.ComponentRef cref, vn;
      DAE.DAElist dae;
      DAE.Mod mod, mods, class_mod, mm, cmod, mod_1, var_class_mod, m_1;
      DAE.Type ty;
      DAE.Var new_var;
      Env.Cache cache;
      Env.Env env, env2, cenv, comp_env;
      InstanceHierarchy ih;
      InstDims inst_dims;
      list<Absyn.ComponentRef> crefs, crefs1, crefs2, crefs3;
      list<Absyn.Subscript> ad;
      list<DAE.Dimension> dims;
      list<DAE.Var> vars;
      Option<Absyn.Exp> cond;
      Option<DAE.EqMod> eq;
      Option<SCode.Comment> comment;
      Prefix.Prefix pre;
      SCode.Attributes attr;
      SCode.Element cls, comp;
      SCode.Final final_prefix;
      SCode.Flow fp;
      SCode.Mod m;
      SCode.Prefixes prefixes;
      SCode.Stream sp;
      SCode.Variability vt;
      SCode.Visibility vis;
      String name, id, ns, s, scope_str;
      UnitAbsyn.InstStore store;

    // Imports are simply added to the current frame, so that the lookup rule can find them.
    // Import have already been added to the environment so there is nothing more to do here.
    case (_, _, _, _, _, _, _, _,(SCode.IMPORT(imp = _),_), _, _, _, _)
      then (inCache, inEnv, inIH, inUnitStore, DAEUtil.emptyDae, inSets, inState, {}, inGraph);

    // A new class definition. Put it in the current frame in the environment
    case (cache, env, ih, _, _, _, _, _, (SCode.CLASS(name = name,
        prefixes = SCode.PREFIXES(replaceablePrefix = SCode.REPLACEABLE(_))), _),
        _, _, _, _)
      equation
        //Redeclare of class definition, replaceable is true
        (class_mod as DAE.REDECL(tplSCodeElementModLst = {(cls,_)})) =
          Mod.lookupModificationP(inMod, Absyn.IDENT(name));
        class_mod = Types.removeMod(class_mod, name);
        (cache, env, ih, dae) = 
          instClassDecl(cache, env, ih, class_mod, inPrefix, inSets, cls, inInstDims);
      then
        (cache, env, ih, inUnitStore, dae, inSets, inState, {}, inGraph);

    // Classdefinition without redeclaration
    case (cache, env, ih, _, _, _, _, _, (cls as SCode.CLASS(name = name), _), _, _, _, _)
      equation
        class_mod = Mod.lookupModificationP(inMod, Absyn.IDENT(name));
        // This was an attempt to fix multiple class definition bug. Unfortunately, it breaks some tests. -- alleb       
        // _ = checkMultiplyDeclared(cache,env,mods,pre,csets,ci_state,(comp,cmod),inst_dims,impl);
        (cache, env, ih, dae) = instClassDecl(cache, env, ih, class_mod,
          inPrefix, inSets, cls, inInstDims);
      then
        (cache, env, ih, inUnitStore, dae, inSets, inState, {}, inGraph);

    // A component
    // This is the rule for instantiating a model component.  A component can be
    // a structured subcomponent or a variable, parameter or constant.  All of
    // these are treated in a similar way. Lookup the class name, apply
    // modifications and add the variable to the current frame in the
    // environment. Then instantiate the class with an extended prefix.
    case (cache, env, ih, store, mods, pre, csets, ci_state,
        ((comp as SCode.COMPONENT(
          name = name,
          prefixes = prefixes as SCode.PREFIXES(
            visibility = vis,
            finalPrefix = final_prefix,
            innerOuter = io
            ),
          attributes = attr as SCode.ATTR(arrayDims = ad),
          typeSpec = (ts as Absyn.TPATH(path = t)),
          modifications = m,
          comment = comment,
          condition = cond,
          info = info)), cmod),
        inst_dims, impl, callscope, graph)
      equation
        // print("  instElement: A component: " +& n +& " " +& SCode.finalStr(finalPrefix) +& "\n");
        // Debug.fprintln("debug"," instElement " +& n +& " in s:" +& Env.printEnvPathStr(env) +& " m: " +& SCodeDump.printModStr(m) +& " cm : " +& Mod.printModStr(cmod));
        m = traverseModAddFinal(m, final_prefix);
        comp = SCode.COMPONENT(name, prefixes, attr, ts, m, comment, cond, info);

        // Fails if multiple decls not identical
        already_declared = checkMultiplyDeclared(cache, env, mods, pre, csets, 
          ci_state, (comp, cmod), inst_dims, impl);
        m = traverseModAddDims(cache, env, pre, m, inst_dims, ad);
        comp = SCode.COMPONENT(name, prefixes, attr, ts, m, comment, cond, info);
        ci_state = ClassInf.trans(ci_state, ClassInf.FOUND_COMPONENT(name));
        cref = ComponentReference.makeCrefIdent(name, DAE.ET_OTHER(), {});
        (cache, vn) = PrefixUtil.prefixCref(cache, env, ih, pre, cref);

        // The class definition is fetched from the environment. Then the set of
        // modifications is calculated. The modificions is the result of merging
        // the modifications from several sources. The modification stored with
        // the class definition is put in the variable `classmod', the
        // modification passed to the function_ is extracted and put in the
        // variable `mm', and the modification that is included in the variable
        // declaration is in the variable `m'.  All of these are merged so that
        // the correct precedence rules are followed." 
        class_mod = Mod.lookupModificationP(mods, t);
        mm = Mod.lookupCompModification(mods, name);

        // The types in the environment does not have correct Binding.
        // We must update those variables that is found in m into a new environment.
        own_cref = Absyn.CREF_IDENT(name, {})  ;
        crefs1 = getCrefFromMod(m);
        crefs2 = getCrefFromDim(ad);
        crefs3 = getCrefFromCond(cond);
        crefs = Util.listFlatten({crefs1, crefs2, crefs3});

        // can call instVar
        (cache, env, ih, store, crefs) = removeSelfReferenceAndUpdate(cache, 
          env, ih, store, crefs, own_cref, t, ci_state, csets, attr, prefixes,
          impl, inst_dims, pre, mods, info);

        // can call instVar
        (cache, env2, ih, csets) = updateComponentsInEnv(cache, env, ih, pre,
          mods, crefs, ci_state, csets, impl);

        // Update the untyped modifiers to typed ones, and extract class and
        // component modifiers again.
        (cache, class_mod) = Mod.updateMod(cache, env2, ih, pre, class_mod, impl, info);
        (cache, mm) = Mod.updateMod(cache, env2, ih, pre, mm, impl, info);
        
        // (BZ part:1/2)
        // If we have a redeclaration of a inner model, we have lowest priority on it.
        // This is while if we instantiate an instance of this redeclared class with a
        // modifier, the modifier should be the value to use.
        (var_class_mod, class_mod) = modifyInstantiateClass(class_mod, t);
        
        // print("Inst.instElement: before elabMod " +& PrefixUtil.printPrefixStr(pre) +& 
        // "." +& n +& " component mod: " +& SCodeDump.printModStr(m) +& " in env: " +& 
        // Env.printEnvPathStr(env2) +& "\n");
        (cache, m_1) = Mod.elabMod(cache, env2, ih, pre, m, impl, info);
        // print("Inst.instElement: after elabMod " +& PrefixUtil.printPrefixStr(pre) +& 
        // "." +& n +& " component mod: " +& Mod.printModStr(m_1) +& " in env: " +& 
        // Env.printEnvPathStr(env2) +& "\n");

        mod = Mod.merge(mm, class_mod,  env2, pre);
        mod = Mod.merge(mod, m_1, env2, pre);
        mod = Mod.merge(cmod, mod, env2, pre);

        /* (BZ part:2/2) here we merge the redeclared class modifier.
         * Redeclaration has lowest priority and if we have any local modifiers,
         * they will be used before "global" modifers.
         */
        mod = Mod.merge(mod, var_class_mod, env2, pre);

        /* Apply redeclaration modifier to component */
        (cache, env2, ih, SCode.COMPONENT(name, 
          prefixes as SCode.PREFIXES(innerOuter = io),
          attr as SCode.ATTR(arrayDims = ad, variability = vt, direction = dir),
          Absyn.TPATH(t, _), m, comment, cond, _), mod_1, csets) 
          = redeclareType(cache, env2, ih, mod, comp, pre, ci_state, csets, impl, DAE.NOMOD());

        (cache, cls, cenv) = Lookup.lookupClass(cache, env, t, true);
        
        checkRecursiveDefinition(env, cenv, ci_state, cls);
        
        // If the element is protected, and an external modification 
        // is applied, it is an error. 
        checkProt(vis, mm, vn);
        eq = Mod.modEquation(mod);
        
        // The variable declaration and the (optional) equation modification are inspected for array dimensions.
        is_function_input = isFunctionInput(ci_state, dir);
        (cache, dims) = elabArraydim(cache, env2, own_cref, t, ad, eq, impl, 
          NONE(), true, is_function_input, pre, info, inst_dims);

        //Instantiate the component  
        // Start a new "set" of inst_dims for this component (in instance hierarchy), see InstDims
        inst_dims = listAppend(inst_dims,{{}}); 
        (cache,mod_1) = Mod.updateMod(cache, cenv, ih, pre, mod_1, impl, info);
        
        // adrpo: 2010-09-28: check if the IDX mod doesn't overlap!
        Mod.checkIdxModsForNoOverlap(mod_1, PrefixUtil.prefixAdd(name, {}, pre, vt, ci_state), info);
        
        (cache, comp_env, ih, store, dae, csets, ty, graph_new) = instVar(cache,
          cenv, ih, store, ci_state, mod_1, pre, csets, name, cls, attr,
          prefixes, dims, {}, inst_dims, impl, comment, info, graph, env2);
        
        // print("instElement -> component: " +& n +& " ty: " +& Types.printTypeStr(ty) +& "\n");
        
        //The environment is extended (updated) with the new variable binding. 
        (cache, binding) = makeBinding(cache, env2, attr, mod, ty, pre, name, info);
        
        /* uncomment this for debugging of bindings from mods 
        print("Created binding for var: " +& 
           PrefixUtil.printPrefixStr(pre) +& "." +& n +&
           " binding: " +& DAEUtil.printBindingExpStr(binding) +& 
           " mods: " +& Mod.printModStr(mod_1) +&
           "\n");
        */
        
        dae_attr = DAEUtil.translateSCodeAttrToDAEAttr(attr, prefixes);
        new_var = DAE.TYPES_VAR(name, dae_attr, vis, ty, binding, NONE());

        // Type info present. Now we can also put the binding into the dae.
        // If the type is one of the simple, predifined types a simple variable
        // declaration is added to the DAE.
        env = Env.updateFrameV(env2, new_var, Env.VAR_DAE(), comp_env);
        vars = Util.if_(already_declared, {}, {new_var});
        dae = Util.if_(already_declared, DAEUtil.emptyDae, dae);
        (_, ih, graph) = InnerOuter.handleInnerOuterEquations(io, DAEUtil.emptyDae, ih, graph_new, graph);

      then
        (cache, env, ih, store, dae, csets, ci_state, vars, graph);

    //------------------------------------------------------------------------
    // MetaModelica Complex Types. Part of MetaModelica extension.
    //------------------------------------------------------------------------
    case (cache, env, ih, store, mods, pre, csets, ci_state,
        (comp as SCode.COMPONENT(
          name,
          prefixes as SCode.PREFIXES(
            visibility = vis,
            finalPrefix = final_prefix,
            innerOuter = io
            ),
          attr as SCode.ATTR(arrayDims = ad, flowPrefix = fp, streamPrefix = sp),
          ts as Absyn.TCOMPLEX(path = type_name), m, comment, cond, info), cmod),
        inst_dims, impl, _, graph)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();

        // see if we have a modification on the inner component
        m = traverseModAddFinal(m, final_prefix);
        comp = SCode.COMPONENT(name, prefixes, attr, ts, m, comment, cond, info);

        // Fails if multiple decls not identical
        already_declared = checkMultiplyDeclared(cache, env, mods, pre, csets,
          ci_state, (comp, cmod), inst_dims, impl);
        cref = ComponentReference.makeCrefIdent(name, DAE.ET_OTHER(), {});
        (cache,vn) = PrefixUtil.prefixCref(cache, env, ih, pre, cref);

       
        // The types in the environment does not have correct Binding.
        // We must update those variables that is found in m into a new environment.
        own_cref = Absyn.CREF_IDENT(name, {}) ;
        // In case we want to EQBOUND a complex type, e.g. when declaring constants. /sjoelund 2009-10-30
        (cache, m_1) = Mod.elabMod(cache, env, ih, pre, m, impl, info); 

        //---------
        // We build up a class structure for the complex type
        id = Absyn.pathString(type_name);
        
        cls = SCode.CLASS(id, SCode.defaultPrefixes, SCode.NOT_ENCAPSULATED(), 
          SCode.NOT_PARTIAL(), SCode.R_TYPE(), SCode.DERIVED(ts, SCode.NOMOD(),
          SCode.ATTR(ad, fp, sp,  SCode.VAR(), Absyn.BIDIR()),
          NONE()), info);
       
        // The variable declaration and the (optional) equation modification are inspected for array dimensions.
        // Gather all the dimensions
        // (Absyn.IDENT("Integer") is used as a dummy)
        (cache, dims) = elabArraydim(cache, env, own_cref, Absyn.IDENT("Integer"), 
          ad, NONE(), impl, NONE(), true, false, pre, info, inst_dims);

        // Instantiate the component
        (cache, comp_env, ih, store, dae, csets, ty, graph_new) = 
          instVar(cache, env, ih, store,ci_state, m_1, pre, csets, name, cls, attr,
            prefixes, dims, {}, inst_dims, impl, comment, info, graph, env);
        
        // print("instElement -> component: " +& n +& " ty: " +& Types.printTypeStr(ty) +& "\n");
        
        // The environment is extended (updated) with the new variable binding.
        (cache, binding) = makeBinding(cache, env, attr, m_1, ty, pre, name, info);

        // true in update_frame means the variable is now instantiated.
        dae_attr = DAEUtil.translateSCodeAttrToDAEAttr(attr, prefixes);
        new_var = DAE.TYPES_VAR(name, dae_attr, vis, ty, binding, NONE()) ;

        // type info present Now we can also put the binding into the dae.
        // If the type is one of the simple, predifined types a simple variable
        // declaration is added to the DAE.
        env = Env.updateFrameV(env, new_var, Env.VAR_DAE(), comp_env)  ;
        vars = Util.if_(already_declared, {}, {new_var});
        dae = Util.if_(already_declared, DAEUtil.emptyDae, dae);
        (_, ih, graph) = InnerOuter.handleInnerOuterEquations(io, DAEUtil.emptyDae, ih, graph_new, graph);
      then
        (cache, env, ih, store, dae, csets, ci_state, vars, graph);

    //------------------------------
    // If the class lookup in the previous rule fails, this rule catches the error
    // and prints an error message about the unknown class.
    // Failure => ({},env,csets,ci_state,{})
    case (cache, env, ih, store, _, pre, csets, ci_state,
        (SCode.COMPONENT(
          name = name,
          attributes = SCode.ATTR(variability = vt),
          typeSpec = Absyn.TPATH(t,_), 
          info = info), _), _, _, _, _)
      equation
        failure((_, _, _) = Lookup.lookupClass(cache, env, t, false));
        s = Absyn.pathString(t);
        scope_str = Env.printEnvPathStr(env);
        pre = PrefixUtil.prefixAdd(name, {}, pre, vt, ci_state);
        ns = PrefixUtil.printPrefixStrIgnoreNoPre(pre);
        Error.addSourceMessage(Error.LOOKUP_ERROR_COMPNAME, {s, scope_str, ns}, info);
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("Lookup class failed:" +& Absyn.pathString(t));
      then
        fail();

    case (_, env, _, _, _, _, _, _, (comp, mod), _, _, _, _)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.instElement failed: " +& SCodeDump.printElementStr(comp));
        Debug.traceln("  Scope: " +& Env.printEnvPathStr(env));
      then
        fail();
  end matchcontinue;
end instElement;

protected function removeSelfModReference
"Help function to elabMod, removes self-references in modifiers.
 For instance, A a(x = a.y) the modifier references the component itself.
 This is removed to avoid a circular dependency, resulting in A a(x=y);"
  input Env.Cache inCache;
  input Ident preId;
  input SCode.Mod inMod;
  output Env.Cache outCache;
  output SCode.Mod outMod;
algorithm
  (outCache,outMod) := matchcontinue(inCache,preId,inMod)
    local
      Absyn.Exp e,e1; String id;
      SCode.Each ea;
      SCode.Final fi;
      list<SCode.SubMod> subs;
      Env.Cache cache;
      Integer cnt;
      Boolean delayTpCheck;

    // true to delay type checking/elabExp
    case(cache,id,SCode.MOD(fi,ea,subs,SOME((e,_))))
      equation
        ((e1,(_,cnt))) = Absyn.traverseExp(e,removeSelfModReferenceExp,(id,0));
        (cache,subs) = removeSelfModReferenceSubs(cache,id,subs);
        delayTpCheck = cnt > 0;
      then 
        (cache,SCode.MOD(fi,ea,subs,SOME((e1,delayTpCheck))));

    case(cache,id,SCode.MOD(fi,ea,subs,NONE()))
      equation
        (cache,subs) = removeSelfModReferenceSubs(cache,id,subs);
      then 
        (cache,SCode.MOD(fi,ea,subs,NONE()));
    
    case(cache,id,inMod) then (cache,inMod);
    
  end matchcontinue;
end removeSelfModReference;

protected function removeSelfModReferenceSubs
"Help function to removeSelfModeReference"
  input Env.Cache inCache;
  input String id;
  input list<SCode.SubMod> inSubs;
  output Env.Cache outCache;
  output list<SCode.SubMod> outSubs;
algorithm
 (outCache,outSubs) := matchcontinue(inCache,id,inSubs)
   local
     Env.Cache cache;
     list<SCode.Subscript> idxs;
     list<SCode.SubMod> subs;
     SCode.Mod mod;
     String ident;

   case (cache,id,{}) then (cache,{});

   case(cache, id,SCode.NAMEMOD(ident,mod)::subs)
     equation
       (cache,SCode.NOMOD()) = removeSelfModReference(cache,id,mod);
       (cache,subs) = removeSelfModReferenceSubs(cache,id,subs);
     then (cache,subs);

   case(cache, id,SCode.NAMEMOD(ident,mod)::subs)
     equation
       (cache,mod) = removeSelfModReference(cache,id,mod);
       (cache,subs) = removeSelfModReferenceSubs(cache,id,subs);
     then (cache,SCode.NAMEMOD(ident,mod)::subs);

   case(cache,id,SCode.IDXMOD(idxs,mod)::subs)
     equation
      (cache,mod) = removeSelfModReference(cache,id,mod);
     (cache,subs) = removeSelfModReferenceSubs(cache,id,subs);
     then (cache,SCode.IDXMOD(idxs,mod)::subs);
  end matchcontinue;
end removeSelfModReferenceSubs;

protected function removeSelfModReferenceExp
"Help function to removeSelfModReference."
  input tuple<Absyn.Exp,tuple<String,Integer>> inExp;
  output tuple<Absyn.Exp,tuple<String,Integer>> outExp;
algorithm
  outExp := matchcontinue(inExp)
  local
    Absyn.ComponentRef cr,cr1;
    Absyn.Exp e,e1;
    String id,id2;
    Integer cnt;
    case( (Absyn.CREF(cr),(id,cnt)))
      equation
        Absyn.CREF_IDENT(id2,_) = Absyn.crefGetFirst(cr);
        // prefix == first part of cref
        0 = stringCompare(id2,id);
        cr1 = Absyn.crefStripFirst(cr);
      then ((Absyn.CREF(cr1),(id,cnt+1)));
    // other expressions falltrough
    case((e,(id,cnt))) then ((e,(id,cnt)));
  end matchcontinue;
end removeSelfModReferenceExp;

protected function checkRecursiveDefinition
"Checks that a class does not have a recursive definition,
 i.e. an instance of itself. This is not allowed in Modelica."
  input Env.Env env;
  input Env.Env cenv;
  input ClassInf.State ci_state;
  input SCode.Element cl;
algorithm
  _ := matchcontinue(env,cenv,ci_state,cl)
    local
      Absyn.Path envPath,cenvPath;
      String name,s;
    // No envpath, nothing to check.
    case(env,cenv,ci_state,cl)
      equation
        NONE() = Env.getEnvPath(env);
      then ();
    // No recursive definition, succeed.
    case(env,cenv,ci_state,SCode.CLASS(name=name))
      equation
        envPath = Env.getEnvName(env);
        cenvPath = Env.getEnvName(Env.openScope(cenv,SCode.NOT_ENCAPSULATED(),SOME(name),NONE()));
        false = Absyn.pathEqual(envPath,cenvPath);
      then ();
    // No recursive definition, succeed.
    case(env,cenv,ci_state,cl)
      equation
        false = checkRecursiveDefinitionRecConst(ci_state,cl);
      then ();
    // report error: recursive definition
    case(env,cenv,ci_state,SCode.CLASS(name=name))
      equation
        cenvPath = Env.getEnvName(Env.openScope(cenv,SCode.NOT_ENCAPSULATED(),SOME(name),NONE()));
        s = Absyn.pathString(cenvPath);
        Error.addMessage(Error.RECURSIVE_DEFINITION,{s});
      then fail();
    // failure
    case(env,_,ci_state,cl)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprint("failtrace","-Inst.checkRecursiveDefinition failed, envpath="+&Env.printEnvPathStr(env)+&"\n");
      then fail();
  end matchcontinue;
end checkRecursiveDefinition;

protected function checkMultiplyDeclared
"Check if variable is multiply declared and
 that all declarations are identical if so."
  input Env.Cache cache;
  input Env.Env env;
  input DAE.Mod mod;
  input Prefix.Prefix prefix;
  input Connect.Sets csets;
  input ClassInf.State ciState;
  input tuple<SCode.Element, DAE.Mod> compTuple;
  input InstDims instDims;
  input Boolean impl;
  output Boolean alreadyDeclared;
algorithm
  alreadyDeclared := matchcontinue(cache,env,mod,prefix,csets,ciState,compTuple,instDims,impl)
    local
      String n,n2;
      Boolean finalPrefix,repl,prot;
      SCode.Element oldElt;
      DAE.Mod oldMod;
      tuple<SCode.Element,DAE.Mod> newComp;
      Env.InstStatus instStatus;
      SCode.Element oldClass,newClass;

    case (_,_,_,_,_,_,_,_,_) equation /*print(" dupe check setting ");*/ ErrorExt.setCheckpoint("checkMultiplyDeclared"); then fail();


    // If a component definition is replaceable, skip check
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (SCode.COMPONENT(name = n, prefixes = SCode.PREFIXES(replaceablePrefix=SCode.REPLACEABLE(_))),_)),_,_)
      equation
        ErrorExt.rollBack("checkMultiplyDeclared");
      then false;

    // If a comopnent definition is redeclaration, skip check
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (SCode.COMPONENT(name = _),DAE.REDECL(_,_,_))),_,_)
      equation
        ErrorExt.rollBack("checkMultiplyDeclared");
      then false;

    /* If a variable is declared multiple times, the first is used.
     * If the two variables are not identical, an error is given.
     */

    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (SCode.COMPONENT(name = n),_)),_,_)
      equation
        (_,_,SOME((oldElt,oldMod)),instStatus,_) = Lookup.lookupIdentLocal(cache, env, n);
        checkMultipleElementsIdentical(cache,env,(oldElt,oldMod),newComp);
        alreadyDeclared = instStatusToBool(instStatus);
        ErrorExt.delCheckpoint("checkMultiplyDeclared");
      then alreadyDeclared;

    // If not multiply declared, return.
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (SCode.COMPONENT(name = n),_)),_,_)
      equation
        failure((_,_,SOME((oldElt,oldMod)),_,_) = Lookup.lookupIdentLocal(cache, env, n));
        ErrorExt.rollBack("checkMultiplyDeclared");
      then false;


    // If a class definition is replaceable, skip check
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (SCode.CLASS(prefixes = SCode.PREFIXES(replaceablePrefix=SCode.REPLACEABLE(_))),_)),_,_)
      equation
        ErrorExt.rollBack("checkMultiplyDeclared");
      then false;

    // If a class definition is redeclaration, skip check
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (SCode.CLASS(prefixes = _),DAE.REDECL(_,_,_))),_,_)
      equation
        ErrorExt.rollBack("checkMultiplyDeclared");
      then false;

    // If a class definition is a product of InstExtends.instClassExtendsList2, skip check
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (SCode.CLASS(name=n,classDef=SCode.PARTS(elementLst=SCode.EXTENDS(baseClassPath=Absyn.IDENT(n2))::_ )),_)),_,_)
      equation
        n=n+&"$parent";
        true = stringEq(n, n2);
        ErrorExt.rollBack("checkMultiplyDeclared");
      then false;

    // If a class is defined multiple times, the first is used.
    // If the two class definitions are not equivalent, an error is given.
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (newClass as SCode.CLASS(name=n),_)),_,_)
      equation
        (oldClass,_) = Lookup.lookupClassLocal(env, n);
        checkMultipleClassesEquivalent(oldClass,newClass);
        ErrorExt.delCheckpoint("checkMultiplyDeclared");
      then true;

    // If a class not multiply defined, return.
    case (cache,env,mod,prefix,csets,ciState,
          (newComp as (newClass as SCode.CLASS(name=n),_)),_,_)
      equation
        failure((oldClass,_) = Lookup.lookupClassLocal(env, n));
        ErrorExt.rollBack("checkMultiplyDeclared");
      then false;

    // failure
    case (cache,env,mod,prefix,csets,ciState,_,_,_)
      equation
        Debug.fprint("failtrace","-Inst.checkMultiplyDeclared failed\n");
        ErrorExt.delCheckpoint("checkMultiplyDeclared");
      then fail();
  end matchcontinue;
end checkMultiplyDeclared;

protected function instStatusToBool
"Translates InstStatus to a boolean indicating if component is allready declared."
  input Env.InstStatus instStatus;
  output Boolean alreadyDeclared;
algorithm
  alreadyDeclared := match(instStatus)
    case (Env.VAR_DAE()) then true;
    case (Env.VAR_UNTYPED()) then false;
    case (Env.VAR_TYPED()) then false;
  end match;
end instStatusToBool;

protected function checkMultipleElementsIdentical
"Checks that the old declaration is identical
 to the new one. If not, give error message"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input tuple<SCode.Element,DAE.Mod> oldComponent;
  input tuple<SCode.Element,DAE.Mod> newComponent;
algorithm
  _ := matchcontinue(inCache,inEnv,oldComponent,newComponent)
    local
      SCode.Element oldElt,newElt;
      DAE.Mod oldMod,newMod;
      String s1,s2;
      SCode.Mod smod1, smod2;
      Env.Env env, env1, env2;
      Env.Cache cache;
      SCode.Element c1, c2;
      Absyn.Path tpath1, tpath2;
      Absyn.Info aInfo;
      SCode.Prefixes prefixes1, prefixes2;
      SCode.Attributes attr1,attr2;
      Absyn.TypeSpec tp1,tp2;
      String n1, n2;
      Option<Absyn.ArrayDim> ad1, ad2;
      Option<Absyn.ConstrainClass> cc1, cc2;
      Option<Absyn.Exp> cond1, cond2;

    // try equality first!
    case(cache,env,(oldElt,oldMod),(newElt,newMod))
      equation
        // NOTE: Should be type identical instead? see spec.
        // p.23, check of flattening. "Check that duplicate elements are identical".
        true = SCode.elementEqual(oldElt,newElt);
      then ();
    
    // adrpo: see if they are not syntactically equivalent, but semantically equivalent!
    //        see Modelica Spec. 3.1, page 66.
    // COMPONENT
    case (cache,env,(oldElt as SCode.COMPONENT(n1, prefixes1, attr1, tp1 as Absyn.TPATH(tpath1, ad1), smod1, _, cond1, aInfo),oldMod),
                    (newElt as SCode.COMPONENT(n2, prefixes2, attr2, tp2 as Absyn.TPATH(tpath2, ad2), smod2, _, cond2, _),newMod))
      equation
        // see if the most stuff is the same!
        true = stringEq(n1, n2);
        true = SCode.prefixesEqual(prefixes1, prefixes2);
        true = SCode.attributesEqual(attr1, attr2);
        true = SCode.modEqual(smod1, smod2);
        equality(ad1 = ad2);
        equality(cond1 = cond2);
        // if we lookup tpath1 and tpath2 and reach the same class, we're fine!
        (_, c1, env1) = Lookup.lookupClass(cache, env, tpath1, false);
        (_, c2, env2) = Lookup.lookupClass(cache, env, tpath2, false);
        // the class has the same environment
        true = stringEq(Env.printEnvPathStr(env1), Env.printEnvPathStr(env2));
        // the classes are the same!
        true = SCode.elementEqual(c1, c2);
        // add a warning and let it continue!
        s1 = SCodeDump.unparseElementStr(oldElt);
        s2 = SCodeDump.unparseElementStr(newElt);
        Error.addSourceMessage(Error.DUPLICATE_ELEMENTS_NOT_SYNTACTICALLY_IDENTICAL,{s1,s2}, aInfo);
      then ();
    
    // fail baby and add a source message!
    case (cache, env, (oldElt as SCode.COMPONENT(info=aInfo),oldMod),(newElt,newMod))
      equation
        s1 = SCodeDump.unparseElementStr(oldElt);
        s2 = SCodeDump.unparseElementStr(newElt);
        Error.addSourceMessage(Error.DUPLICATE_ELEMENTS_NOT_IDENTICAL,{s1,s2}, aInfo);
        //print(" *** error message added *** \n");
      then fail();
  end matchcontinue;
end checkMultipleElementsIdentical;

protected function checkMultipleClassesEquivalent
"Checks that the old class definition is equivalent
 to the new one. If not, give error message"
  input SCode.Element oldClass;
  input SCode.Element newClass;
algorithm
  _ := matchcontinue(oldClass,newClass)
    local
      SCode.Element oldCl,newCl;
      String s1,s2;
      list<String> sl1,sl2;
      list<SCode.Enum> enumLst;
      list<SCode.Element> elementLst;

    //   Special cases for checking enumerations which can be represented differently
    case(oldCl as SCode.CLASS(classDef=SCode.ENUMERATION(enumLst=enumLst)), newCl as SCode.CLASS(restriction=SCode.R_ENUMERATION(),classDef=SCode.PARTS(elementLst=elementLst)))
      equation
        sl1=Util.listMap(enumLst,SCode.enumName);
        sl2=Util.listMap(elementLst,SCode.elementName);
        Util.listThreadMapAllValue(sl1,sl2,stringEq,true);
      then 
        ();

    case(oldCl as SCode.CLASS(restriction=SCode.R_ENUMERATION(),classDef=SCode.PARTS(elementLst=elementLst)), newCl as SCode.CLASS(classDef=SCode.ENUMERATION(enumLst=enumLst)))
      equation
        sl1=Util.listMap(enumLst,SCode.enumName);
        sl2=Util.listMap(elementLst,SCode.elementName);
        Util.listThreadMapAllValue(sl1,sl2,stringEq,true);
      then 
        ();

    // try equality first!
    case(oldCl,newCl)
      equation
        true = SCode.elementEqual(oldCl,newCl);
      then ();

    case (oldCl,newCl)
      equation
      s1 = SCodeDump.printClassStr(oldCl);
      s2 = SCodeDump.printClassStr(newCl);
      Error.addMessage(Error.DUPLICATE_CLASSES_NOT_EQUIVALENT,{s1,s2});
      //print(" *** error message added *** \n");
      then fail();
  end matchcontinue;
end checkMultipleClassesEquivalent;

protected function removeCrefFromCrefs
"function: removeCrefFromCrefs
  Removes a variable from a variable list"
  input list<Absyn.ComponentRef> inAbsynComponentRefLst;
  input Absyn.ComponentRef inComponentRef;
  output list<Absyn.ComponentRef> outAbsynComponentRefLst;
algorithm
  outAbsynComponentRefLst := matchcontinue (inAbsynComponentRefLst,inComponentRef)
    local
      String n1,n2;
      list<Absyn.ComponentRef> rest_1,rest;
      Absyn.ComponentRef cr1,cr2;
    case ({},_) then {};
    case ((cr1 :: rest),cr2)
      equation
        Absyn.CREF_IDENT(name = n1,subscripts = {}) = cr1;
        Absyn.CREF_IDENT(name = n2,subscripts = {}) = cr2;
        true = stringEq(n1, n2);
        rest_1 = removeCrefFromCrefs(rest, cr2);
      then
        rest_1;
    case ((cr1 :: rest),cr2) // If modifier like on comp like: T t(x=t.y) => t.y must be removed
      equation
        Absyn.CREF_QUAL(name = n1) = cr1;
        Absyn.CREF_IDENT(name = n2) = cr2;
        true = stringEq(n1, n2);
        rest_1 = removeCrefFromCrefs(rest, cr2);
      then
        rest_1;
    case ((cr1 :: rest),cr2)
      equation
        rest_1 = removeCrefFromCrefs(rest, cr2);
      then
        (cr1 :: rest_1);
  end matchcontinue;
end removeCrefFromCrefs;

protected function redeclareType
"function: redeclareType
  This function takes a DAE.Mod and an SCode.Element and if the modification
  contains a redeclare of that element, the type is changed and an updated
  element is returned."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input SCode.Element inElement;
  input Prefix.Prefix inPrefix;
  input ClassInf.State inState;
  input Connect.Sets inSets;
  input Boolean inImplicit;
  input DAE.Mod cmod;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output SCode.Element outElement;
  output DAE.Mod outMod;
  output Connect.Sets outSets;
algorithm
  (outCache,outEnv,outIH,outElement,outMod,outSets) := matchcontinue (inCache,inEnv,inIH,inMod,inElement,inPrefix,inState,inSets,inImplicit,cmod)
    local
      list<Absyn.ComponentRef> crefs;
      list<Env.Frame> env_1,env;
      Connect.Sets csets;
      DAE.Mod m_1,old_m_1,m_2,m_3,m,rmod,innerCompMod,compMod;
      SCode.Element redecl,newcomp,comp,redComp;
      String n1,n2;
      SCode.Final finalPrefix,redfin;
      SCode.Each each_;
      SCode.Replaceable repl,repl2;
      SCode.Visibility vis, vis2;
      SCode.Redeclare redeclp;
      Boolean impl;
      Absyn.TypeSpec t,t2;
      SCode.Mod mod,old_mod;
      Option<SCode.Comment> comment;
      list<tuple<SCode.Element, DAE.Mod>> rest;
      Prefix.Prefix pre;
      ClassInf.State ci_state;
      Env.Cache cache;
      InstanceHierarchy ih;

      Option<SCode.ConstrainClass> cc;
      list<SCode.Element> compsOnConstrain;
      Absyn.InnerOuter io;
      SCode.Attributes at;
      Option<Absyn.Exp> cond;
      Option<Absyn.Info> nfo;
      Absyn.Info info;
      Absyn.TypeSpec apt;

    /* uncomment for debugging!
    case (cache,env,ih,inMod,inElement,
          pre,ci_state,csets,impl,cmod)
      equation
        print("redeclareType\nmodifier: " +& Mod.printModStr(inMod) +& "\nelement:" +& SCodeDump.printElementStr(inElement) +& "\n");
      then
        fail();
    */

    /* Implicit instantation */
    case (cache,env,ih,(m as DAE.REDECL(tplSCodeElementModLst = (((redecl as
          SCode.COMPONENT(name = n1,
                          prefixes = SCode.PREFIXES(
                            finalPrefix = finalPrefix,
                            replaceablePrefix = repl,
                            visibility = vis,
                            redeclarePrefix = redeclp,
                            innerOuter = io), 
                            typeSpec = t,modifications = mod,comment = comment,
                            attributes = at,condition = cond, info = info
                            )),rmod) :: rest))),
          SCode.COMPONENT(name = n2,
                          prefixes = SCode.PREFIXES(
                            finalPrefix = SCode.NOT_FINAL(),
                            replaceablePrefix = repl2 as SCode.REPLACEABLE((cc as SOME(_))),
                            visibility = vis2),
                          typeSpec = t2,
                          modifications = old_mod),
          pre,ci_state,csets,impl,cmod)
      equation
        true = stringEq(n1, n2);
        compsOnConstrain = extractConstrainingComps(cc,env,pre) "extract components belonging to constraining class";
        crefs = getCrefFromMod(mod);
        (cache,env_1,ih,csets) = updateComponentsInEnv(cache, env, ih, pre, DAE.NOMOD(), crefs, ci_state, csets, impl);
        (cache,m_1) = Mod.elabMod(cache,env_1, ih, pre, mod, impl, info);
        (cache,old_m_1) = Mod.elabMod(cache,env_1, ih, pre, old_mod, impl, info);

        old_m_1 = keepConstrainingTypeModifersOnly(old_m_1,compsOnConstrain) "keep previous constrainingclass mods";
        cmod = keepConstrainingTypeModifersOnly(cmod,compsOnConstrain) "keep previous constrainingclass mods";

        innerCompMod = Mod.merge(m_1,old_m_1,env_1,pre) "inner comp modifier merg(new_inner, old_inner) ";
        compMod = Mod.merge(rmod,cmod,env_1,pre) "outer comp modifier";

        redComp = SCode.COMPONENT(n1,
                    SCode.PREFIXES(vis, redeclp, finalPrefix, io, repl2),
                    at,t,mod,comment,cond,info);
        m_2 = Mod.merge(compMod, innerCompMod, env_1, pre);
      then
        (cache,env_1,ih,redComp,m_2,csets);

// no constraining type on comp, throw away modifiers prior to redeclaration
    case (cache,env,ih,(m as DAE.REDECL(tplSCodeElementModLst = (((redecl as
          SCode.COMPONENT(name = n1,typeSpec = t,modifications = mod,comment = comment, info = info)),rmod) :: rest))),
          SCode.COMPONENT(name = n2,
                          prefixes = SCode.PREFIXES(
                            finalPrefix = SCode.NOT_FINAL(),
                            replaceablePrefix = repl2 as SCode.REPLACEABLE(cc as NONE()),
                            visibility = vis2
                          ),
                          typeSpec = t2,modifications = old_mod),
          pre,ci_state,csets,impl,cmod)
      equation
        true = stringEq(n1, n2);
        crefs = getCrefFromMod(mod);
        (cache,env_1,ih,csets) = updateComponentsInEnv(cache,env,ih, pre, DAE.NOMOD(), crefs, ci_state, csets, impl) "m" ;
        (cache,m_1) = Mod.elabMod(cache, env_1, ih, pre, mod, impl, info);
        (cache,old_m_1) = Mod.elabMod(cache, env_1, ih, pre, old_mod, impl, info);
        m_2 = Mod.merge(rmod, m_1, env_1, pre);
        m_3 = Mod.merge(m_2, old_m_1, env_1, pre);
      then
        (cache,env_1,ih,redecl,m_3,csets);

    // redeclaration of classes:
    case (cache,env,ih,
          (m as DAE.REDECL(tplSCodeElementModLst = (((redecl as SCode.CLASS(name = n1) ),rmod) :: rest))),
          SCode.CLASS(name = n2),pre,ci_state,csets,impl,cmod)
      equation
        true = stringEq(n1, n2);
        //crefs = getCrefFromMod(mod);
        (cache,env_1,ih,csets) = updateComponentsInEnv(cache,env,ih, pre, DAE.NOMOD(), {Absyn.CREF_IDENT(n2,{})}, ci_state, csets, impl) "m" ;
        //(cache,m_1) = Mod.elabMod(cache, env_1, ih, pre, mod, impl);
        //(cache,old_m_1) = Mod.elabMod(cache, env_1, ih, pre, old_mod, impl);
        // m_2 = Mod.merge(rmod, m_1, env_1, pre);
        // m_3 = Mod.merge(m_2, old_m_1, env_1, pre);
      then
        (cache,env_1,ih,redecl,rmod,csets);

    // local redeclaration of class
    case (cache,env,ih,(m as DAE.REDECL(tplSCodeElementModLst = (((SCode.CLASS(name = n1) ),rmod) :: rest))),
        redecl as SCode.COMPONENT(typeSpec = apt),pre,ci_state,csets,impl,cmod)
      equation
        n2 = Absyn.typeSpecPathString(apt);
        true = stringEq(n1, n2);
        (cache,env_1,ih,csets) = updateComponentsInEnv(cache,env,ih, pre, DAE.NOMOD(), {Absyn.CREF_IDENT(n2,{})}, ci_state, csets, impl) "m" ;
      then
        (cache,env_1,ih,redecl,rmod,csets);

    case (cache,env,ih,(DAE.REDECL(finalPrefix = redfin, eachPrefix = each_, tplSCodeElementModLst = (((redecl as
          SCode.COMPONENT(name = n1)),rmod) :: rest))),
          (comp as SCode.COMPONENT(name = n2,prefixes = SCode.PREFIXES(finalPrefix = SCode.NOT_FINAL()))),
          pre,ci_state,csets,impl,cmod)
      equation
        false = stringEq(n1, n2);
        (cache,env_1,ih,newcomp,m,csets) =
          redeclareType(cache, env, ih, DAE.REDECL(redfin,each_,rest), comp, pre, ci_state, csets, impl, cmod);
      then
        (cache,env_1,ih,newcomp,m,csets);

    case (cache,env,ih,DAE.REDECL(finalPrefix = redfin,eachPrefix = each_,tplSCodeElementModLst = (_ :: rest)),comp,pre,ci_state,csets,impl,cmod)
      equation
        (cache,env_1,ih,newcomp,m,csets) =
          redeclareType(cache, env, ih, DAE.REDECL(redfin,each_,rest), comp, pre, ci_state, csets, impl,cmod);
      then
        (cache,env_1,ih,newcomp,m,csets);

    case (cache,env,ih,DAE.REDECL(finalPrefix = redfin,eachPrefix = each_,tplSCodeElementModLst = {}),comp,pre,ci_state,csets,impl,cmod)
      then (cache,env,ih,comp,DAE.NOMOD(),csets);

    case (cache,env,ih,m,comp,pre,ci_state,csets,impl,cmod)
      equation
        m = Mod.merge(m, cmod, env, pre);
      then
        (cache,env,ih,comp,m,csets);

    case (_,_,ih,_,_,_,_,_,_,_)
      equation
        Debug.fprintln("failtrace", "- Inst.redeclareType failed");
      then
        fail();
  end matchcontinue;
end redeclareType;

protected function keepConstrainingTypeModifersOnly
"Author: BZ, 2009-07
 A function for filtering out the modifications on the constraining type class."
  input DAE.Mod inMod;
  input list<SCode.Element> elems;
  output DAE.Mod filteredMod;
algorithm
  filteredMod := matchcontinue(inMod,elems)
    local
      SCode.Final f;
      SCode.Each e;
      Option<DAE.EqMod> oe;
      list<DAE.SubMod> subs;
      list<String> compNames;
    
    case(inMod,{}) then inMod;
    case(DAE.NOMOD(),_ ) then DAE.NOMOD();
    case(DAE.REDECL(_,_,_),_) then inMod;
    case(DAE.MOD(f,e,subs,oe),elems)
      equation
        compNames = Util.listMap(elems,SCode.elementName);
        subs = keepConstrainingTypeModifersOnly2(subs,compNames);
      then
        DAE.MOD(f,e,subs,oe);
  end matchcontinue;
end keepConstrainingTypeModifersOnly;

protected function keepConstrainingTypeModifersOnly2 "
Author BZ
Helper function for keepConstrainingTypeModifersOnly"
  input list<DAE.SubMod> subs;
  input list<String> elems;
  output list<DAE.SubMod> osubs;
algorithm 
  osubs := matchcontinue(subs,elems)
    local
      DAE.SubMod sub;
      DAE.Mod mod;
      String n;
      list<DAE.SubMod> osubs2;
      Boolean b;
    
    case({},_) then {};
    case(subs,{}) then subs;
    case((sub as DAE.NAMEMOD(ident=n,mod=mod))::subs,elems)
      equation
        osubs = keepConstrainingTypeModifersOnly2(subs,elems);
        b = Util.listContainsWithCompareFunc(n,elems,stringEq);
        osubs2 = Util.if_(b, {sub},{});
        osubs = listAppend(osubs2,osubs);
      then
        osubs;
    case(sub::subs,elems) then keepConstrainingTypeModifersOnly2(subs,elems);
    
  end matchcontinue;
end keepConstrainingTypeModifersOnly2;

protected function extractConstrainingComps
"Author: BZ, 2009-07
 This function examines a optional Absyn.ConstrainClass argument.
 If there is a constraining class, lookup the class and return its elements."
  input Option<SCode.ConstrainClass> cc;
  input Env.Env env;
  input Prefix.Prefix pre;
  output list<SCode.Element> elems;
algorithm
  elems := matchcontinue(cc,env,pre)
    local
      Absyn.Path path;
      SCode.Element cl;
      String name;
      list<SCode.Element> selems,extendselts,compelts,extcompelts,classextendselts;
      list<tuple<SCode.Element, DAE.Mod>> extcomps;
      SCode.Mod mod;
      Option<SCode.Comment> cmt;

    case(NONE(),_,_) then {};
    case(SOME(SCode.CONSTRAINCLASS(constrainingClass = path)),env,pre)
      equation
        (_,(cl as SCode.CLASS(name = name, classDef = SCode.PARTS(elementLst=selems))), _) = Lookup.lookupClass(Env.emptyCache(),env,path,false);
        (_,classextendselts,extendselts,compelts) = splitElts(selems);
        (_,_,_,_,extcomps,_,_,_,_) = InstExtends.instExtendsAndClassExtendsList(Env.emptyCache(), env, InnerOuter.emptyInstHierarchy, DAE.NOMOD(),  pre, extendselts, classextendselts, ClassInf.UNKNOWN(Absyn.IDENT("")), name, true, false);
        extcompelts = Util.listMap(extcomps,Util.tuple21);
        compelts = listAppend(compelts,extcompelts);
      then
        compelts;
    case (SOME(SCode.CONSTRAINCLASS(path, mod, cmt)), _, _)
      equation
        (_,(cl as SCode.CLASS(classDef = SCode.DERIVED(typeSpec = Absyn.TPATH(path = path)))),_) = Lookup.lookupClass(Env.emptyCache(),env,path,false);
        compelts = extractConstrainingComps(SOME(SCode.CONSTRAINCLASS(path, mod, cmt)),env,pre);
      then
        compelts;
  end matchcontinue;
end extractConstrainingComps;

protected function instVar
"function: instVar
  this function will look if a variable is inner/outer and depending on that will:
  - lookup for inner in the instanance hieararchy if we have ONLY outer
  - instantiate normally via instVar_dispatch otherwise
  - report an error if we have modifications on outer"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input ClassInf.State inState;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input Ident inIdent;
  input SCode.Element inClass;
  input SCode.Attributes inAttributes;
  input SCode.Prefixes inPrefixes;
  input list<DAE.Dimension> inDimensionLst;
  input list<DAE.Subscript> inIntegerLst;
  input InstDims inInstDims;
  input Boolean inImpl;
  input Option<SCode.Comment> inComment;
  input Absyn.Info info;
  input ConnectionGraph.ConnectionGraph inGraph;
  input Env.Env componentDefinitionParentEnv;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output DAE.Type outType;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm 
    (outCache,outEnv,outIH,outStore,outDae,outSets,outType,outGraph):=
    matchcontinue (inCache, inEnv, inIH, store, inState, inMod, inPrefix,
      inSets, inIdent, inClass, inAttributes, inPrefixes, inDimensionLst,
      inIntegerLst, inInstDims, inImpl, inComment, info, inGraph, 
      componentDefinitionParentEnv)
    local
      list<DAE.Dimension> dims;
      list<Env.Frame> compenv,env,innerCompEnv,outerCompEnv;
      DAE.DAElist dae, outerDAE, innerDAE;
      Connect.Sets csets,csetsInner,csetsOuter;
      DAE.Type ty;
      ClassInf.State ci_state;
      DAE.Mod mod;
      Prefix.Prefix pre, innerPrefix;
      String n,s1,s2,s3,s;
      SCode.Element cl;
      SCode.Attributes attr;
      list<DAE.Subscript> idxs;
      InstDims inst_dims;
      Boolean impl;
      Option<SCode.Comment> comment;
      Env.Cache cache;
      SCode.Visibility vis;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      DAE.ComponentRef cref, crefOuter, crefInner;
      list<DAE.ComponentRef> outers;
      String nInner, typeName, fullName;
      Absyn.Path typePath;
      String innerScope;
      Absyn.InnerOuter io, ioInner;
      Option<InnerOuter.InstResult> instResult;
      SCode.Prefixes pf;

    // is ONLY inner
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl as SCode.CLASS(name=typeName),attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation
        // only inner!
        io = SCode.prefixesInnerOuter(pf);
        true = Absyn.isOnlyInner(io);
        
        // Debug.fprintln("innerouter", "- Inst.instVar inner: " +& PrefixUtil.printPrefixStr(pre) +& "/" +& n +& " in env: " +& Env.printEnvPathStr(env));
        
        // instantiate as inner
        (cache,innerCompEnv,ih,store,dae,csets,ty,graph) =
          instVar_dispatch(cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph);
        
        (cache,cref) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        fullName = ComponentReference.printComponentRefStr(cref);
        (cache, typePath) = makeFullyQualified(cache, env, Absyn.IDENT(typeName));
        
        // also all the components in the environment should be updated to be outer!
        // switch components from inner to outer in the component env.
        outerCompEnv = InnerOuter.switchInnerToOuterInEnv(innerCompEnv, cref);

        // outer doesn't generate a visible DAE
        outerDAE = DAEUtil.emptyDae;
       
        innerScope = Env.printEnvPathStr(componentDefinitionParentEnv);

        // add to instance hierarchy
        ih = InnerOuter.updateInstHierarchy(ih, pre, io,
               InnerOuter.INST_INNER(
                  pre, // prefix
                  n, // component name,
                  io, // inner outer atttributes
                  fullName, // full component name
                  typePath, // fully qual type path
                  innerScope, // the scope,                  
                  SOME(InnerOuter.INST_RESULT(cache,outerCompEnv,store,outerDAE,csets,ty,graph)), // instantiation result 
                  {} // outers connected to this inner
                  ));
      then
        (cache,innerCompEnv,ih,store,dae,csets,ty,graph);

    // is ONLY outer and it has modifications on it!
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation
        // only outer!
        io = SCode.prefixesInnerOuter(pf);
        true = Absyn.isOnlyOuter(io);

        // we should have here any kind of modification!
        false = Mod.modEqual(mod, DAE.NOMOD());
        (cache,cref) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        s1 = ComponentReference.printComponentRefStr(cref);
        s2 = Mod.prettyPrintMod(mod, 0);
        s = s1 +&  " " +& s2;
        // add a warning!
        Error.addMessage(Error.OUTER_MODIFICATION, {s});

        // call myself without any modification!
        (cache,compenv,ih,store,dae,csets,ty,graph) = 
           instVar(cache,env,ih,store,ci_state,DAE.NOMOD(),pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv);
     then
        (cache,compenv,ih,store,dae,csets,ty,graph);
        
    // is ONLY outer
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation
        // only outer!
        io = SCode.prefixesInnerOuter(pf);
        true = Absyn.isOnlyOuter(io);
        
        // we should have NO modifications on only outer!
        true = Mod.modEqual(mod, DAE.NOMOD());

        // Debug.fprintln("innerouter", "- Inst.instVar outer: " +& PrefixUtil.printPrefixStr(pre) +& "/" +& n +& " in env: " +& Env.printEnvPathStr(env));
        
        // lookup in IH
        InnerOuter.INST_INNER(
           innerPrefix, 
           nInner, 
           ioInner, 
           fullName, 
           typePath, 
           innerScope, 
           instResult as SOME(InnerOuter.INST_RESULT(cache,compenv,store,outerDAE,_,ty,graph)),outers) =
          InnerOuter.lookupInnerVar(cache, env, ih, pre, n, io);

        // add outer prefix + component name and its corresponding inner prefix to the IH
        (cache,crefOuter) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        (cache,crefInner) = PrefixUtil.prefixCref(cache,env,ih,innerPrefix, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        ih = InnerOuter.addOuterPrefixToIH(ih, crefOuter, crefInner);
        
        // update the inner with the outer for easy reference
        ih = InnerOuter.updateInstHierarchy(ih, innerPrefix, ioInner,
               InnerOuter.INST_INNER(
                  innerPrefix, // prefix
                  nInner, // component name,
                  ioInner, // inner outer atttributes
                  fullName, // full component name
                  typePath, // fully qual type path
                  innerScope, // the scope,                  
                  instResult, 
                  crefOuter::outers // outers connected to this inner
                  ));

        // outer dae has no meaning!
        outerDAE = DAEUtil.emptyDae;
      then
        (cache,compenv,ih,store,outerDAE,csets,ty,graph);

    // is ONLY outer and the inner was not yet set in the IH or we have no inner declaration!
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation 
        // only outer!
        io = SCode.prefixesInnerOuter(pf);
        true = Absyn.isOnlyOuter(io);
        
        // no modifications!
        true = Mod.modEqual(mod, DAE.NOMOD());
        
        // lookup in IH, crap, we couldn't find it!
        // lookup in IH
        InnerOuter.INST_INNER(
           innerPrefix, 
           nInner, 
           ioInner, 
           fullName, 
           typePath, 
           innerScope, 
           instResult as NONE(),outers) =
          InnerOuter.lookupInnerVar(cache, env, ih, pre, n, io);
        
        // Debug.fprintln("innerouter", "- Inst.instVar failed to lookup inner: " +& PrefixUtil.printPrefixStr(pre) +& "/" +& n +& " in env: " +& Env.printEnvPathStr(env));
        
        // display an error message!
        (cache,crefOuter) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        s1 = ComponentReference.printComponentRefStr(crefOuter);
        s2 = Dump.unparseInnerouterStr(io);
        s3 = InnerOuter.getExistingInnerDeclarations(ih, componentDefinitionParentEnv);
        // adrpo: do NOT! display an error message if impl = true and prefix is Prefix.NOPRE()
        // print(Util.if_(impl, "impl crap\n", "no impl\n"));
        Debug.bcall(impl and listMember(pre, {Prefix.NOPRE()}), ErrorExt.setCheckpoint, "innerouter-instVar-implicit");
        Error.addMessage(Error.MISSING_INNER_PREFIX,{s1, s2, s3});
        Debug.bcall(impl and listMember(pre, {Prefix.NOPRE()}), ErrorExt.rollBack, "innerouter-instVar-implicit");
        
        // call it normaly
        (cache,compenv,ih,store,dae,_,ty,graph) =
           instVar_dispatch(cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph);
      then
        (cache,compenv,ih,store,dae,csets,ty,graph);

    // is ONLY outer and the inner was not yet set in the IH or we have no inner declaration!
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation
        // only outer!
        io = SCode.prefixesInnerOuter(pf);
        true = Absyn.isOnlyOuter(io);
        
        // no modifications!
        true = Mod.modEqual(mod, DAE.NOMOD());
        
        // lookup in IH, crap, we couldn't find it!
        failure(_ = InnerOuter.lookupInnerVar(cache, env, ih, pre, n, io));
        
        // Debug.fprintln("innerouter", "- Inst.instVar failed to lookup inner: " +& PrefixUtil.printPrefixStr(pre) +& "/" +& n +& " in env: " +& Env.printEnvPathStr(env));
        
        // display an error message!
        (cache,crefOuter) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        s1 = ComponentReference.printComponentRefStr(crefOuter);
        s2 = Dump.unparseInnerouterStr(io);
        s3 = InnerOuter.getExistingInnerDeclarations(ih,componentDefinitionParentEnv);
        // print(Util.if_(impl, "impl crap\n", "no impl\n"));
        // adrpo: do NOT! display an error message if impl = true and prefix is Prefix.NOPRE()
        Debug.bcall(impl and listMember(pre, {Prefix.NOPRE()}), ErrorExt.setCheckpoint, "innerouter-instVar-implicit");
        Error.addMessage(Error.MISSING_INNER_PREFIX,{s1, s2, s3});
        Debug.bcall(impl and listMember(pre, {Prefix.NOPRE()}), ErrorExt.rollBack, "innerouter-instVar-implicit");
        
        // call it normally
        (cache,compenv,ih,store,dae,_,ty,graph) =
           instVar_dispatch(cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph);
      then
        (cache,compenv,ih,store,dae,csets,ty,graph);

    // is inner outer!
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl as SCode.CLASS(name=typeName),attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation
        // both inner and outer
        io = SCode.prefixesInnerOuter(pf);
        true = Absyn.isInnerOuter(io);
        
        // Debug.fprintln("innerouter", "- Inst.instVar inner outer: " +& PrefixUtil.printPrefixStr(pre) +& "/" +& n +& " in env: " +& Env.printEnvPathStr(env));
        
        (cache,innerCompEnv,ih,store,dae,csetsInner,ty,graph) =
           instVar_dispatch(cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph);
        
        // add it to the instance hierarchy
        (cache,cref) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        fullName = ComponentReference.printComponentRefStr(cref);
        (cache, typePath) = makeFullyQualified(cache, env, Absyn.IDENT(typeName));
        
        // also all the components in the environment should be updated to be outer!
        // switch components from inner to outer in the component env.
        outerCompEnv = InnerOuter.switchInnerToOuterInEnv(innerCompEnv, cref);
        
        // keep the dae we get from the instantiation of the inner 
        innerDAE = dae;
        
        innerScope = Env.printEnvPathStr(componentDefinitionParentEnv);
        
        // add inner to the instance hierarchy
        ih = InnerOuter.updateInstHierarchy(ih, pre, io,
               InnerOuter.INST_INNER(
                  pre, 
                  n, 
                  io,
                  fullName,
                  typePath,
                  innerScope,
                  SOME(InnerOuter.INST_RESULT(cache,outerCompEnv,store,innerDAE,csetsInner,ty,graph)), {}));
        
        // now instantiate it as an outer with no modifications
        pf = SCode.prefixesSetInnerOuter(pf, Absyn.OUTER());
        (cache,compenv,ih,store,dae,csetsOuter,ty,graph) =
           instVar(cache,env,ih,store,ci_state,DAE.NOMOD(),pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv);
        
        // keep the dae we get from the instantiation of the outer
        outerDAE = dae;
        
        // join the dae's (even thou' the outer is empty)
        dae = DAEUtil.joinDaes(outerDAE, innerDAE);
      then
        (cache,compenv,ih,store,dae,csetsInner,ty,graph);

    // is NO INNER NOR OUTER or it failed before!
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation
        // no inner no outer
        io = SCode.prefixesInnerOuter(pf);
        true = Absyn.isNotInnerOuter(io);
        
        // Debug.fprintln("innerouter", "- Inst.instVar NO inner NO outer: " +& PrefixUtil.printPrefixStr(pre) +& "/" +& n +& " in env: " +& Env.printEnvPathStr(env));
        
        (cache,compenv,ih,store,dae,csets,ty,graph) =
           instVar_dispatch(cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph);
      then
        (cache,compenv,ih,store,dae,csets,ty,graph);

    // failtrace
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph,componentDefinitionParentEnv)
      equation
        true = RTOpts.debugFlag("failtrace");
        (cache,cref) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n, DAE.ET_OTHER(), {}));
        Debug.fprintln("failtrace", "- Inst.instVar failed while instatiating variable: " +&
          ComponentReference.printComponentRefStr(cref) +& " " +& Mod.prettyPrintMod(mod, 0) +&
          " in scope: " +& Env.printEnvPathStr(env));
      then 
        fail();
    end matchcontinue;
end instVar;

protected function instVar_dispatch "function: instVar_dispatch
  A component element in a class may consist of several subcomponents
  or array elements.  This function is used to instantiate a
  component, instantiating all subcomponents and array elements
  separately.
  P.A: Most of the implementation is moved to instVar2. instVar collects
  dimensions for userdefined types, such that these can be correctly
  handled by instVar2 (using instArray)"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input ClassInf.State inState;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input Ident inIdent;
  input SCode.Element inClass;
  input SCode.Attributes inAttributes;
  input SCode.Prefixes inPrefixes;
  input list<DAE.Dimension> inDimensionLst;
  input list<DAE.Subscript> inIntegerLst;
  input InstDims inInstDims;
  input Boolean inBoolean;
  input Option<SCode.Comment> inSCodeCommentOption;
  input Absyn.Info info;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output DAE.Type outType;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm 
  (outCache,outEnv,outIH,outStore,outDae,outSets,outType,outGraph):=
  matchcontinue (inCache,inEnv,inIH,store,inState,inMod,inPrefix,inSets,inIdent,inClass,inAttributes,inPrefixes,inDimensionLst,inIntegerLst,inInstDims,inBoolean,inSCodeCommentOption,info,inGraph)
    local
      list<DAE.Dimension> dims;
      list<Env.Frame> compenv,env;
      DAE.DAElist dae;
      Connect.Sets csets;
      DAE.Type ty;
      ClassInf.State ci_state;
      DAE.Mod mod;
      Prefix.Prefix pre;
      String n,id;
      SCode.Element cl;
      SCode.Attributes attr;
      list<DAE.Subscript> idxs;
      InstDims inst_dims;
      Boolean impl;
      Option<SCode.Comment> comment;
      Env.Cache cache;
      Absyn.Path p1;
      String str;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      DAE.Mod type_mods;
      SCode.Prefixes pf;

     // impl component environment dae elements for component Variables of userdefined type,
     // e.g. Point p => Real p[3]; These must be handled separately since even if they do not
     // appear to be an array, they can. Therefore we need to collect
      // the full dimensionality and call instVar2
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl as SCode.CLASS(name = id)),attr,pf,dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        // Collect dimensions
        p1 = Absyn.IDENT(n);
        p1 = PrefixUtil.prefixPath(p1,pre);
        str = Absyn.pathString(p1);
        Error.updateCurrentComponent(str,info);
        (cache, dims as (_ :: _),cl,type_mods) = getUsertypeDimensions(cache, env, ih, mod, pre, cl, inst_dims, impl);
        mod = Mod.merge(mod, type_mods, env, pre);

        attr = propagateClassPrefix(attr,pre);
        (cache,compenv,ih,store,dae,csets,ty,graph) = 
          instVar2(cache,env,ih,store, ci_state, mod, pre, csets, n, cl, attr,
            pf, dims, idxs, inst_dims, impl, comment, info, graph);
        Error.updateCurrentComponent("",Absyn.dummyInfo);
      then
        (cache,compenv,ih,store,dae,csets,ty,graph);

    // Generic case: fall through
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl as SCode.CLASS(name = id)),attr,pf,dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        p1 = Absyn.IDENT(n);
        p1 = PrefixUtil.prefixPath(p1,pre);
        str = Absyn.pathString(p1);
        Error.updateCurrentComponent(str,info);
        // print("instVar: " +& str +& " in scope " +& Env.printEnvPathStr(env) +& "\t mods: " +& Mod.printModStr(mod) +& "\n");

        attr = propagateClassPrefix(attr,pre);
        (cache,compenv,ih,store,dae,csets,ty,graph) =
          instVar2(cache,env,ih,store, ci_state, mod, pre, csets, n, cl, attr,
            pf, dims, idxs, inst_dims, impl, comment, info, graph);
        Error.updateCurrentComponent("",Absyn.dummyInfo);
      then
        (cache,compenv,ih,store,dae,csets,ty,graph);

    else
      equation
        Error.updateCurrentComponent("",Absyn.dummyInfo);
      then fail();
  end matchcontinue;
end instVar_dispatch;

protected function instVar2
"function: instVar2
  Helper function to instVar, does the main work."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore inStore;
  input ClassInf.State inState;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input Ident inName;
  input SCode.Element inClass;
  input SCode.Attributes inAttributes;
  input SCode.Prefixes inPrefixes;
  input list<DAE.Dimension> inDimensions;
  input list<DAE.Subscript> inSubscripts;
  input InstDims inInstDims;
  input Boolean inImpl;
  input Option<SCode.Comment> inComment;
  input Absyn.Info inInfo;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output DAE.Type outType;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outType,outGraph):=
  matchcontinue (inCache,inEnv,inIH,inStore,inState,inMod,inPrefix,inSets,inName,inClass,inAttributes,inPrefixes,inDimensions,inSubscripts,inInstDims,inImpl,inComment,inInfo,inGraph)
    local
      InstDims inst_dims,inst_dims_1;
      list<DAE.Subscript> dims_1;
      DAE.Exp e,e_1;
      DAE.Properties p;
      list<Env.Frame> env_1,env,compenv;
      Connect.Sets csets_1,csets;
      DAE.Type ty,ty_1,arrty;
      ClassInf.State st,ci_state;
      DAE.ComponentRef cr;
      DAE.ExpType ty_2;
      DAE.DAElist dae1,dae,dae1_1,dae3,dae2,daex;
      DAE.Mod mod,mod2;
      Prefix.Prefix pre,pre_1;
      String n;
      SCode.Element cl;
      SCode.Attributes attr;
      list<DAE.Dimension> dims;
      list<DAE.Subscript> idxs,idxs_1;
      Boolean impl;
      SCode.Flow flowPrefix;
      SCode.Stream streamPrefix;
      Option<SCode.Comment> comment;
      Option<DAE.VariableAttributes> dae_var_attr;
      SCode.Variability vt;
      Absyn.Direction dir;
      Option<DAE.Exp> start;
      DAE.Subscript dime;
      DAE.Dimension dim;
      Env.Cache cache;
      SCode.Visibility vis;
      Option<DAE.Exp> eOpt "for external objects";
      DAE.ExpType identType;
      Option<SCode.Attributes> oDA;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      DAE.ElementSource source "the origin of the element";
      String ss1,n2;
      SCode.Restriction r;
      Integer deduced_dim;
      DAE.Subscript dime2;
      SCode.Prefixes pf;
      SCode.Final fin;
      Absyn.Info info;
      Absyn.InnerOuter io;
      UnitAbsyn.InstStore store;

    // Rules for instantation of function variables (e.g. input and output

    // Function variables with modifiers (outputs or local/protected variables)
    // For Functions we cannot always find dimensional sizes. e.g. 
    // input Real x[:]; component environement The class is instantiated 
    // with the calculated modification, and an extended prefix. 
    //     
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        ClassInf.isFunction(ci_state);

        //Do not flatten because it is a function
        dims_1 = instDimExpLst(dims, impl);
                
        //get the equation modification 
        SOME(DAE.TYPED(e,_,p,_)) = Mod.modEquation(mod);
        //Instantiate type of the component, skip dae/not flattening (but extract functions)
        // adrpo: do not send in the modifications as it will fail if the modification is an ARRAY. 
        //        anyhow the modifications are handled below.
        //        input Integer sequence[3](min = {1,1,1}, max = {3,3,3}) = {1,2,3}; // this will fail if we send in the mod.
        //        see testsuite/mofiles/Sequence.mo
        (cache,env_1,ih,store,dae1,csets_1,ty,st,_,graph) = 
          instClass(cache, env, ih, store, /* mod */ DAE.NOMOD(), pre, csets, cl, inst_dims, impl, INNER_CALL(), graph);
        //Make it an array type since we are not flattening
        ty_1 = makeArrayType(dims, ty);

        (cache,dae_var_attr) = instDaeVariableAttributes(cache,env, mod, ty, {});
        // Check binding type matches variable type
        (e_1,_) = Types.matchProp(e,p,DAE.PROP(ty_1,DAE.C_VAR()),true);

        //Generate variable with default binding
        ty_2 = Types.elabType(ty_1);
        (cache,cr) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n,ty_2,{}));

        // set the source of this element
        source = DAEUtil.createElementSource(info, Env.getEnvPath(env), PrefixUtil.prefixToCrefOpt(pre), NONE(), NONE());

        
        SCode.PREFIXES(visibility = vis, finalPrefix = fin, innerOuter = io) = pf;
        dae = daeDeclare(cr, ci_state, ty, attr, vis, SOME(e_1), {dims_1}, NONE(), dae_var_attr, comment, io, fin, source, true);
        store = UnitAbsynBuilder.instAddStore(store,ty,cr);
      then
        (cache,env_1,ih,store,dae,csets_1,ty_1,graph);

    // Function variables without binding
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl as SCode.CLASS(name=n2)),attr,pf,dims,idxs,inst_dims,impl,comment,info,graph)
       equation
        ClassInf.isFunction(ci_state);
         //Instantiate type of the component, skip dae/not flattening
        (cache,env_1,ih,store,dae1,csets,ty,st,_,_) = 
          instClass(cache, env, ih, store, mod, pre, csets, cl, inst_dims, impl, INNER_CALL(), ConnectionGraph.EMPTY) ;
        (cache,cr) = PrefixUtil.prefixCref(cache,env,ih,pre, ComponentReference.makeCrefIdent(n,DAE.ET_OTHER(),{}));
        (cache,dae_var_attr) = instDaeVariableAttributes(cache,env, mod, ty, {});
        //Do all dimensions...
        dims_1 = instDimExpLst(dims, impl);

        // set the source of this element
        source = DAEUtil.createElementSource(info, Env.getEnvPath(env), PrefixUtil.prefixToCrefOpt(pre), NONE(), NONE());

        SCode.PREFIXES(visibility = vis, finalPrefix = fin, innerOuter = io) = pf;
        dae = daeDeclare(cr, ci_state, ty, attr,vis,NONE(), {dims_1},NONE(), dae_var_attr, comment,io,fin,source,true);
        arrty = makeArrayType(dims, ty);
        store = UnitAbsynBuilder.instAddStore(store,ty,cr);
      then
        (cache,env_1,ih,store,dae,csets,arrty,graph);

    // Scalar variables.
    case (_, _, _, _, _, _, _, _, _, _, _, _, {}, _, _, _, _, _, _)
      equation
        (cache, env, ih, store, dae, csets, ty, graph) = instScalar(
            inCache, inEnv, inIH, inStore, inState, inMod, inPrefix,
            inSets, inName, inClass, inAttributes, inPrefixes, inSubscripts,
            inInstDims, inImpl, inComment, inInfo, inGraph);
      then
        (cache, env, ih, store, dae, csets, ty, graph);
            
    // Array variables with unknown dimensions, e.g. Real x[:] = [some expression that can be used to determine dimension]. 
    case (cache,env,ih,store,ci_state,(mod as DAE.MOD(eqModOption = SOME(DAE.TYPED(e,_,_,_)))),pre,csets,n,cl,attr,pf,
      ((dim as DAE.DIM_UNKNOWN()) :: dims),idxs,inst_dims,impl,comment,info,graph)
      equation
        true = RTOpts.splitArrays();
        // Try to deduce the dimension from the modifier.
        (dime as DAE.INDEX(DAE.ICONST(integer = deduced_dim))) = 
          instWholeDimFromMod(dim, mod, n, info);
        dim = DAE.DIM_INTEGER(deduced_dim);
        inst_dims_1 = Util.listListAppendLast(inst_dims, {dime});
        (cache,compenv,ih,store,dae,csets,ty,graph) =
          instArray(cache,env,ih,store, ci_state, mod, pre, csets, n, (cl,attr), pf, 1, dim, dims, idxs, inst_dims_1, impl, comment,info,graph);
        ty_1 = liftNonBasicTypes(ty,dim); // Do not lift types extending basic type, they are already array types.
      then
        (cache,compenv,ih,store,dae,csets,ty_1,graph);

    // Array variables with unknown dimensions, non-expanding case 
    case (cache,env,ih,store,ci_state,(mod as DAE.MOD(eqModOption = SOME(DAE.TYPED(e,_,_,_)))),pre,csets,n,cl,attr,pf,
      ((dim as DAE.DIM_UNKNOWN()) :: dims),idxs,inst_dims,impl,comment,info,graph)
      equation
        false = RTOpts.splitArrays();
        // Try to deduce the dimension from the modifier.
        dime = instWholeDimFromMod(dim, mod, n, info);
        dime2 = makeNonExpSubscript(dime);
        dim = Expression.subscriptDimension(dime);
        inst_dims_1 = Util.listListAppendLast(inst_dims, {dime2});
        (cache,compenv,ih,store,dae,csets,ty,graph) =
          instVar2(cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,dime2::idxs,inst_dims_1,impl,comment,info,graph);
        ty_1 = liftNonBasicTypes(ty,dim); // Do not lift types extending basic type, they are already array types.
      then
        (cache,compenv,ih,store,dae,csets,ty_1,graph);

    // Array variables , e.g. Real x[3]
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,(dim :: dims),idxs,inst_dims,impl,comment,info,graph)
      equation
        true = RTOpts.splitArrays();
        dime = instDimExp(dim, impl);
        inst_dims_1 = Util.listListAppendLast(inst_dims, {dime});
        (cache,compenv,ih,store,dae,csets,ty,graph) =
          instArray(cache,env,ih,store, ci_state, mod, pre, csets, n, (cl,attr), pf, 1, dim, dims, idxs, inst_dims_1, impl, comment,info,graph);
        ty_1 = liftNonBasicTypes(ty,dim); // Do not lift types extending basic type, they are already array types.
      then
        (cache,compenv,ih,store,dae,csets,ty_1,graph);

    // Array variables , non-expanding case
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,(dim :: dims),idxs,inst_dims,impl,comment,info,graph)
      equation
        false = RTOpts.splitArrays();
        dime = instDimExpNonSplit(dim, impl);
        inst_dims_1 = Util.listListAppendLast(inst_dims, {dime});
        (cache,compenv,ih,store,dae,csets,ty,graph) =
          instVar2(cache,env,ih,store,ci_state,mod,pre,csets,n,cl,attr,pf,dims,dime::idxs,inst_dims_1,impl,comment,info,graph);
        // Type lifting is done in the "scalar" case  
        //ty_1 = liftNonBasicTypes(ty,dim); // Do not lift types extending basic type, they are already array types.
      then
        (cache,compenv,ih,store,dae,csets,ty,graph);

    // failtrace 
    case (_,env,ih,_,_,mod,pre,_,n,_,_,_,_,_,_,_,_,_,_)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprintln("failtrace", "- Inst.instVar2 failed: " +&
          PrefixUtil.printPrefixStr(pre) +& "." +&
          n +& "(" +& Mod.prettyPrintMod(mod, 0) +& ")\n  Scope: " +&
          Env.printEnvPathStr(env));
      then
        fail();
  end matchcontinue;
end instVar2;

public function instScalar
  "Instantiates a scalar variable."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore inStore;
  input ClassInf.State inState;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input Ident inName;
  input SCode.Element inClass;
  input SCode.Attributes inAttributes;
  input SCode.Prefixes inPrefixes;
  input list<DAE.Subscript> inSubscripts;
  input InstDims inInstDims;
  input Boolean inImpl;
  input Option<SCode.Comment> inComment;
  input Absyn.Info inInfo;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output DAE.Type outType;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache, outEnv, outIH, outStore, outDae, outSets, outType, outGraph) :=
  matchcontinue(inCache, inEnv, inIH, inStore, inState, inMod, inPrefix, inSets,
      inName, inClass, inAttributes, inPrefixes, inSubscripts,
      inInstDims, inImpl, inComment, inInfo, inGraph)

    local
      String cls_name;
      Env.Cache cache;
      Env.Env env;
      InstanceHierarchy ih;
      UnitAbsyn.InstStore store;
      Connect.Sets csets;
      SCode.Restriction res;
      SCode.Variability vt;
      list<DAE.Subscript> idxs;
      Prefix.Prefix pre;
      ClassInf.State ci_state;
      ConnectionGraph.ConnectionGraph graph;
      DAE.DAElist dae, dae1, dae2;
      DAE.Type ty;
      DAE.ExpType ident_ty;
      DAE.ComponentRef cr;
      Option<DAE.VariableAttributes> dae_var_attr;
      Option<DAE.Exp> opt_binding;
      DAE.ElementSource source;
      SCode.Attributes attr;
      SCode.Visibility vis;
      SCode.Final fin;
      Absyn.InnerOuter io;
      DAE.StartValue start;
      Option<SCode.Attributes> opt_attr;
      SCode.Prefixes pf;

    case (cache, env, ih, store, _, _, _, csets, _, 
        SCode.CLASS(name = cls_name, restriction = res), SCode.ATTR(variability = vt), 
        SCode.PREFIXES(visibility = vis, finalPrefix = fin, innerOuter = io), 
        idxs, _, _, _, _, _)
      equation
        // Instantiate the components class.
        idxs = listReverse(idxs);
        ci_state = ClassInf.start(res, Absyn.IDENT(cls_name));
        pre = PrefixUtil.prefixAdd(inName, idxs, inPrefix, vt, ci_state);
        (cache, env, ih, store, dae1, csets, ty, ci_state, opt_attr, graph) =
          instClass(cache, env, ih, store, inMod, pre, inSets, inClass,
            inInstDims, inImpl, INNER_CALL(), inGraph);

        // Propagate and instantiate attributes.
        dae1 = propagateAttributes(dae1, inAttributes, inPrefixes, inInfo);
        (cache, dae_var_attr) = instDaeVariableAttributes(cache, env, inMod, ty, {});
        attr = propagateAbSCDirection(vt, inAttributes, opt_attr);
        attr = SCode.removeAttributeDimensions(attr);

        // Attempt to set the correct type for array variable if splitArrays is
        // false. Does not work correctly yet.
        ty = Debug.bcallret2(not RTOpts.splitArrays(), Types.liftArraySubscriptList,
          ty, Util.listFlatten(inInstDims), ty);

        // Make a component reference for the component.
        ident_ty = makeCrefBaseType(ty, inInstDims);
        cr = ComponentReference.makeCrefIdent(inName, ident_ty, idxs);
        (cache, cr) = PrefixUtil.prefixCref(cache, env, ih, inPrefix, cr);

        // adrpo: we cannot check this here as:
        //        we might have modifications on inner that we copy here
        //        Dymola doesn't report modifications on outer as error!
        //        instead we check here if the modification is not the same
        //        as the one on inner
        checkModificationOnOuter(cache, env, ih, inPrefix, inName, cr, inMod,
          vt, io, inImpl);

        // Set the source of this element.
        source = DAEUtil.createElementSource(inInfo, Env.getEnvPath(env),
          PrefixUtil.prefixToCrefOpt(inPrefix), NONE(), NONE());

        // Instantiate the components binding.
        opt_binding = makeVariableBinding(ty, inMod, toConst(vt), inPrefix, inName, source);
        start = instStartBindingExp(inMod, ty, vt);

        // Add the component to the DAE.
        dae2 = daeDeclare(cr, inState, ty, attr, vis, opt_binding, inInstDims,
          start, dae_var_attr, inComment, io, fin, source, false);
        dae2 = DAEUtil.addComponentTypeOpt(dae2, Types.getClassnameOpt(ty));
        store = UnitAbsynBuilder.instAddStore(store, ty, cr);

        // The remaining work is done in instScalar2.
        dae = instScalar2(cr, ty, vt, inMod, dae2, dae1, source, inImpl);
      then
        (cache, env, ih, store, dae, csets, ty, graph);

    else
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprintln("failtrace", "- Inst.instScalar failed on " +& inName +& "\n");
      then
        fail();
  end matchcontinue;
end instScalar;

protected function instScalar2
  "Helper function to instScalar. Some operations needed when instantiating a
  scalar depends on what kind of variable it is, i.e. constant, parameter or
  variable. This function does these operations to keep instScalar simple."
  input DAE.ComponentRef inCref;
  input DAE.Type inType;
  input SCode.Variability inVariability;
  input DAE.Mod inMod;
  input DAE.DAElist inDae;
  input DAE.DAElist inClassDae;
  input DAE.ElementSource inSource;
  input Boolean inImpl;
  output DAE.DAElist outDae;
algorithm
  outDae := match(inCref, inType, inVariability, inMod, inDae, inClassDae, inSource, inImpl)
    local
      DAE.DAElist dae;
      Absyn.Direction dir;
      SCode.Attributes attr;

    // Constant with binding.
    case (_, _, SCode.CONST(), DAE.MOD(eqModOption = SOME(DAE.TYPED(modifierAsExp = _))),
        _, _, _, _)
      equation
        dae = DAEUtil.joinDaes(inClassDae, inDae);
      then 
        dae;

    // Parameter with binding.
    case (_, _, SCode.PARAM(), DAE.MOD(eqModOption = SOME(DAE.TYPED(modifierAsExp = _))),
        _, _, _, _)
      equation
        dae = instModEquation(inCref, inType, inMod, inSource, inImpl);
        // The equations generated by instModEquation are used only to modify
        // the bindings of parameters. No extra equations are added. -- alleb
        dae = propagateBinding(inClassDae, dae);
        dae = DAEUtil.joinDaes(dae, inDae);
      then
        dae;

    // All other scalars.
    else
      equation
        dae = instModEquation(inCref, inType, inMod, inSource, inImpl);
        dae = Util.if_(Types.isComplexType(inType), dae, DAEUtil.emptyDae);
        dae = DAEUtil.joinDaes(dae, inDae);
        dae = DAEUtil.joinDaes(inClassDae, dae);
      then
        dae;
  end match;
end instScalar2;

protected function checkModificationOnOuter
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input Ident inName;
  input DAE.ComponentRef inCref;
  input DAE.Mod inMod;
  input SCode.Variability inVariability;
  input Absyn.InnerOuter inInnerOuter;
  input Boolean inImpl;
algorithm
  _ := match(inCache, inEnv, inIH, inPrefix, inName, inCref, inMod,
      inVariability, inInnerOuter, inImpl)

    case (_, _, _, _, _, _, _, SCode.CONST(), _, _)
      then ();

    case (_, _, _, _, _, _, _, SCode.PARAM(), _, _)
      then ();

    else
      equation
        // adrpo: we cannot check this here as:
        //        we might have modifications on inner that we copy here
        //        Dymola doesn't report modifications on outer as error!
        //        instead we check here if the modification is not the same
        //        as the one on inner
        false = InnerOuter.modificationOnOuter(inCache, inEnv, inIH, inPrefix,
          inName, inCref, inMod, inInnerOuter, inImpl);
      then
        ();
  end match;
end checkModificationOnOuter;

protected function liftNonBasicTypes
"Helper functin to instVar2. All array variables should be
 given array types, by lifting the type given a dimensionality.
 An exception are types extending builtin types, since they already
 have array types. This relation performs the lifting for alltypes
 except types extending basic types."
  input DAE.Type tp;
  input DAE.Dimension dimt;
  output DAE.Type outTp;
algorithm
  outTp:= matchcontinue(tp,dimt)
    case ((tp as (DAE.T_COMPLEX(_,_,SOME(_),_),_)),dimt) then tp;

    case (tp,dimt)
      equation  outTp = Types.liftArray(tp, dimt);
      then outTp;
  end matchcontinue;
end liftNonBasicTypes;

protected function makeVariableBinding "Helper relation to instVar2

For external objects the binding contains the constructor call.  This must be inserted in the DAE.VAR
as the binding expression so the constructor code can be generated.
-- BZ 2008-11, added:
If the type is not externa object, the normal binding value is bound,
Unless it is a complex var that not inherites a basic type. In that case DAE.Equation are generated."
  input DAE.Type tp;
  input DAE.Mod mod;
  input DAE.Const const;
  input Prefix.Prefix pre;
  input Ident name;
  input DAE.ElementSource source;
  output Option<DAE.Exp> eOpt;
algorithm 
  eOpt := matchcontinue(tp,mod,const,pre,name,source)
    local 
      DAE.Exp e,e1;
      DAE.Properties p;
      DAE.Const c,c1;
      Ident n;
      Prefix.Prefix pr;
      DAE.Type bt;
      String v_str, b_str, et_str, bt_str;
      Absyn.Path tpath;
      list<DAE.Var> complex_vars;
      list<DAE.SubMod> sub_mods;

    case ((DAE.T_COMPLEX(complexClassType=ClassInf.EXTERNAL_OBJ(_)),_),
        DAE.MOD(eqModOption = SOME(DAE.TYPED(modifierAsExp = e))),_,_,_,_)
      then 
        SOME(e);

    case(tp,mod,c,pr,n,_)
      equation
        SOME(DAE.TYPED(e,_,p,_)) = Mod.modEquation(mod);
        (e1,DAE.PROP(_,c1)) = Types.matchProp(e,p,DAE.PROP(tp,c),true);
        checkHigherVariability(c,c1,pr,n,e,source);
      then
        SOME(e1);

    // An empty array such as x[:] = {} will cause Types.matchProp to fail, but we
    // shouldn't print an error.
    case (tp, mod, c, pr, n, _)
      equation
        SOME(DAE.TYPED(e,_,p as DAE.PROP(type_ = bt),_)) = Mod.modEquation(mod);
        true = Types.isEmptyArray(bt);
      then
        NONE();

    // If Types.matchProp fails, print an error.
    case (tp, mod, c, pr, n, _)
      equation
        SOME(DAE.TYPED(e,_,p as DAE.PROP(type_ = bt),_)) = Mod.modEquation(mod);
        failure((e1,DAE.PROP(_,c1)) = Types.matchProp(e, p, DAE.PROP(tp, c), true));
        v_str = n;
        b_str = ExpressionDump.printExpStr(e);
        et_str = Types.unparseType(tp);
        bt_str = Types.unparseType(bt);
        Error.addSourceMessage(Error.VARIABLE_BINDING_TYPE_MISMATCH, 
        {v_str, b_str, et_str, bt_str}, DAEUtil.getElementSourceFileInfo(source));
      then
        fail();

    case (_,mod,_,_,_,_)
      equation
        failure(SOME(DAE.TYPED(_,_,_,_)) = Mod.modEquation(mod));
      then 
        NONE();
  end matchcontinue;
end makeVariableBinding;
        
protected function checkHigherVariability 
"If the binding expression has higher variability that the component, generates an error.
Helper to makeVariableBinding. Author -- alleb" 
  input DAE.Const compConst;
  input DAE.Const bindConst;
  input Prefix.Prefix pre;
  input Ident name;
  input DAE.Exp binding;
  input DAE.ElementSource source;
algorithm 
  _ := matchcontinue(compConst,bindConst,pre,name,binding,source)
  local
    DAE.Const c,c1;
    Ident n;
    String sc,sc1,se,sn;
    DAE.Exp e;
  case (c,c1,_,_,_,_)
    equation
      equality(c=c1);
    then ();
      
  // When doing checkModel we might have parameters with variable bindings, 
  // for example when the binding depends on the dimensions on an array with
  // unknown dimensions. 
  case (DAE.C_PARAM(),DAE.C_UNKNOWN(),_,_,_,_)
    equation
      true = OptManager.getOption("checkModel");
    then ();
    
  // Since c1 is generated by Types.matchProp, it can not be lower that c, so no need to check that it is higher            
  case (c,c1,pre,n,e,source)
    equation
      sn = PrefixUtil.printPrefixStr2(pre)+&n;
      sc = DAEUtil.constStr(c);
      sc1 = DAEUtil.constStr(c1);
      se = ExpressionDump.printExpStr(e);
      Error.addSourceMessage(Error.HIGHER_VARIABILITY_BINDING,{sn,sc,se,sc1}, DAEUtil.getElementSourceFileInfo(source));
    then
      fail();
  end matchcontinue;
end checkHigherVariability;

public function makeArrayType
"function: makeArrayType
  Creates an array type from the element type
  given as argument and a list of dimensional sizes."
  input list<DAE.Dimension> inDimensionLst;
  input DAE.Type inType;
  output DAE.Type outType;
algorithm
  outType := matchcontinue (inDimensionLst,inType)
    local
      DAE.Type ty,ty_1;
      Integer i;
      list<DAE.Dimension> xs;
      Option<Absyn.Path> p;
      DAE.TType tty;
    case ({},ty) then ty;
    case ((DAE.DIM_INTEGER(integer = i) :: xs),(tty,p))
      equation
        ty_1 = makeArrayType(xs, (tty,p));
      then
        ((DAE.T_ARRAY(DAE.DIM_INTEGER(i),ty_1),p));
    case ((DAE.DIM_ENUM(size = i) :: xs), (tty,p))
      equation
        ty_1 = makeArrayType(xs, (tty, p));
      then
        ((DAE.T_ARRAY(DAE.DIM_INTEGER(i),ty_1),p));
    /*case ((DAE.DIM_SUBSCRIPT(subscript = _) :: xs),(tty,p))
      equation
        ty_1 = makeArrayType(xs, (tty,p));
      then
        ((DAE.T_ARRAY(DAE.DIM_UNKNOWN(),ty_1),p));*/
    case (DAE.DIM_UNKNOWN() :: xs, (tty, p))
      equation
        ty_1 = makeArrayType(xs, (tty, p));
      then
        ((DAE.T_ARRAY(DAE.DIM_UNKNOWN(), ty_1), p));
    case (DAE.DIM_EXP(exp = _) :: xs, (tty, p))
      equation
        ty_1 = makeArrayType(xs, (tty, p));
      then
        ((DAE.T_ARRAY(DAE.DIM_UNKNOWN(), ty_1), p));
    case (_,_)
      equation
        Debug.fprintln("failtrace", "- Inst.makeArrayType failed");
      then
        fail();
  end matchcontinue;
end makeArrayType;

public function getUsertypeDimensions
"function: getUsertypeDimensions
  Retrieves the dimensions of a usertype and the innermost class type to instantiate, 
  and also any modifications from the base classes of the usertype.
  The builtin types have no dimension, whereas a user defined type might
  have dimensions. For instance, type Point = Real[3];
  has one dimension of size 3 and the class to instantiate is Real"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input SCode.Element inClass;
  input InstDims inInstDims;
  input Boolean inBoolean;
  output Env.Cache outCache;
  output list<DAE.Dimension> outDimensionLst;
  output SCode.Element classToInstantiate;
  output DAE.Mod outMods "modifications from base classes";
algorithm
  (outCache,outDimensionLst,classToInstantiate,outMods) := matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inClass,inInstDims,inBoolean)
    local
      SCode.Element cl;
      list<Env.Frame> cenv,env;
      Absyn.ComponentRef owncref;
      list<Absyn.Subscript> ad_1;
      DAE.Mod mod_1,mods_2,mods_3,mods,type_mods;
      Option<DAE.EqMod> eq;
      list<DAE.Dimension> dim1,dim2,res;
      Prefix.Prefix pre;
      String id;
      Absyn.Path cn;
      Option<list<Absyn.Subscript>> ad;
      SCode.Mod mod;
      InstDims dims;
      Boolean impl;
      Env.Cache cache;
      InstanceHierarchy ih;
      Absyn.Info info;
      list<SCode.Element> els;
      SCode.Path path;

    case (cache,_,_,_,_,cl as SCode.CLASS(name = "Real"),_,_) then (cache,{},cl,DAE.NOMOD());  /* impl */
    case (cache,_,_,_,_,cl as SCode.CLASS(name = "Integer"),_,_) then (cache,{},cl,DAE.NOMOD());
    case (cache,_,_,_,_,cl as SCode.CLASS(name = "String"),_,_) then (cache,{},cl,DAE.NOMOD());
    case (cache,_,_,_,_,cl as SCode.CLASS(name = "Boolean"),_,_) then (cache,{},cl,DAE.NOMOD());

    case (cache,_,_,_,_,cl as SCode.CLASS(restriction = SCode.R_RECORD(),
                                        classDef = SCode.PARTS(elementLst = _)),_,_) then (cache,{},cl,DAE.NOMOD());

    /*------------------------*/
    /* MetaModelica extension */
    case (cache,env,ih,_,pre,cl as SCode.CLASS(name = id, info=info,
                                          classDef = SCode.DERIVED(Absyn.TCOMPLEX(Absyn.IDENT(_),_,arrayDim = ad),
                                                                   modifications = mod)),
          dims,impl)
      equation
        true=RTOpts.acceptMetaModelicaGrammar();
        owncref = Absyn.CREF_IDENT(id,{});
        ad_1 = getOptionArraydim(ad);
        // Absyn.IDENT("Integer") used as a dummie
        (cache,dim1) = elabArraydim(cache,env, owncref, Absyn.IDENT("Integer"), ad_1,NONE(), impl,NONE(),true, false,pre,info,dims);
      then 
        (cache,dim1,cl,DAE.NOMOD());

    // Partial function definitions with no output - stefan
    case (cache,env,ih,_,_,
      cl as SCode.CLASS(name = id,restriction = SCode.R_FUNCTION(),
                        partialPrefix = SCode.PARTIAL()),_,_) 
      then 
        (cache,{},cl,DAE.NOMOD());

    case (cache,env,ih,_,_,
      SCode.CLASS(name = id,info=info,restriction = SCode.R_FUNCTION(),
                  partialPrefix = SCode.NOT_PARTIAL()),_,_)
      equation
        Error.addSourceMessage(Error.META_FUNCTION_TYPE_NO_PARTIAL_PREFIX, {id}, info);
      then fail();

      // MetaModelica Uniontype. Added 2009-05-11 sjoelund
    case (cache,env,ih,_,_,
      cl as SCode.CLASS(name = id,restriction = SCode.R_UNIONTYPE()),_,_) 
      then (cache,{},cl,DAE.NOMOD());
      /*----------------------*/
          
    /* Derived classes with restriction type, e.g. type Point = Real[3]; */
    case (cache,env,ih,mods,pre,
      inClass as SCode.CLASS(name = id,restriction = SCode.R_TYPE(),info=info,
                             classDef = SCode.DERIVED(Absyn.TPATH(path = cn, arrayDim = ad),modifications = mod)),
          dims,impl)
      equation
        (cache,cl,cenv) = Lookup.lookupClass(cache,env, cn, true);
        owncref = Absyn.CREF_IDENT(id,{});
        ad_1 = getOptionArraydim(ad);
        env = addEnumerationLiteralsToEnv(env, cl);
        (cache,mod_1) = Mod.elabMod(cache, env, ih, pre, mod, impl, info);
        mods_2 = Mod.merge(mods, mod_1, env, pre);
        eq = Mod.modEquation(mods_2);
        mods_3 = Mod.lookupCompModification(mods_2, id);
        (cache,dim1,cl,type_mods) = getUsertypeDimensions(cache,cenv,ih, mods_3, pre, cl, dims, impl);
        type_mods = Mod.merge(mod_1, type_mods, env, pre);
        (cache,dim2) = elabArraydim(cache,env, owncref, cn, ad_1, eq, impl,NONE(),true, false,pre,info,dims);
        res = listAppend(dim2, dim1);
      then
        (cache,res,cl,type_mods);

    /* extended classes type Y = Real[3]; class X extends Y; */
    case (cache,env,ih,mods,pre,
      SCode.CLASS(name = id,restriction = _,
                  classDef = SCode.PARTS(elementLst=els,
                  normalEquationLst={},
                  initialEquationLst={},
                  normalAlgorithmLst={},
                  initialAlgorithmLst={},
                  externalDecl=_)),
          dims,impl)
      equation
        (_,_,{SCode.EXTENDS(path, _, mod,_, info)},{}) = splitElts(els); // ONLY ONE extends!
        (cache,mod_1) = Mod.elabModForBasicType(cache, env, ih, pre, mod, impl, info);
        mods_2 = Mod.merge(mods, mod_1, env, pre);
        (cache,cl,cenv) = Lookup.lookupClass(cache,env, path, true);
        (cache,res,cl,type_mods) = getUsertypeDimensions(cache,env,ih,mods_2,pre,cl,{},impl);
        type_mods = Mod.merge(mods_2, type_mods, env, pre);
      then
        (cache,res,cl,type_mods);

    case (cache,_,_,_,_,cl as SCode.CLASS(name = _),_,_)
      then (cache,{},cl,DAE.NOMOD());

    case (_,_,_,_,_,SCode.CLASS(name = id),_,_)
      equation
        true = RTOpts.debugFlag("failtrace");
        id = SCodeDump.printClassStr(inClass);
        Debug.traceln("Inst.getUsertypeDimensions failed: " +& id);
      then fail();
  end matchcontinue;
end getUsertypeDimensions;

protected function addEnumerationLiteralsToEnv
  "If the input SCode.Element is an enumeration, this function adds all of it's 
   enumeration literals to the environment. This is used in getUsertypeDimensions 
   so that the modifiers on an enumeration can be elaborated when the literals
   are used, for example like this:
     type enum1 = enumeration(val1, val2);
     type enum2 = enum1(start = val1); // val1 needs to be in the environment here." 
  input Env.Env inEnv;
  input SCode.Element inClass;
  output Env.Env outEnv;
algorithm
  outEnv := matchcontinue(inEnv, inClass)
    local
      list<SCode.Element> enums;
      Env.Env env;
    case (_, SCode.CLASS(restriction = SCode.R_ENUMERATION(), classDef = SCode.PARTS(elementLst = enums)))
      equation
        env = Util.listFold(enums, addEnumerationLiteralToEnv, inEnv);
      then env;
    case (_, _) then inEnv; // Not an enumeration, no need to do anything.
  end matchcontinue;
end addEnumerationLiteralsToEnv;
    
protected function addEnumerationLiteralToEnv
  input SCode.Element inEnum;
  input Env.Env inEnv;
  output Env.Env outEnv;
algorithm
  outEnv := matchcontinue(inEnum, inEnv)
    local
      SCode.Ident lit;
      Env.Env env;
    
    case (SCode.COMPONENT(name = lit), _)
      equation
        env = Env.extendFrameV(inEnv,
          DAE.TYPES_VAR(
            lit,
            DAE.ATTR(SCode.NOT_FLOW(), SCode.NOT_STREAM(),  SCode.VAR(), Absyn.BIDIR(), Absyn.NOT_INNER_OUTER()),
            SCode.PUBLIC(),
            (DAE.T_NOTYPE(),NONE()),
            DAE.UNBOUND(),
            NONE()),
          NONE(), Env.VAR_UNTYPED(), {});
      then env;
    
    case (_, _)
      equation
        print("Inst.addEnumerationLiteralToEnv: Unknown enumeration type!\n");
      then fail();
  end matchcontinue;
end addEnumerationLiteralToEnv;
    
protected function getCrefFromMod
"function: getCrefFromMod
  author: PA
  Return all variables in a modifier, SCode.Mod.
  This is needed to prepare the second pass of instantiation, because a
  component can not be instantiated unless the types of the modifiers are
  known. Therefore the variables in all  modifiers must be instantiated
  before the component itself is instantiated. This is done by backpatching
  in the instantiation process.
  NOTE: This means that a recursive modification structure
        (which is not allowed in Modelica) will currently
        run the compiler into infinite recursion."
  input SCode.Mod inMod;
  output list<Absyn.ComponentRef> outAbsynComponentRefLst;
algorithm
  outAbsynComponentRefLst := matchcontinue (inMod)
    local
      list<Absyn.ComponentRef> res1,res2,res,l1,l2;
      SCode.Final fin;
      SCode.Each each_;
      String n;
      SCode.Mod m,mod;
      list<SCode.Element> xs;
      list<SCode.SubMod> submods;
      Absyn.Exp e;

    // For redeclarations e.g redeclare B2 b(cref=<expr>), find cref 
    case (SCode.REDECL(finalPrefix = fin,eachPrefix = each_,elementLst = (SCode.COMPONENT(name = n,modifications = m) :: xs)))
      equation
        res1 = getCrefFromMod(SCode.REDECL(fin,each_,xs));
        res2 = getCrefFromMod(m);
        res = listAppend(res1, res2);
      then
        res;

    // For redeclarations e.g redeclare B2 b(cref=<expr>), find cref
    case (SCode.REDECL(finalPrefix = fin,eachPrefix = each_,elementLst = (_ :: xs)))
      equation
        res = getCrefFromMod(SCode.REDECL(fin,each_,xs));
      then
        res;
    
    case (SCode.REDECL(finalPrefix = fin,eachPrefix = each_,elementLst = {})) then {};

    /* Find in sub modifications e.g A(B=3) find B */
    case ((mod as SCode.MOD(subModLst = submods,binding = SOME((e,_)))))
      equation
        l1 = getCrefFromSubmods(submods);
        l2 = Absyn.getCrefFromExp(e,true);
        res = listAppend(l2, l1);
      then
        res;
    case (SCode.MOD(subModLst = submods,binding = NONE()))
      equation
        res = getCrefFromSubmods(submods);
      then
        res;
    case(SCode.NOMOD()) then {};
    case (_) then {}; // this should never happen, keeping it anyway.
    case (_)
      equation
        Debug.fprintln("failtrace", "- Inst.getCrefFromMod failed");
      then
        fail();
  end matchcontinue;
end getCrefFromMod;

protected function getCrefFromDim
"function: getCrefFromDim
  author: PA
  Similar to getCrefFromMod, but investigates
  array dimensionalitites instead."
  input Absyn.ArrayDim inArrayDim;
  output list<Absyn.ComponentRef> outAbsynComponentRefLst;
algorithm
  outAbsynComponentRefLst := matchcontinue (inArrayDim)
    local
      list<Absyn.ComponentRef> l1,l2,res;
      Absyn.Exp exp;
      list<Absyn.Subscript> rest;
    case ((Absyn.SUBSCRIPT(subscript = exp) :: rest))
      equation
        l1 = getCrefFromDim(rest);
        l2 = Absyn.getCrefFromExp(exp,true);
        res = listAppend(l1, l2);
      then
        res;
    case ((Absyn.NOSUB() :: rest))
      equation
        res = getCrefFromDim(rest);
      then
        res;
    case ({}) then {};
    case (_)
      equation
        Debug.fprintln("failtrace", "- Inst.getCrefFromDim failed");
      then
        fail();
  end matchcontinue;
end getCrefFromDim;

protected function getCrefFromSubmods
"function: getCrefFromSubmods
  Helper function to getCrefFromMod, investigates sub modifiers."
  input list<SCode.SubMod> inSCodeSubModLst;
  output list<Absyn.ComponentRef> outAbsynComponentRefLst;
algorithm
  outAbsynComponentRefLst := match (inSCodeSubModLst)
    local
      list<Absyn.ComponentRef> res1,res2,res;
      SCode.Mod mod;
      list<SCode.SubMod> rest;
    case ((SCode.NAMEMOD(A = mod) :: rest))
      equation
        res1 = getCrefFromMod(mod);
        res2 = getCrefFromSubmods(rest);
        res = listAppend(res1, res2);
      then
        res;
    case ({}) then {};
  end match;
end getCrefFromSubmods;

protected function updateComponentsInEnv
"function: updateComponentsInEnv
  author: PA
  This function is the second pass of component instantiation, when a
  component can be instantiated fully and the type of the component can be
  determined. The type is added/updated to the environment such that other
  components can use it when they are instantiated."
  input Env.Cache cache;
  input Env.Env env;
  input InstanceHierarchy inIH;
  input Prefix.Prefix pre;
  input DAE.Mod mod;
  input list<Absyn.ComponentRef> crefs;
  input ClassInf.State ci_state;
  input Connect.Sets csets;
  input Boolean impl;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output Connect.Sets outSets;
protected
  String myTick, crefsStr;
algorithm
  //myTick := intString(tick());
  //crefsStr := Util.stringDelimitList(Util.listMap(crefs, Dump.printComponentRefStr),",");
  //Debug.fprintln("debug","start update comps " +& myTick +& " # " +& crefsStr);
  (outCache,outEnv,outIH,outSets,_):=
  updateComponentsInEnv2(cache,env,inIH,pre,mod,crefs,ci_state,csets,impl,HashTable5.emptyHashTable());
  //Debug.fprintln("debug","finished update comps" +& myTick);
  //print("outEnv:");print(Env.printEnvStr(outEnv));print("\n");
end updateComponentsInEnv;

protected function updateComponentInEnv
"function: updateComponentInEnv
  author: PA
  Helper function to updateComponentsInEnv.
  Does the work for one variable."
  input Env.Cache cache;
  input Env.Env env;
  input InstanceHierarchy inIH;
  input Prefix.Prefix pre;
  input DAE.Mod mod;
  input Absyn.ComponentRef cref;
  input ClassInf.State ci_state;
  input Connect.Sets csets;
  input Boolean impl;
  input HashTable5.HashTable updatedComps;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output Connect.Sets outSets;
  output HashTable5.HashTable outUpdatedComps;
algorithm
  (outCache,outEnv,outIH,outSets,outUpdatedComps) :=
  matchcontinue (cache,env,inIH,pre,mod,cref,ci_state,csets,impl,updatedComps)
    local
      String n,id;
      SCode.Final finalPrefix;
      SCode.Replaceable repl;
      SCode.Visibility vis;
      SCode.Flow flowPrefix;
      SCode.Stream streamPrefix;
      Absyn.InnerOuter io;
      SCode.Attributes attr;
      list<Absyn.Subscript> ad;
      SCode.Variability param;
      Absyn.Direction dir;
      Absyn.Path t;
      SCode.Mod m;
      Option<SCode.Comment> comment;
      DAE.Mod cmod,mods;
      SCode.Element cl;
      list<Env.Frame> cenv,env2,env_1;
      list<Absyn.ComponentRef> crefs,crefs2,crefs3,crefs_1,crefs_2;
      Connect.Sets csets_1;
      Option<Absyn.Exp> cond;
      DAE.Var tyVar;
      Env.InstStatus is;
      Absyn.Info info;
      InstanceHierarchy ih;
      Option<Absyn.ConstrainClass> cc;
      SCode.Prefixes pf;
      
    // if there are no modifications, return the same!
    //case (cache,env,ih,pre,DAE.NOMOD(),cref,ci_state,csets,impl,updatedComps)
    //  then
    //    (cache,env,ih,csets,updatedComps);
      
    // If first part of ident is a class, e.g StateSelect.None, nothing to update
    case (cache,env,ih,pre,mods,(cref /*as Absyn.CREF_QUAL(name = id)*/),ci_state,csets,impl,updatedComps)
      equation
        id = Absyn.crefFirstIdent(cref);
        (cache,cl,cenv) = Lookup.lookupClass(cache,env, Absyn.IDENT(id), false);
      then
        (cache,env,ih,csets,updatedComps);

    // Variable with NONE() element is already instantiated.
    case (cache,env,ih,pre,mods,cref,ci_state,csets,impl,updatedComps)
      equation
        id = Absyn.crefFirstIdent(cref);
        (cache,_,_,is) = Lookup.lookupIdent(cache,env,id);
        true = Env.isTyped(is) "If InstStatus is typed, return";
      then
        (cache,env,ih,csets,updatedComps);

    // the default case
    case (cache,env,ih,pre,mods,cref,ci_state,csets,impl,updatedComps)
      equation
        id = Absyn.crefFirstIdent(cref);
        (cache,tyVar,SOME((SCode.COMPONENT(n,pf as SCode.PREFIXES(innerOuter = io),(attr as SCode.ATTR(ad,flowPrefix,streamPrefix,param,dir)),Absyn.TPATH(t, _),m,comment,cond,info),cmod)),_)
          = Lookup.lookupIdent(cache, env, id);
        //Debug.traceln("update comp " +& n +& " with mods:" +& Mod.printModStr(mods) +& " m:" +& SCodeDump.printModStr(m) +& " cm:" +& Mod.printModStr(cmod));
        (cache,cl,cenv) = Lookup.lookupClass(cache, env, t, false);
        //Debug.traceln("got class " +& SCodeDump.printClassStr(cl));
        (mods,cmod,m) = noModForUpdatedComponents(param,updatedComps,cref,mods,cmod,m);
        crefs = getCrefFromMod(m);
        crefs2 = getCrefFromDim(ad);
        crefs3 = getCrefFromCond(cond);
        crefs_1 = listAppend(listAppend(crefs, crefs2),crefs3);
        crefs_2 = removeCrefFromCrefs(crefs_1, cref);
        updatedComps = BaseHashTable.add((cref,0),updatedComps);
        (cache,env2,ih,csets,updatedComps) = updateComponentsInEnv2(cache, env, ih, pre, mods, crefs_2, ci_state, csets, impl, updatedComps);
        (cache,env_1,ih,csets_1,updatedComps) = updateComponentInEnv2(cache,env2,cenv,ih,pre,t,n,ad,cl,attr,pf,DAE.ATTR(flowPrefix,streamPrefix,param,dir,io),info,m,cmod,mods,cref,ci_state,csets,impl,updatedComps);
      then
        (cache,env_1,ih,csets_1,updatedComps);

    // report an error!
    case (cache,env,ih,pre,mod,cref,ci_state,csets,impl,updatedComps)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.updateComponentInEnv failed, ident = " +& Dump.printComponentRefStr(cref));
        Debug.traceln(" mods: " +& Mod.printModStr(mod));
        Debug.traceln(" scope: " +& Env.printEnvPathStr(env));
        Debug.traceln(" prefix: " +& PrefixUtil.printPrefixStr(pre));
      then 
        fail();
    
    case (cache,env,ih,pre,mod,cref,ci_state,csets,impl,updatedComps) then (cache,env,ih,csets,updatedComps);
  end matchcontinue;
end updateComponentInEnv;

protected function updateComponentInEnv2
" Helper function, checks if the component was already instantiated.
  If it was, don't do it again."
  input Env.Cache cache;
  input Env.Env env;
  input Env.Env cenv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix pre;
  input Absyn.Path path;
  input String name;
  input list<Absyn.Subscript> ad;
  input SCode.Element cl;
  input SCode.Attributes attr;
  input SCode.Prefixes inPrefixes;
  input DAE.Attributes dattr;
  input Absyn.Info info;
  input SCode.Mod m;
  input DAE.Mod cmod;
  input DAE.Mod mod;
  input Absyn.ComponentRef cref;
  input ClassInf.State ci_state;
  input Connect.Sets csets;
  input Boolean impl;
  input HashTable5.HashTable updatedComps;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output Connect.Sets outSets;
  output HashTable5.HashTable outUpdatedComps;
algorithm
  (outCache,outEnv,outIH,outSets,outUpdatedComps) := matchcontinue (cache,env,cenv,inIH,pre,path,name,ad,cl,attr,inPrefixes,dattr,info,m,cmod,mod,cref,ci_state,csets,impl,updatedComps)
    local
      DAE.Type ty;
      DAE.Mod m_1,classmod,mm,mod_1,mod_2,mod_3;
      list<Env.Frame> compenv;
      Option<DAE.EqMod> eq;
      list<DAE.Dimension> dims;
      DAE.Binding binding;
      Absyn.ComponentRef owncref;
      InstanceHierarchy ih;
      SCode.Visibility vis;

    case (cache,env,cenv,ih,pre,path,name,ad,cl,attr,_,dattr,info,m,cmod,mod,cref,ci_state,csets,impl,updatedComps)
      equation
        1 = BaseHashTable.get(cref, updatedComps);
      then (cache,env,ih,csets,updatedComps);
    case (cache,env,cenv,ih,pre,path,name,ad,cl,attr,_,dattr,info,m,cmod,mod,cref,ci_state,csets,impl,updatedComps)
      equation        
        ErrorExt.setCheckpoint("updateComponentInEnv2");
        (cache,m_1) = Mod.elabMod(cache, env, ih, Prefix.NOPRE(), m, impl, info)
        "Prefix does not matter, since we only update types
         in env, and does not make any dae elements, etc.." ;
        ErrorExt.rollBack("updateComponentInEnv2")
        "Rollback all error since we are only interested in type, not value at this point.
         Errors that occur in elabMod which does not fail the function will be accepted.";
        classmod = Mod.lookupModificationP(mod, path);
        mm = Mod.lookupCompModification(mod, name);
        mod = Mod.merge(classmod, mm, env, Prefix.NOPRE());
        mod_1 = Mod.merge(mod, m_1, env, Prefix.NOPRE());
        mod_2 = Mod.merge(cmod, mod_1, env, Prefix.NOPRE());
        (cache,mod_3) = Mod.updateMod(cache, env, ih, Prefix.NOPRE(),mod_2,impl,info);
        eq = Mod.modEquation(mod_3);
        
        owncref = Absyn.CREF_IDENT(name,{});
        (cache,dims) = elabArraydim(cache,env,owncref,path,ad,eq,impl,NONE(),true, false,pre,info,{})
        "The variable declaration and the (optional) equation modification are inspected for array dimensions." ;
        /* Instantiate the component */
        (cache,compenv,ih,_,_,_,ty,_) = 
          instVar(cache, cenv, ih, UnitAbsyn.noStore, ci_state, mod_3, pre, csets, name, cl, attr, inPrefixes, dims, {}, {}, impl, NONE(), info, ConnectionGraph.EMPTY, env);
        
        // print("updateComponentInEnv -> 1 component: " +& n +& " ty: " +& Types.printTypeStr(ty) +& "\n");
        
        /* The environment is extended with the new variable binding. */
        (cache,binding) = makeBinding(cache, env, attr, mod_3, ty, pre, name, info);
        /* type info present */
        //Debug.fprintln("debug","VAR " +& name +& " has new type " +& Types.unparseType(ty) +& ", " +& Types.printBindingStr(binding) +& "m:" +& SCodeDump.printModStr(m));
        vis = SCode.prefixesVisibility(inPrefixes);
        env = Env.updateFrameV(env, DAE.TYPES_VAR(name,dattr,vis,ty,binding,NONE()), Env.VAR_TYPED(), compenv);
        //updatedComps = BaseHashTable.delete(cref,updatedComps);
        
        updatedComps = BaseHashTable.add((cref,1),updatedComps);
      then (cache,env,ih,csets,updatedComps);
    case (cache,env,cenv,ih,pre,path,name,ad,cl,attr,_,dattr,info,m,cmod,mod,cref,ci_state,csets,impl,updatedComps)
      equation
        //Debug.traceln("- Inst.updateComponentInEnv2 failed");
      then fail();
  end matchcontinue;
end updateComponentInEnv2;

protected function instDimExpLst
"function: instDimExpLst
  Instantiates dimension expressions, DAE.Dimension, which are transformed to DAE.Subscript\'s"
  input list<DAE.Dimension> inDimensionLst;
  input Boolean inBoolean;
  output list<DAE.Subscript> outExpSubscriptLst;
algorithm
  outExpSubscriptLst := match (inDimensionLst,inBoolean)
    local
      list<DAE.Subscript> res;
      DAE.Subscript r;
      DAE.Dimension x;
      list<DAE.Dimension> xs;
      Boolean b;
    case ({},_) then {};  /* impl */
    case ((x :: xs),b)
      equation
        res = instDimExpLst(xs, b);
        r = instDimExp(x, b);
      then
        (r :: res);
  end match;
end instDimExpLst;

protected function instDimExp
"function: instDAE.Dimension
  instantiates one dimension expression, See also instDimExpLst."
  input DAE.Dimension inDimension;
  input Boolean inBoolean;
  output DAE.Subscript outSubscript;
algorithm
  outSubscript := match (inDimension,inBoolean)
    local
      DAE.Exp e;
      Integer i;

    /* TODO: Fix slicing, e.g. DAE.SLICE, for impl=true */
    /*case (DIMEXP(subscript = DAE.WHOLEDIM()),(impl as false))
      equation
        Error.addMessage(Error.DIMENSION_NOT_KNOWN, {":"});
      then
        fail();*/
    case (DAE.DIM_UNKNOWN(),_) then DAE.WHOLEDIM();
    case (DAE.DIM_INTEGER(integer = i),_) then DAE.INDEX(DAE.ICONST(i));
    case (DAE.DIM_ENUM(size = i), _) then DAE.INDEX(DAE.ICONST(i));
    case (DAE.DIM_EXP(exp = e), _) then DAE.INDEX(e);
  end match;
end instDimExp;

protected function instDimExpNonSplit
"function: instDimExpNonSplit
  the vesrion of instDimExp for the case of non-expanded arrays"
  input DAE.Dimension inDimension;
  input Boolean inBoolean;
  output DAE.Subscript outSubscript;
algorithm
  outSubscript := matchcontinue (inDimension,inBoolean)
    local
      DAE.Exp e;
      Integer i;

    case (DAE.DIM_UNKNOWN(),_) then DAE.WHOLEDIM();
    case (DAE.DIM_INTEGER(integer = i),_) then DAE.WHOLE_NONEXP(DAE.ICONST(i));
    case (DAE.DIM_ENUM(size = i), _) then DAE.WHOLE_NONEXP(DAE.ICONST(i));
    //case (DAE.DIM_EXP(exp = e as DAE.RANGE(exp = _)), _) then DAE.INDEX(e);
    case (DAE.DIM_EXP(exp = e), _) then DAE.WHOLE_NONEXP(e);
  end matchcontinue;
end instDimExpNonSplit;

protected function instWholeDimFromMod
  "Tries to determine the size of a WHOLEDIM dimension by looking at a variables
  modifier."
  input DAE.Dimension dimensionExp;
  input DAE.Mod modifier;
  input String inVarName;
  input Absyn.Info inInfo;
  output DAE.Subscript subscript;
algorithm
  subscript := matchcontinue(dimensionExp, modifier, inVarName, inInfo)
    local  
      DAE.Dimension d;
      DAE.Subscript sub;
      DAE.Exp exp;
      String exp_str;

    case (DAE.DIM_UNKNOWN(), DAE.MOD(eqModOption = 
            SOME(DAE.TYPED(modifierAsExp = exp))), _, _)
      equation
        (d :: _) = Expression.expDimensions(exp);
        sub = Expression.dimensionSubscript(d);
      then sub;

    // TODO: We should print an error if we fail to deduce the dimensions from
    // the modifier, but we do not yet handle some cases (such as
    // Modelica.Blocks.Sources.KinematicPTP), so just print a warning for now.
    case (DAE.DIM_UNKNOWN(), DAE.MOD(eqModOption = 
            SOME(DAE.TYPED(modifierAsExp = exp))), _, _)
      equation
        exp_str = ExpressionDump.printExpStr(exp);
        Error.addSourceMessage(Error.FAILURE_TO_DEDUCE_DIMS_FROM_MOD,
          {inVarName, exp_str}, inInfo);
      then
        fail();

    case (DAE.DIM_UNKNOWN(), _, _, _)
      equation
        Debug.fprint("failtrace","- Inst.instWholeDimFromMod failed\n");
      then 
        fail();
  end matchcontinue;
end instWholeDimFromMod;

protected function propagateAttributes
  "Propagates attributes (flow, stream, discrete, parameter, constant, input,
  output) to elements in a structured component."
  input DAE.DAElist inDae;
  input SCode.Attributes inAttributes;
  input SCode.Prefixes inPrefixes;
  input Absyn.Info inInfo;
  output DAE.DAElist outDae;
protected
  list<DAE.Element> elts;
algorithm
  DAE.DAE(elementLst = elts) := inDae;
  elts := Util.listMap3(elts, propagateAllAttributes, inAttributes, inPrefixes, inInfo);
  outDae := DAE.DAE(elts);
end propagateAttributes;

protected function propagateAllAttributes
  "Helper function to propagateAttributes. Propagates all attributes if needed."
  input DAE.Element inElement;
  input SCode.Attributes inAttributes;
  input SCode.Prefixes inPrefixes;
  input Absyn.Info inInfo;
  output DAE.Element outElement;
algorithm
  outElement := match(inElement, inAttributes, inPrefixes, inInfo)
    local
      DAE.ComponentRef cr;
      DAE.VarKind vk;
      DAE.VarDirection vdir;
      DAE.VarVisibility vvis;
      DAE.Type ty;
      Option<DAE.Exp> binding;
      DAE.InstDims dims;
      SCode.Flow flow1;
      DAE.Flow flow2;
      SCode.Stream stream1;
      DAE.Stream stream2;
      DAE.ElementSource source;
      Option<DAE.VariableAttributes> var_attrs;
      Option<SCode.Comment> cmt;
      Absyn.InnerOuter io1, io2;
      SCode.Variability var;
      Absyn.Direction dir;
      SCode.Final fp;
      SCode.Ident ident;
      list<DAE.Element> el;

    // Just return the element if nothing needs to be changed.
    case (_, 
        SCode.ATTR(
          flowPrefix = SCode.NOT_FLOW(), 
          streamPrefix = SCode.NOT_STREAM(), 
          variability = SCode.VAR(), 
          direction = Absyn.BIDIR()), 
        SCode.PREFIXES(
          finalPrefix = SCode.NOT_FINAL(), 
          innerOuter = Absyn.NOT_INNER_OUTER()), _)
      then inElement;

    // Normal variable.
    case (
        DAE.VAR(
          componentRef = cr,
          kind = vk,
          direction = vdir,
          protection = vvis,
          ty = ty,
          binding = binding,
          dims = dims,
          flowPrefix = flow2,
          streamPrefix = stream2,
          source = source,
          variableAttributesOption = var_attrs,
          absynCommentOption = cmt,
          innerOuter = io2),
        SCode.ATTR(
          flowPrefix = flow1,
          streamPrefix = stream1,
          variability = var,
          direction = dir),
        SCode.PREFIXES(
          finalPrefix = fp,
          innerOuter = io1), _)
      equation
        vdir = propagateDirection(vdir, dir, cr, inInfo);
        vk = propagateVariability(vk, var);
        var_attrs = propagateFinal(var_attrs, fp);
        io2 = propagateInnerOuter(io2, io1);
        flow2 = propagateFlow(flow2, flow1, cr, inInfo);
        stream2 = propagateStream(stream2, stream1, cr, inInfo);
      then
        DAE.VAR(cr, vk, vdir, vvis, ty, binding, dims, flow2, stream2, source,
          var_attrs, cmt, io2);

    // Structured component.
    case (DAE.COMP(ident = ident, dAElist = el, source = source, comment = cmt), _, _, _)
      equation
        el = Util.listMap3(el, propagateAllAttributes, inAttributes, inPrefixes, inInfo);
      then
        DAE.COMP(ident, el, source, cmt);

    // Everything else.
    else inElement;

  end match;
end propagateAllAttributes;
  
protected function propagateDirection
  "Helper function to propagateAttributes. Propagates the input/output
  attribute to variables of a structured component."
  input DAE.VarDirection inVarDirection;
  input Absyn.Direction inDirection;
  input DAE.ComponentRef inCref;
  input Absyn.Info inInfo;
  output DAE.VarDirection outVarDirection;
algorithm
  outVarDirection := match(inVarDirection, inDirection, inCref, inInfo)
    local
      String s1, s2, s3;

    // Component that is bidirectional does not change direction on subcomponents.
    case (_, Absyn.BIDIR(), _, _) then inVarDirection;

    // Bidirectional variables are changed to input or output if component has
    // such prefix.
    case (DAE.BIDIR(), _, _, _) then absynDirToDaeDir(inDirection);

    // Error when component declared as input or output if the variable already
    // has such a prefix.
    else
      equation
        s1 = Dump.directionSymbol(inDirection);
        s2 = ComponentReference.printComponentRefStr(inCref);
        s3 = DAEDump.dumpDirectionStr(inVarDirection);
        Error.addSourceMessage(Error.COMPONENT_INPUT_OUTPUT_MISMATCH, 
          {s1, s2, s3}, inInfo);
      then
        fail();
  end match;
end propagateDirection;

protected function propagateVariability
  "Helper function to propagateAttributes. Propagates the variability (parameter
  or constant) attribute to variables of a structured component."
  input DAE.VarKind inVarKind;
  input SCode.Variability inVariability;
  output DAE.VarKind outVarKind;
algorithm
  outVarKind := match(inVarKind, inVariability)
    // Component that is VAR does not change variability of subcomponents.
    case (_, SCode.VAR()) then inVarKind;
    // Most restrictive variability is preserved.
    case (DAE.DISCRETE(), _) then inVarKind;
    case (_, SCode.DISCRETE()) then DAE.DISCRETE();
    case (DAE.CONST(), _) then inVarKind;
    case (_, SCode.CONST()) then DAE.CONST();
    case (DAE.PARAM(), _) then inVarKind;
    case (_, SCode.PARAM()) then DAE.PARAM();
    else inVarKind;
  end match;
end propagateVariability;

protected function propagateFinal
  "Helper function to propagateAttributes. Propagates the final attribute to
  variables of a structured component."
  input Option<DAE.VariableAttributes> inVarAttributes;
  input SCode.Final inFinal;
  output Option<DAE.VariableAttributes> outVarAttributes;
algorithm
  outVarAttributes := match(inVarAttributes, inFinal)
    case (_, SCode.FINAL())
      then DAEUtil.setFinalAttr(inVarAttributes, SCode.finalBool(inFinal));
    else inVarAttributes;
  end match;
end propagateFinal;

protected function propagateInnerOuter
  "Helper function to propagateAttributes. Propagates the inner/outer attribute
  to variables of a structured component."
  input Absyn.InnerOuter inVarInnerOuter;
  input Absyn.InnerOuter inInnerOuter;
  output Absyn.InnerOuter outVarInnerOuter;
algorithm
  outVarInnerOuter := match(inVarInnerOuter, inInnerOuter)
    // Component that is unspecified does not change inner/outer on subcomponents.
    case (_, Absyn.NOT_INNER_OUTER()) then inVarInnerOuter;
    // Unspecified variables are changed to the same inner/outer prefix as the
    // component.
    case (Absyn.NOT_INNER_OUTER(), _) then inInnerOuter;
    // If variable already have inner/outer, keep it.
    else inVarInnerOuter;
  end match;
end propagateInnerOuter;

protected function propagateFlow
  "Helper function to propagateAttributes. Propagates the flow attribute to
  variables of a structured component."
  input DAE.Flow inVarFlow;
  input SCode.Flow inFlow;
  input DAE.ComponentRef inCref;
  input Absyn.Info inInfo;
  output DAE.Flow outVarFlow;
algorithm
  outVarFlow := match(inVarFlow, inFlow, inCref, inInfo)
    local
      String s1, s2, s3;

    // The only valid propagation is from a non-flow connector variable to a flow.
    case (DAE.NON_FLOW(), SCode.FLOW(), _, _) then DAE.FLOW();
    case (DAE.NON_CONNECTOR(), SCode.FLOW(), _, _) then DAE.FLOW();

    // Error if the component is declared as flow but the subcomponent already
    // is flow.
    case (DAE.FLOW(), SCode.FLOW(), _, _)
      equation
        s1 = SCodeDump.flowStr(inFlow);
        s2 = ComponentReference.printComponentRefStr(inCref);
        s3 = DAEDump.dumpFlow(inVarFlow);
        Error.addSourceMessage(Error.INVALID_TYPE_PREFIX,
          {s1, s2, s3}, inInfo);
      then
        fail();

    else inVarFlow;
  end match;
end propagateFlow;

protected function propagateStream
  "Helper function to propagateAttributes. Propagates the stream attribute to
  variables of a structured component."
  input DAE.Stream inVarStream;
  input SCode.Stream inStream;
  input DAE.ComponentRef inCref;
  input Absyn.Info inInfo;
  output DAE.Stream outVarStream;
algorithm
  outVarStream := match(inVarStream, inStream, inCref, inInfo)
    case (DAE.NON_STREAM(), SCode.STREAM(), _, _) then DAE.STREAM();
    case (DAE.NON_STREAM_CONNECTOR(), SCode.STREAM(), _, _) then DAE.STREAM();
    else inVarStream;
  end match;
end propagateStream;        

protected function absynDirToDaeDir
"function: absynDirToDaeDir
  Translates Absyn.Direction to DAE.VarDirection.
  Needed so that input, output is transferred to DAE."
  input Absyn.Direction inDirection;
  output DAE.VarDirection outVarDirection;
algorithm
  outVarDirection := match (inDirection)
    case Absyn.INPUT() then DAE.INPUT();
    case Absyn.OUTPUT() then DAE.OUTPUT();
    case Absyn.BIDIR() then DAE.BIDIR();
  end match;
end absynDirToDaeDir;

protected function instArray
"function: instArray
  When an array is instantiated by instVar, this function is used
  to go through all the array elements and instantiate each array
  element separately."
  input Env.Cache cache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input ClassInf.State inState;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input Ident inIdent;
  input tuple<SCode.Element, SCode.Attributes> inTplSCodeClassSCodeAttributes;
  input SCode.Prefixes inPrefixes;
  input Integer inInteger;
  input DAE.Dimension inDimension;
  input list<DAE.Dimension> inDimensionLst;
  input list<DAE.Subscript> inIntegerLst;
  input InstDims inInstDims;
  input Boolean inBoolean;
  input Option<SCode.Comment> inAbsynCommentOption;
  input Absyn.Info info;
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output DAE.Type outType;
  output ConnectionGraph.ConnectionGraph outGraph;
algorithm
  (outCache,outEnv,outIH,outStore,outDae,outSets,outType,outGraph) :=
  matchcontinue (cache,inEnv,inIH,store,inState,inMod,inPrefix,inSets,inIdent,inTplSCodeClassSCodeAttributes,inPrefixes,inInteger,inDimension,inDimensionLst,inIntegerLst,inInstDims,inBoolean,inAbsynCommentOption,info,inGraph)
    local
      DAE.Exp e,lhs,rhs;
      DAE.Properties p;
      list<Env.Frame> env_1,env,compenv;
      Connect.Sets csets,csets_1,csets_2;
      DAE.Type ty;
      ClassInf.State st,ci_state;
      DAE.ComponentRef cr;
      DAE.ExpType ty_1;
      DAE.Mod mod,mod_1;
      Prefix.Prefix pre;
      String n, str1, str2, str3, str4;
      SCode.Element cl;
      SCode.Attributes attr;
      Integer i,stop,i_1;
      list<DAE.Dimension> dims;
      list<DAE.Subscript> idxs;
      InstDims inst_dims;
      Boolean impl;
      Option<SCode.Comment> comment;
      DAE.DAElist dae,dae1,dae2,daeLst;
      SCode.Visibility vis;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      DAE.ElementSource source "the origin of the element";
      DAE.Subscript s;
      SCode.Element clBase;
      Absyn.Path path;
      SCode.Attributes absynAttr;
      SCode.Mod scodeMod;
      DAE.Mod mod2, mod3;
      String lit;
      list<String> l;
      Integer enum_size;
      Absyn.Path enum_type, enum_lit;
      SCode.Prefixes pf;

    /* component environment If is a function var. */
    case (cache,env,ih,store,(ci_state as ClassInf.FUNCTION(path = _)),mod,pre,csets,n,(cl,attr),pf,i,DAE.DIM_UNKNOWN(),dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        SOME(DAE.TYPED(e,_,p,_)) = Mod.modEquation(mod);
        (cache,env_1,ih,store,dae1,csets,ty,st,_,graph) =
          instClass(cache,env,ih,store, mod, pre, csets, cl, inst_dims, true, INNER_CALL(),graph) "Which has an expression binding";
        ty_1 = Types.elabType(ty);
        (cache,cr) = PrefixUtil.prefixCref(cache,env,ih,pre,ComponentReference.makeCrefIdent(n,ty_1,{})) "check their types";
        (rhs,_) = Types.matchProp(e,p,DAE.PROP(ty,DAE.C_VAR()),true);
        
        // set the source of this element
        source = DAEUtil.createElementSource(info, Env.getEnvPath(env), PrefixUtil.prefixToCrefOpt(pre), NONE(), NONE());
        
        lhs = Expression.makeCrefExp(cr,ty_1);
        
        dae = InstSection.makeDaeEquation(lhs, rhs, source, SCode.NON_INITIAL());
        // dae = DAEUtil.joinDaes(dae,DAEUtil.extractFunctions(dae1));
      then
        (cache,env_1,ih,store,dae,csets,ty,graph);

    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl,attr),pf,i,_,dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        false = Expression.dimensionKnown(inDimension);
        s = DAE.INDEX(DAE.ICONST(i));
        mod = Mod.lookupIdxModification(mod, i);
        (cache,compenv,ih,store,daeLst,csets,ty,graph) =
          instVar2(cache, env, ih, store, ci_state, mod, pre, csets, n, cl, attr, pf, dims, (s :: idxs), inst_dims, impl, comment,info,graph);
      then
        (cache,compenv,ih,store,daeLst,csets,ty,graph);

    /* Special case when instantiating Real[0]. We need to know the type */
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl,attr),pf,i,DAE.DIM_INTEGER(0),dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        ErrorExt.setCheckpoint("instArray Real[0]");
        s = DAE.INDEX(DAE.ICONST(0));
        (cache,compenv,ih,store,daeLst,csets,ty,graph) =
           instVar2(cache,env,ih,store, ci_state, DAE.NOMOD(), pre, csets, n, cl, attr,pf, dims, (s :: idxs), inst_dims, impl, comment,info,graph);
        ErrorExt.rollBack("instArray Real[0]");
      then
        (cache,compenv,ih,store,DAEUtil.emptyDae,csets,ty,graph);

    /* Keep the errors if we somehow fail */
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl,attr),pf,i,DAE.DIM_INTEGER(0),dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        ErrorExt.delCheckpoint("instArray Real[0]");
      then
        fail();

    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl,attr),pf,i,DAE.DIM_INTEGER(integer = stop),dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        (i > stop) = true;
      then
        (cache,env,ih,store,DAEUtil.emptyDae,csets,(DAE.T_NOTYPE(),NONE()),graph);

    /* adrpo: if a class is derived WITH AN ARRAY DIMENSION we should instVar2 the derived from type not the actual type!!! */
    case (cache,env,ih,store,ci_state,mod,pre,csets,n,
          (cl as SCode.CLASS(classDef=SCode.DERIVED(typeSpec=Absyn.TPATH(path,SOME(_)),
                                                    modifications=scodeMod,attributes=absynAttr)),
                                                    attr),
          pf,i,DAE.DIM_INTEGER(integer = stop),dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        (_,clBase,_) = Lookup.lookupClass(cache, env, path, true);
        /* adrpo: TODO: merge also the attributes, i.e.:
           type A = input discrete flow Integer[3];
           A x; <-- input discrete flow IS NOT propagated even if it should. FIXME!
         */
        //SOME(attr3) = SCode.mergeAttributes(attr,SOME(absynAttr));
        (_,mod2) = Mod.elabMod(cache, env, ih, pre, scodeMod, impl,info);
        mod3 = Mod.merge(mod, mod2, env, pre);
        mod_1 = Mod.lookupIdxModification(mod3, i);
        s = DAE.INDEX(DAE.ICONST(i));
        (cache,env_1,ih,store,dae1,csets_1,ty,graph) =
           instVar2(cache,env,ih, store,ci_state, mod_1, pre, csets, n, clBase, attr, pf,dims, (s :: idxs), {} /* inst_dims */, impl, comment,info,graph);
        i_1 = i + 1;
        (cache,_,ih,store,dae2,csets_2,_,graph) =
          instArray(cache,env,ih,store, ci_state, mod, pre, csets_1, n, (cl,attr), pf, i_1, DAE.DIM_INTEGER(stop), dims, idxs, {} /* inst_dims */, impl, comment,info,graph);
        daeLst = DAEUtil.joinDaeLst({dae1, dae2});
      then
        (cache,env_1,ih,store,daeLst,csets_2,ty,graph);

    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl,attr),pf,i,DAE.DIM_INTEGER(integer = stop),dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        mod_1 = Mod.lookupIdxModification(mod, i);
        s = DAE.INDEX(DAE.ICONST(i));
        (cache,env_1,ih,store,dae1,csets_1,ty,graph) =
           instVar2(cache,env,ih, store,ci_state, mod_1, pre, csets, n, cl, attr, pf,dims, (s :: idxs), inst_dims, impl, comment,info,graph);
        i_1 = i + 1;
        (cache,_,ih,store,dae2,csets_2,_,graph) =
          instArray(cache,env,ih,store, ci_state, mod, pre, csets_1, n, (cl,attr), pf, i_1, DAE.DIM_INTEGER(stop), dims, idxs, inst_dims, impl, comment,info,graph);
        daeLst = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,env_1,ih,store,daeLst,csets_2,ty,graph);

    // Instantiate an array whose dimension is determined by an enumeration.
    case (cache, env, ih, store, ci_state, mod, pre, csets, n, (cl, attr), pf,
        i, DAE.DIM_ENUM(enumTypeName = enum_type, literals = lit :: l), dims, 
        idxs, inst_dims, impl, comment, info, graph)
      equation
        mod_1 = Mod.lookupIdxModification(mod, i);
        enum_lit = Absyn.joinPaths(enum_type, Absyn.IDENT(lit));
        s = DAE.INDEX(DAE.ENUM_LITERAL(enum_lit, i));
        enum_size = listLength(l);
        (cache, env_1, ih, store, dae1, csets_1, ty, graph) =
          instVar2(cache, env, ih, store, ci_state, mod_1, pre, csets, n, cl,
          attr, pf, dims, (s :: idxs), inst_dims, impl, comment, info, graph);
        i_1 = i + 1;
        (cache, _, ih, store, dae2, csets_2, _, graph) =
          instArray(cache, env, ih, store, ci_state, mod, pre, csets_1, n, (cl,
          attr), pf, i_1, DAE.DIM_ENUM(enum_type, l, enum_size), dims, idxs, 
          inst_dims, impl, comment, info, graph);
        daeLst = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache, env_1, ih, store, daeLst, csets_2, ty, graph);

    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl,attr),pf,i,
      DAE.DIM_ENUM(literals = {}),dims,idxs,inst_dims,impl,comment,
      info,graph)
      then
        (cache,env,ih,store,DAEUtil.emptyDae,csets,(DAE.T_NOTYPE(),NONE()),graph);

    case (cache,env,ih,store,ci_state,mod,pre,csets,n,(cl,attr),pf,i,_,dims,idxs,inst_dims,impl,comment,info,graph)
      equation
        failure(_ = Mod.lookupIdxModification(mod, i));
        str1 = PrefixUtil.printPrefixStrIgnoreNoPre(PrefixUtil.prefixAdd(n, {}, pre, SCode.VAR(), ci_state));
        str2 = "[" +& Util.stringDelimitList(Util.listMap(idxs, ExpressionDump.printSubscriptStr), ", ") +& "]";
        str3 = Mod.prettyPrintMod(mod, 1);
        str4 = PrefixUtil.printPrefixStrIgnoreNoPre(pre) +& "(" +& n +& str2 +& "=" +& str3 +& ")";
        str2 = str1 +& str2;
        Error.addSourceMessage(Error.MODIFICATION_INDEX_NOT_FOUND, {str1,str4,str2,str3}, info);
      then
        fail();

    case (_,_,ih,_,_,_,_,_,n,(_,_),_,_,_,_,_,_,_,_,_,_)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprintln("failtrace", "- Inst.instArray failed: " +& n);
      then
        fail();
  end matchcontinue;
end instArray;

protected function attrIsParam
"function: attrIsParam
  Returns true if attributes contain PARAM"
  input SCode.Attributes inAttributes;
  output Boolean outBoolean;
algorithm
  outBoolean := matchcontinue (inAttributes)
    case SCode.ATTR(variability = SCode.PARAM()) then true;
    case _ then false;
  end matchcontinue;
end attrIsParam;

public function elabComponentArraydimFromEnv
"function elabComponentArraydimFromEnv
  author: PA
  Lookup uninstantiated component in env, elaborate its modifiers to
  find arraydimensions and return as DAE.Dimension list.
  Used when components have submodifiers (on e.g. attributes) using
  size to find dimensions of component."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.ComponentRef inComponentRef;
  input Absyn.Info info;
  output Env.Cache outCache;
  output list<DAE.Dimension> outDimensionLst;
algorithm
  (outCache,outDimensionLst) := matchcontinue (inCache,inEnv,inComponentRef,info)
    local
      String id;
      list<Absyn.Subscript> ad;
      SCode.Mod m,m_1;
      DAE.Mod cmod,cmod_1,m_2,mod_2;
      DAE.EqMod eq;
      list<DAE.Dimension> dims;
      list<Env.Frame> env;
      DAE.ComponentRef cref;
      Env.Cache cache;
      list<DAE.Subscript> subs;

    case (cache,env,cref as DAE.CREF_IDENT(ident = id),info)
      equation
        (cache,_,SOME((SCode.COMPONENT(modifications = m),cmod)),_)
          = Lookup.lookupIdent(cache,env, id);
        cmod_1 = Types.stripSubmod(cmod);
        m_1 = SCode.stripSubmod(m);
        (cache,m_2) = Mod.elabMod(cache, env, InnerOuter.emptyInstHierarchy, Prefix.NOPRE(), m_1, false,info);
        mod_2 = Mod.merge(cmod_1, m_2, env, Prefix.NOPRE());
        SOME(eq) = Mod.modEquation(mod_2);
        (cache,dims) = elabComponentArraydimFromEnv2(cache,eq, env);
      then
        (cache,dims);
    case (cache,env,cref as DAE.CREF_IDENT(ident = id),info)
      equation
        (cache,_,SOME((SCode.COMPONENT(attributes = SCode.ATTR(arrayDims = ad)),_)),_)
          = Lookup.lookupIdent(cache,env, id);
        (cache, subs, _) = Static.elabSubscripts(cache, env, ad, true, Prefix.NOPRE(), info);
        dims = Expression.subscriptDimensions(subs);
      then
        (cache,dims);
    case (_, _, cref,_)
      equation
        Debug.fprintln("failtrace", "- Inst.elabComponentArraydimFromEnv failed: " 
          +& ComponentReference.printComponentRefStr(cref));
      then
        fail();
  end matchcontinue;
end elabComponentArraydimFromEnv;

protected function elabComponentArraydimFromEnv2
"function: elabComponentArraydimFromEnv2
  author: PA
  Helper function to elabComponentArraydimFromEnv.
  This function is similar to elabArraydim, but it will only
  investigate binding (DAE.EqMod) and not the component declaration."
  input Env.Cache inCache;
  input DAE.EqMod inEqMod;
  input Env.Env inEnv;
  output Env.Cache outCache;
  output list<DAE.Dimension> outDimensionLst;
algorithm
  (outCache,outDimensionLst) := match (inCache,inEqMod,inEnv)
    local
      list<Integer> lst;
      list<DAE.Dimension> lst_1;
      DAE.Exp e;
      DAE.Type t;
      list<Env.Frame> env;
      Env.Cache cache;
    case (cache,DAE.TYPED(modifierAsExp = e,properties = DAE.PROP(type_ = t)),env)
      equation
        lst = Types.getDimensionSizes(t);
        lst_1 = Util.listMap(lst, Expression.intDimension);
      then
        (cache,lst_1);
  end match;
end elabComponentArraydimFromEnv2;

protected function elabArraydimOpt
"function: elabArraydimOpt
  Same functionality as elabArraydim, but takes an optional arraydim.
  In case of NONE(), empty DAE.Dimension list is returned."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Absyn.ComponentRef inComponentRef;
  input Absyn.Path path "Class of declaration";
  input Option<Absyn.ArrayDim> inAbsynArrayDimOption;
  input Option<DAE.EqMod> inTypesEqModOption;
  input Boolean inBoolean;
  input Option<Interactive.InteractiveSymbolTable> inInteractiveInteractiveSymbolTableOption;
  input Boolean performVectorization;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output list<DAE.Dimension> outDimensionLst;
algorithm
  (outCache,outDimensionLst) :=
  match (inCache,inEnv,inComponentRef,path,inAbsynArrayDimOption,inTypesEqModOption,inBoolean,inInteractiveInteractiveSymbolTableOption,performVectorization,inPrefix,info,inInstDims)
    local
      list<DAE.Dimension> res;
      list<Env.Frame> env;
      Absyn.ComponentRef owncref;
      list<Absyn.Subscript> ad;
      Option<DAE.EqMod> eq;
      Boolean impl;
      Option<Interactive.InteractiveSymbolTable> st;
      Env.Cache cache;
      Boolean doVect;
      Prefix.Prefix pre;
      InstDims inst_dims;
    case (cache,env,owncref,path,SOME(ad),eq,impl,st,doVect,pre,info,inst_dims)
      equation
        (cache,res) = elabArraydim(cache,env, owncref, path,ad, eq, impl, st,doVect, false,pre,info,inst_dims);
      then
        (cache,res);
    case (cache,env,owncref,path,NONE(),eq,impl,st,doVect,_,_,_) then (cache,{});
  end match;
end elabArraydimOpt;

protected function elabArraydim
"function: elabArraydim
  This functions examines both an `Absyn.ArrayDim\' and an `DAE.EqMod
  option\' argument to find out the dimensions af a component.  If
  no equation modifications is given, only the declared dimension is
  used.

  When the size of a dimension in the type is undefined, the
  corresponding size in the type of the modification is used.

  All this is accomplished by examining the two arguments separately
  and then using `complete_arraydime\' or `compatible_arraydim\' to
  check that that the dimension sizes are compatible and complete."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Absyn.ComponentRef inComponentRef;
  input Absyn.Path path "Class of declaration";
  input Absyn.ArrayDim inArrayDim;
  input Option<DAE.EqMod> inTypesEqModOption;
  input Boolean inBoolean;
  input Option<Interactive.InteractiveSymbolTable> inInteractiveInteractiveSymbolTableOption;
  input Boolean performVectorization;
  input Boolean isFunctionInput;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output list<DAE.Dimension> outDimensionLst;
algorithm
  (outCache,outDimensionLst) :=
  matchcontinue
    (inCache,inEnv,inComponentRef,path,inArrayDim,inTypesEqModOption,inBoolean,inInteractiveInteractiveSymbolTableOption,performVectorization,isFunctionInput,inPrefix,info,inInstDims)
    local
      list<DAE.Dimension> dim,dim1,dim2;
      list<DAE.Dimension> dim3;
      list<Env.Frame> env;
      Absyn.ComponentRef cref;
      list<Absyn.Subscript> ad;
      Boolean impl;
      Option<Interactive.InteractiveSymbolTable> st;
      DAE.Exp e,e_1;
      DAE.Type t;
      String e_str,t_str,dim_str;
      Env.Cache cache;
      Boolean doVect;
      DAE.Properties prop;
      Prefix.Prefix pre;
      Absyn.Exp aexp;
      Option<DAE.EqMod> eq;
      InstDims inst_dims;

    // The size of function input arguments should not be set here, since they
    // may vary depending on the inputs. So we ignore any modifications on input
    // variables here.
    case (cache, env, cref, path, ad, _, impl, st, doVect, true,pre,info,_)
      equation
        (cache, dim) = Static.elabArrayDims(cache, env, cref, ad, true, st, doVect,pre,info);
      then
        (cache, dim);
        
    case (cache,env,cref,path,ad,NONE(),impl,st,doVect, _,pre,info,_) /* impl */
      equation
        (cache,dim) = Static.elabArrayDims(cache,env, cref, ad, impl, st,doVect,pre,info);
      then
        (cache,dim);
    case (cache,env,cref,path,ad,SOME(DAE.TYPED(e,_,prop,_)),impl,st,doVect, _ ,pre,info,inst_dims) /* Untyped expressions must be elaborated. */
      equation
        t = Types.getPropType(prop);
        (cache,dim1) = Static.elabArrayDims(cache,env, cref, ad, impl, st,doVect,pre,info);
        dim2 = elabArraydimType(t, ad, e, path, pre, cref, info,inst_dims);
        //Debug.traceln("TYPED: " +& ExpressionDump.printExpStr(e) +& " s: " +& Env.printEnvPathStr(env));
        dim3 = Util.listThreadMap(dim1, dim2, compatibleArraydim);
      then
        (cache,dim3);
    case (cache,env,cref,path,ad,SOME(DAE.UNTYPED(aexp)),impl,st,doVect, _,pre,info,inst_dims)
      equation
        (cache,e_1,prop,_) = Static.elabExp(cache,env, aexp, impl, st,doVect,pre,info);
        (cache, e_1, prop) = Ceval.cevalIfConstant(cache, env, e_1, prop, impl);
        t = Types.getPropType(prop);
        (cache,dim1) = Static.elabArrayDims(cache,env, cref, ad, impl, st,doVect,pre,info);
        dim2 = elabArraydimType(t, ad, e_1, path, pre, cref, info,inst_dims);
        //Debug.traceln("UNTYPED");
        dim3 = Util.listThreadMap(dim1, dim2, compatibleArraydim);
      then
        (cache,dim3);
    case (cache,env,cref,path,ad,SOME(DAE.TYPED(e,_,DAE.PROP(t,_),_)),impl,st,doVect, _,pre,info,inst_dims)
      equation
        // adrpo: do not display error when running checkModel 
        //        TODO! FIXME! check if this doesn't actually get rid of useful error messages
        false = OptManager.getOption("checkModel");
        (cache,dim1) = Static.elabArrayDims(cache,env, cref, ad, impl, st,doVect,pre,info);
        dim2 = elabArraydimType(t, ad, e, path, pre, cref, info,inst_dims);
        failure(dim3 = Util.listThreadMap(dim1, dim2, compatibleArraydim));
        e_str = ExpressionDump.printExpStr(e);
        t_str = Types.unparseType(t);
        dim_str = printDimStr(dim1);
        Error.addSourceMessage(Error.ARRAY_DIMENSION_MISMATCH, {e_str,t_str,dim_str}, info);
      then
        fail();
    // print some failures
    case (_,_,cref,path,ad,eq,_,_,_,_,_,_,_)
      equation
        // only display when the failtrace flag is on
        true = RTOpts.debugFlag("failtrace");
        Debug.trace("- Inst.elabArraydim failed on: \n\tcref:");
        Debug.trace(Absyn.pathString(path) +& " " +& Dump.printComponentRefStr(cref));
        Debug.traceln(Dump.printArraydimStr(ad) +& " = " +& Types.unparseOptionEqMod(eq));
      then
        fail();
  end matchcontinue;
end elabArraydim;

protected function printDimStr
"function: printDimStr
  This function prints array dimensions.
  The code is not included in the report."
  input list<DAE.Dimension> inDimensionLst;
  output String outString;
protected
  list<String> dim_strings;
algorithm
  dim_strings := Util.listMap(inDimensionLst, ExpressionDump.dimensionString);
  outString := Util.stringDelimitList(dim_strings, ",");
end printDimStr;

protected function compatibleArraydim
  "Given two, possibly incomplete, array dimension size specifications, this
  function checks whether they are compatible. Being compatible means that they
  have the same number of dimensions, and for every dimension at least one of
  the lists specifies it's size. If both lists specify a dimension size, they
  have to specify the same size."
  input DAE.Dimension inDimension1;
  input DAE.Dimension inDimension2;
  output DAE.Dimension outDimension;
algorithm
  outDimension := matchcontinue(inDimension1, inDimension2)
    local
      DAE.Dimension x, y;
    case (DAE.DIM_UNKNOWN(), DAE.DIM_UNKNOWN()) then DAE.DIM_UNKNOWN();
    case (x, DAE.DIM_UNKNOWN()) then x;
    case (DAE.DIM_UNKNOWN(), y) then y;
    case (x, DAE.DIM_EXP(exp = _)) then x;
    case (DAE.DIM_EXP(exp = _), y) then y;
    case (x, y)
      equation
        // Convert dimensions given by enumerations to integers, to keep the
        // complexity of compareArraydim down.
        x = enumToIntDimExpTry(x);
        y = enumToIntDimExpTry(y);
        x = compareArraydim(x, y);
      then
        x;
    case (_, _)
      equation
        Debug.fprintln("failtrace", "- Inst.compatibleArraydim failed");
      then
        fail();
  end matchcontinue;
end compatibleArraydim;

protected function compareArraydim
  "Helper function to compatibleArraydim. Checks that two array dimensions are
  compatible."
  input DAE.Dimension inDimension1;
  input DAE.Dimension inDimension2;
  output DAE.Dimension outDimension;
algorithm
  outDimension := matchcontinue(inDimension1, inDimension2)
    local
      Integer xI, yI;
      DAE.Dimension de;
    case (DAE.DIM_INTEGER(integer = xI), DAE.DIM_INTEGER(integer = yI)) 
      equation 
        true = intEq(xI, yI); // equality(xI = yI);
      then 
        inDimension1;
    case (DAE.DIM_UNKNOWN(), de) then de;
    case (de, DAE.DIM_UNKNOWN()) then de;
    /*case (DAE.DIM_INTEGER(integer = xI), DAE.DIM_SUBSCRIPT(subscript = _))
      equation
        de = arraydimCondition(
          DAE.DIM_SUBSCRIPT(DAE.INDEX(DAE.ICONST(xI))), 
          inDimension2);
      then
        de;
    case (DAE.DIM_SUBSCRIPT(subscript = _), DAE.DIM_INTEGER(integer = yI))
      equation
        de = arraydimCondition(
          DAE.DIM_SUBSCRIPT(DAE.INDEX(DAE.ICONST(yI))), 
          inDimension1);
      then
        de;
    case (DAE.DIM_SUBSCRIPT(subscript = _), DAE.DIM_SUBSCRIPT(subscript = _))
      equation
        de = arraydimCondition(inDimension1, inDimension2);
      then
        de;*/
  end matchcontinue;
end compareArraydim;

protected function enumToIntDimExpTry
  "Tries to convert a dimension given by an enumeration to an integer, or
  returns the unchanged dimension if it's not possible."
  input DAE.Dimension enumDimension;
  output DAE.Dimension intDimension;
algorithm
  intDimension := matchcontinue(enumDimension)
    local
      Integer n;
    case (DAE.DIM_ENUM(size = n)) then DAE.DIM_INTEGER(n);
    case _ then enumDimension;
  end matchcontinue;
end enumToIntDimExpTry;

protected function arraydimCondition
"function arraydimCondition
  This function checks that the two arraydim expressions have the same dimension.
  FIXME: no check performed yet, just return first DAE.Dimension."
  input DAE.Dimension inDimension1;
  input DAE.Dimension inDimension2;
  output DAE.Dimension outDimension;
algorithm
  outDimension := matchcontinue (inDimension1,inDimension2)
    local DAE.Dimension de;
    case (de,_) then de;
  end matchcontinue;
end arraydimCondition;

protected function elabArraydimType
"function: elabArraydimType
  Find out the dimension sizes of a type. The second argument is
  used to know how many dimensions should be extracted from the
  type."
  input DAE.Type inType;
  input Absyn.ArrayDim inArrayDim;
  input DAE.Exp exp "Primarily used for error messages";
  input Absyn.Path path "class of declaration, primarily used for error messages";
  input Prefix.Prefix inPrefix;
  input Absyn.ComponentRef componentRef;
  input Absyn.Info info;
  input InstDims inInstDims;
  output list<DAE.Dimension> outDimensionLst;
algorithm
  outDimensionLst := matchcontinue(inType,inArrayDim,exp,path,inPrefix,componentRef,info,inInstDims)
    local
      DAE.Type t;
      list<Absyn.Subscript> ad;
      String tpStr,adStr,expStr,str;
      InstDims id;
      list<DAE.Subscript> flat_id;
    case(t,ad,exp,path,_,_,_,_)
      equation
        true = RTOpts.splitArrays();
        true = (Types.numberOfDimensions(t) >= listLength(ad));
        outDimensionLst = elabArraydimType2(t,ad,{});
      then outDimensionLst;

    case(t,ad,exp,path,_,_,_,id)
      equation
        false = RTOpts.splitArrays();
        flat_id = Util.listFlatten(id);
        true = (Types.numberOfDimensions(t) >= listLength(ad) + listLength(flat_id));
        outDimensionLst = elabArraydimType2(t,ad,flat_id);
      then outDimensionLst;

    case(t,ad,exp,path,inPrefix,componentRef,_,_)
      equation
        adStr = Absyn.pathString(path) +& Dump.printArraydimStr(ad);
        tpStr = Types.unparseType(t);
        expStr = ExpressionDump.printExpStr(exp);
        str = PrefixUtil.printPrefixStrIgnoreNoPre(inPrefix) +& Absyn.printComponentRefStr(componentRef);
        Error.addSourceMessage(Error.MODIFIER_DECLARATION_TYPE_MISMATCH_ERROR,{str,adStr,expStr,tpStr},info);
      then fail();
    end matchcontinue;
end elabArraydimType;

protected function elabArraydimType2
"Help function to elabArraydimType."
  input DAE.Type inType;
  input Absyn.ArrayDim inArrayDim;
  input list<DAE.Subscript> inSubs;
  output list<DAE.Dimension> outDimensionOptionLst;
algorithm
  outDimensionOptionLst := matchcontinue (inType,inArrayDim,inSubs)
    local
      DAE.Dimension d,d1;
      list<DAE.Dimension> l;
      DAE.Type t;
      list<Absyn.Subscript> ad;
      list<DAE.Subscript> subs;
      DAE.Subscript sub;
    case ((DAE.T_ARRAY(arrayDim = d, arrayType = t), _), ad, (sub::subs))
      equation
        d1 = Expression.subscriptDimension(sub);
         _ = compatibleArraydim(d,d1);
        l = elabArraydimType2(t, ad,subs);
      then
        l;
    case ((DAE.T_ARRAY(arrayDim = d, arrayType = t), _), (_ :: ad),{})
      equation
        l = elabArraydimType2(t, ad,{});
      then
        (d :: l);
    case (_,{},{}) then {};
    /* adrpo: handle also complex type!
    case ((DAE.T_COMPLEX(complexTypeOption=SOME(t)),_),ad)
      equation
        l = elabArraydimType2(t, ad);
      then
        l; */
    case (t,(_ :: ad),_) /* PR, for debugging */
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprint("failtrace", "Undefined!");
        Debug.fprint("failtrace", " The type detected: ");
        Debug.fprint("failtrace", Types.printTypeStr(t));
      then
        fail();
  end matchcontinue;
end elabArraydimType2;

public function instClassDecl
"function: instClassDecl
  The class definition is instantiated although no variable is declared with it.
  After instantiating it, it is checked to see if it can be used as a package,
  and if it can, then it is added as a variable under the same name as the class.
  This makes it possible to use a unified lookup mechanism.
  And since packages only can contain constants and class definition, instantiating
  a package does not do anything else."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input SCode.Element inClass;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outEnv,outIH,outDae) := matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inSets,inClass,inInstDims)
    local
      list<Env.Frame> env_1,env_2,env;
      DAE.DAElist dae;
      DAE.Mod mod;
      Prefix.Prefix pre;
      Connect.Sets csets;
      SCode.Element c;
      String n;
      SCode.Restriction restr;
      InstDims inst_dims;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,env,ih,mod,pre,csets,(c as SCode.CLASS(name = n,restriction = restr)),inst_dims)
      equation
        // add the class in the environment 
        env_1 = Env.extendFrameC(env, c);
        // do instantiation of enumerations!
        (cache,env_2,ih,dae) = implicitInstantiation(cache,env_1,ih, DAE.NOMOD(), pre, csets, c, inst_dims);
      then
        (cache,env_2,ih,dae);
    case (cache,env,ih,_,_,_,_,_)
      equation
        Debug.fprint("failtrace", "- Inst.instClassDecl failed\n");
      then
        fail();
  end matchcontinue;
end instClassDecl;

public function implicitInstantiation
"function implicitInstantiation
  This function adds types to the environment.
  If a class definition is a function or a package or an enumeration ,
  it is implicitly instantiated and added as a type binding under the
  same name as the class name."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input SCode.Element inClass;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outEnv,outIH,outDae) := matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inSets,inClass,inInstDims)
    local
      Connect.Sets csets;
      list<Env.Frame> env,env_2;
      DAE.Mod mod;
      Prefix.Prefix pre;
      SCode.Element c,enumclass;
      String n;
      InstDims inst_dims;
      list<SCode.Enum> l;
      Env.Cache cache;
      InstanceHierarchy ih;
      Option<SCode.Comment> cmt;
      Absyn.Info info;

     /* enumerations */
     case (cache,env,ih,mod,pre,csets,
           (c as SCode.CLASS(name = n,restriction = SCode.R_TYPE(),
                             classDef = SCode.ENUMERATION(enumLst=l, comment=cmt),info = info)),inst_dims)
      equation
        enumclass = instEnumeration(n, l, cmt, info);
        env_2 = Env.extendFrameC(env, enumclass);
      then
        (cache,env_2,ih,DAEUtil.emptyDae);

    /* .. the rest will fall trough */
    case (cache,env,ih,mod,pre,csets,c,_) then (cache,env,ih,DAEUtil.emptyDae);
  end matchcontinue;
end implicitInstantiation;

public function makeFullyQualified
"function: makeFullyQualified
  author: PA
  Transforms a class name to its fully qualified name by investigating the environment.
  For instance, the model Resistor in Modelica.Electrical.Analog.Basic will given the
  correct environment have the fully qualified name: Modelica.Electrical.Analog.Basic.Resistor"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Absyn.Path inPath;
  output Env.Cache outCache;
  output Absyn.Path outPath;
algorithm
  (outCache,outPath) := matchcontinue (inCache,inEnv,inPath)
    local
      list<Env.Frame> env,env_1;
      Absyn.Path path,path_2,path3;
      String s;
      Env.Cache cache;
      SCode.Element cl;
      DAE.ComponentRef crPath;
      Env.Frame f;
      Env.Env fs;
      String name;

    // Special cases: assert and reinit can not be handled by builtin.mo, since they do not have return type 
    case(cache,env,path as Absyn.IDENT("assert")) then (cache,path);
    case(cache,env,path as Absyn.IDENT("reinit")) then (cache,path);

    // Other functions that can not be represented in env due to e.g. applicable to any record 
    case(cache,env,path as Absyn.IDENT("smooth")) then (cache,path);

    // MetaModelica extensions
    case (cache,_,path as Absyn.IDENT("list"))        equation true = RTOpts.acceptMetaModelicaGrammar(); then (cache,path);
    case (cache,_,path as Absyn.IDENT("Option"))      equation true = RTOpts.acceptMetaModelicaGrammar(); then (cache,path);
    case (cache,_,path as Absyn.IDENT("tuple"))       equation true = RTOpts.acceptMetaModelicaGrammar(); then (cache,path);
    case (cache,_,path as Absyn.IDENT("polymorphic")) equation true = RTOpts.acceptMetaModelicaGrammar(); then (cache,path);
    case (cache,_,path as Absyn.IDENT("array"))       equation true = RTOpts.acceptMetaModelicaGrammar(); then (cache,path);
    // -------------------------    
                     
    // To make a class fully qualified, the class path is looked up in the environment.
    // The FQ path consist of the simple class name appended to the environment path of the looked up class. 
    case (cache,env,path)
      equation 
        (cache,cl,env_1) = Lookup.lookupClass(cache, env, path, false);
        path_2 = makeFullyQualified2(env_1,SCode.className(cl));
      then
        (cache,Absyn.FULLYQUALIFIED(path_2));
    
    // Needed to make external objects fully-qualified
    case (cache,env as (Env.FRAME(optName=SOME(name))::_),Absyn.IDENT(s)) 
      equation 
        true = name ==& s;
        SOME(path_2) = Env.getEnvPath(env);
      then
        (cache,Absyn.FULLYQUALIFIED(path_2));

    // A type can exist without a class (i.e. builtin functions)  
    case (cache,env,Absyn.IDENT(s)) 
      equation 
         (cache,_,env_1) = Lookup.lookupType(cache,env, Absyn.IDENT(s), NONE());
         path_2 = makeFullyQualified2(env_1,s);
      then
        (cache,Absyn.FULLYQUALIFIED(path_2));

     // A package constant, first try to look it up local(top frame)
    case (cache,(f::fs) ,path) 
      equation 
        crPath = ComponentReference.pathToCref(path);
        (cache,_,_,_,_,_,env,_,name) = Lookup.lookupVarInternal(cache, {f}, crPath, Lookup.SEARCH_ALSO_BUILTIN());
        path3 = makeFullyQualified2(env,name);
      then
        (cache,Absyn.FULLYQUALIFIED(path3));

    // TODO! FIXME! what do we do here??!!
    case (cache,env,path)
      equation 
          crPath = ComponentReference.pathToCref(path);
         (cache,env,_,_,_,_,_,_,name) = Lookup.lookupVarInPackages(cache, env, crPath, {}, Util.makeStatefulBoolean(false));
          path3 = makeFullyQualified2(env,name);
      then
        (cache,Absyn.FULLYQUALIFIED(path3));
    
    // If it fails, leave name unchanged.
    case (cache,env,path) 
      equation
        // print(Absyn.pathString(path));print(" failed to make FQ in env:");
        // print("\n");
        // print(Env.printEnvPathStr(env));
        // print("\n");
        // print(Env.printEnvStr(env));
      then 
        (cache,path);
  end matchcontinue;
end makeFullyQualified;

public function implicitFunctionInstantiation
"function: implicitFunctionInstantiation
  This function instantiates a function, which is performed *implicitly*
  since the variables of a function should not be instantiated as for an
  ordinary class."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input SCode.Element inClass;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outCache,outEnv,outIH):= match (inCache,inEnv,inIH,inMod,inPrefix,inSets,inClass,inInstDims)
    local
      Connect.Sets csets;
      DAE.Type ty1;
      list<Env.Frame> env,cenv;
      Absyn.Path fpath;
      DAE.Mod mod;
      Prefix.Prefix pre;
      SCode.Element c;
      String n;
      InstDims inst_dims;
      Env.Cache cache;
      InstanceHierarchy ih;
      DAE.ElementSource source "the origin of the element";
      list<DAE.Function> funs;
      DAE.Function fun;
      SCode.Restriction r;
      
    case (cache,env,ih,mod,pre,csets,(c as SCode.CLASS(name = n,restriction = SCode.R_RECORD())),inst_dims)
      equation
        (cache,c,cenv) = Lookup.lookupRecordConstructorClass(cache,env,Absyn.IDENT(n));
        (cache,env,ih,{DAE.FUNCTION(fpath,_,ty1,false,_,source,_)}) = implicitFunctionInstantiation2(cache,cenv,ih,mod,pre,csets,c,inst_dims);
        fun = DAE.RECORD_CONSTRUCTOR(fpath,ty1,source);
        cache = Env.addDaeFunction(cache, {fun});
      then (cache,env,ih);

    case (cache,env,ih,mod,pre,csets,(c as SCode.CLASS(name = n,restriction = r)),inst_dims)
      equation
        failure(SCode.R_RECORD() = r);
        true = MetaUtil.strictRMLCheck(RTOpts.debugFlag("rml"),c);
        (cache,env,ih,funs) = implicitFunctionInstantiation2(cache,env,ih,mod,pre,csets,c,inst_dims);
        cache = Env.addDaeFunction(cache, funs);
      then (cache,env,ih);

    // handle failure
    case (_,env,_,_,_,_,SCode.CLASS(name=n),_)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.implicitFunctionInstantiation failed " +& n);
        Debug.traceln("  Scope: " +& Env.printEnvPathStr(env));
      then fail();
  end match;
end implicitFunctionInstantiation;

protected function implicitFunctionInstantiation2
"function: implicitFunctionInstantiation2
  This function instantiates a function, which is performed *implicitly*
  since the variables of a function should not be instantiated as for an
  ordinary class."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input SCode.Element inClass;
  input InstDims inInstDims;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output list<DAE.Function> funcs;
algorithm
  (outCache,outEnv,outIH,funcs):= matchcontinue (inCache,inEnv,inIH,inMod,inPrefix,inSets,inClass,inInstDims)
    local
      Connect.Sets csets_1,csets;
      DAE.Type ty,ty1;
      ClassInf.State st;
      list<Env.Frame> env_1,env,tempenv,cenv;
      Absyn.Path fpath;
      DAE.Mod mod;
      Prefix.Prefix pre;
      SCode.Element c;
      String n;
      InstDims inst_dims;
      SCode.Visibility vis;
      SCode.Partial partialPrefix;
      SCode.Encapsulated encapsulatedPrefix;
      DAE.ExternalDecl extdecl;
      SCode.Restriction restr;
      SCode.ClassDef parts;
      list<SCode.Element> els;
      list<Absyn.Path> funcnames;
      Env.Cache cache;
      InstanceHierarchy ih;
      DAE.ElementSource source "the origin of the element";
      list<DAE.Element> daeElts;
      list<DAE.Function> resfns;
      list<DAE.FunctionDefinition> derFuncs;
      Absyn.Info info;
      DAE.InlineType inlineType;
      SCode.ClassDef cd;
      Boolean partialPrefixBool;
      Option<SCode.Comment> cmt;
    
    /* normal functions */
    case (cache,env,ih,mod,pre,csets,(c as SCode.CLASS(classDef=cd,partialPrefix = partialPrefix, name = n,restriction = SCode.R_FUNCTION(),info = info)),inst_dims)
      equation
        inlineType = isInlineFunc2(c);
        (cache,cenv,ih,_,DAE.DAE(daeElts),csets_1,ty,st,_,_) =
          instClass(cache, env, ih, UnitAbsynBuilder.emptyInstStore(), mod, pre, csets, c, inst_dims, true, INNER_CALL(), ConnectionGraph.EMPTY);
        Util.listMap01(daeElts,info,checkFunctionElement);
        env_1 = Env.extendFrameC(env,c);
        (cache,fpath) = makeFullyQualified(cache, env_1, Absyn.IDENT(n));
        derFuncs = getDeriveAnnotation(cd,fpath,cache,cenv,ih,pre,info);

        (cache) = instantiateDerivativeFuncs(cache,env,ih,derFuncs,fpath);

        ty1 = setFullyQualifiedTypename(ty,fpath);

        env_1 = Env.extendFrameT(env_1, n, ty1);
        // set the source of this element
        source = DAEUtil.createElementSource(info, Env.getEnvPath(env), PrefixUtil.prefixToCrefOpt(pre), NONE(), NONE());
        partialPrefixBool = SCode.partialBool(partialPrefix);
        cmt = extractClassDefComment(cache, env, cd);
      then
        (cache,env_1,ih,{DAE.FUNCTION(fpath,DAE.FUNCTION_DEF(daeElts)::derFuncs,ty1,partialPrefixBool,inlineType,source,cmt)});

    /* External functions should also have their type in env, but no dae. */
    case (cache,env,ih,mod,pre,csets,(c as SCode.CLASS(partialPrefix=partialPrefix,name = n,restriction = (restr as SCode.R_EXT_FUNCTION()),
        classDef = cd as (parts as SCode.PARTS(elementLst = els)), info=info, encapsulatedPrefix = encapsulatedPrefix)),inst_dims)
      equation
        (cache,cenv,ih,_,DAE.DAE(daeElts),csets_1,ty,st,_,_) =
          instClass(cache,env,ih, UnitAbsynBuilder.emptyInstStore(),mod, pre,
            csets, c, inst_dims, true, INNER_CALL(), ConnectionGraph.EMPTY);
        //env_11 = Env.extendFrameC(cenv,c);
        // Only created to be able to get FQ path.
        (cache,fpath) = makeFullyQualified(cache,cenv, Absyn.IDENT(n));

        derFuncs = getDeriveAnnotation(parts,fpath,cache,env,ih,pre,info);

        (cache) = instantiateDerivativeFuncs(cache,env,ih,derFuncs,fpath);

        ty1 = setFullyQualifiedTypename(ty,fpath);
        env_1 = Env.extendFrameT(cenv, n, ty1);
        vis = SCode.PUBLIC();
        (cache,tempenv,ih,_,_,_,_,_,_,_,_,_) =
          instClassdef(cache, env_1, ih, UnitAbsyn.noStore, mod, pre, csets_1,
              ClassInf.FUNCTION(fpath), n,parts, restr, vis, partialPrefix, encapsulatedPrefix, inst_dims, true, INNER_CALL(), ConnectionGraph.EMPTY,NONE(),info) "how to get this? impl" ;
        (cache,ih,extdecl) = instExtDecl(cache, tempenv,ih, n, parts, true, pre,info) "impl" ;

        // set the source of this element
        source = DAEUtil.createElementSource(info, Env.getEnvPath(env), PrefixUtil.prefixToCrefOpt(pre), NONE(), NONE());
        partialPrefixBool = SCode.partialBool(partialPrefix);
        cmt = extractClassDefComment(cache, env, cd);
      then
        (cache,env_1,ih,{DAE.FUNCTION(fpath,DAE.FUNCTION_EXT(daeElts,extdecl)::derFuncs,ty1,partialPrefixBool,DAE.NO_INLINE(),source,cmt)});

    /* Instantiate overloaded functions */
    case (cache,env,ih,mod,pre,csets,(c as SCode.CLASS(name = n,restriction = (restr as SCode.R_FUNCTION()),
          classDef = SCode.OVERLOAD(pathLst = funcnames))),inst_dims)
      equation
        (cache,env_1,ih,resfns) = instOverloadedFunctions(cache,env,ih, n, funcnames) "Overloaded functions" ;
      then
        (cache,env_1,ih,resfns);
    
    // handle failure
    case (_,env,_,_,_,_,SCode.CLASS(name=n),_)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.implicitFunctionInstantiation2 failed " +& n);
        Debug.traceln("  Scope: " +& Env.printEnvPathStr(env));
      then fail();
  end matchcontinue;
end implicitFunctionInstantiation2;

protected function instantiateDerivativeFuncs "instantiates all functions found in derivative annotations so they are also added to the
dae and can be generated code for in case they are required"
  input Env.Cache cache;
  input Env.Env env;
  input InstanceHierarchy ih;
  input list<DAE.FunctionDefinition> funcs;
  input Absyn.Path path "the function name itself, must be added to derivative functions mapping to be able to search upwards";
  output Env.Cache outCache;
algorithm
 // print("instantiate deriative functions for "+&Absyn.pathString(path)+&"\n");
 (outCache) := instantiateDerivativeFuncs2(cache,env,ih,DAEUtil.getDerivativePaths(funcs),path);
 // print("instantiated derivative functions for "+&Absyn.pathString(path)+&"\n");
end instantiateDerivativeFuncs;

protected function instantiateDerivativeFuncs2 "help function"
  input Env.Cache cache;
  input Env.Env env;
  input InstanceHierarchy ih;
  input list<Absyn.Path> paths;
  input Absyn.Path path "the function name itself, must be added to derivative functions mapping to be able to search upwards";
  output Env.Cache outCache;
algorithm
  (outCache) := matchcontinue(cache,env,ih,paths,path)
    local
      list<DAE.Function> funcs;
      Absyn.Path p;
      Env.Env cenv;
      SCode.Element cdef;

    case(cache,env,ih,{},path) then (cache);
      
    /* Skipped recursive calls (by looking in cache) */
    case(cache,env,ih,p::paths,path)
      equation
        (cache,cdef,cenv) = Lookup.lookupClass(cache,env,p,true);
        (cache,p) = makeFullyQualified(cache,cenv,p);
        Env.checkCachedInstFuncGuard(cache,p);
        cache = instantiateDerivativeFuncs2(cache,env,ih,paths,path);
      then (cache);

    case(cache,env,ih,p::paths,path)
      equation
        (cache,cdef,cenv) = Lookup.lookupClass(cache,env,p,true);
        (cache,p) = makeFullyQualified(cache,cenv,p);
        // add to cache before instantiating, to break recursion for recursive definitions.
        cache = Env.addCachedInstFuncGuard(cache,p);
        (cache,_,ih,funcs) = implicitFunctionInstantiation2(cache,cenv,ih,DAE.NOMOD(),Prefix.NOPRE(), Connect.emptySet,cdef,{});
        
        funcs = addNameToDerivativeMapping(funcs,path);
        cache = Env.addDaeFunction(cache, funcs);
        cache = instantiateDerivativeFuncs2(cache,env,ih,paths,path);
      then (cache);

    else
      equation
        true = RTOpts.debugFlag("failtrace");
        p :: _ = paths;
        Debug.traceln("- Inst.instantiateDerivativeFuncs2 failed for " +&
          Absyn.pathString(p));
      then
        fail();

  end matchcontinue;
end instantiateDerivativeFuncs2;

protected function addNameToDerivativeMapping
  input list<DAE.Function> elts;
  input Absyn.Path path;
  output list<DAE.Function> outElts;
algorithm
  outElts := matchcontinue(elts,path)
  local
    DAE.Function elt;
    list<DAE.FunctionDefinition> funcs;
    DAE.Type tp;
    Absyn.Path p;
    Boolean part;
    DAE.InlineType inlineType;
    DAE.ElementSource source;
    Option<SCode.Comment> cmt;

    case({},path) then {};

    case(DAE.FUNCTION(p,funcs,tp,part,inlineType,source,cmt)::elts,path)
      equation
        elts = addNameToDerivativeMapping(elts,path);
        funcs = addNameToDerivativeMappingFunctionDefs(funcs,path);
      then DAE.FUNCTION(p,funcs,tp,part,inlineType,source,cmt)::elts;

    case(elt::elts,path)
      equation
        elts = addNameToDerivativeMapping(elts,path);
      then elt::elts;
  end matchcontinue;
end addNameToDerivativeMapping;

protected function addNameToDerivativeMappingFunctionDefs " help function to addNameToDerivativeMappingElts"
  input list<DAE.FunctionDefinition> funcs;
  input Absyn.Path path;
  output list<DAE.FunctionDefinition> outFuncs;
algorithm
  outFuncs := matchcontinue(funcs,path)
  local DAE.FunctionDefinition func;
    Absyn.Path p1,p2;
    Integer do;
    Option<Absyn.Path> dd;
    list<Absyn.Path> lowerOrderDerivatives;
    list<tuple<Integer,DAE.derivativeCond>> conds;

    case({},_) then {};

    case(DAE.FUNCTION_DER_MAPPER(p1,p2,do,conds,dd,lowerOrderDerivatives)::funcs,path)
      equation
        funcs = addNameToDerivativeMappingFunctionDefs(funcs,path);
      then DAE.FUNCTION_DER_MAPPER(p1,p2,do,conds,dd,path::lowerOrderDerivatives)::funcs;

    case(func::funcs,path)
      equation
        funcs = addNameToDerivativeMappingFunctionDefs(funcs,path);
      then func::funcs;

  end matchcontinue;
end addNameToDerivativeMappingFunctionDefs;

protected function getDeriveAnnotation "
Authot BZ
helper function for implicitFunctionInstantiation, returns derivative of function, if any."
  input SCode.ClassDef cd;
  input Absyn.Path baseFunc;
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output list<DAE.FunctionDefinition> element;
algorithm
  element := matchcontinue(cd,baseFunc,inCache,inEnv,inIH,inPrefix,info)
    local
      list<SCode.Annotation> anns;
      list<SCode.Element> elemDecl;
      SCode.Annotation ann;
    
    case(SCode.PARTS(annotationLst = anns, elementLst = elemDecl, externalDecl=NONE()),baseFunc,inCache,inEnv,inIH,inPrefix,info)
    then getDeriveAnnotation2(anns,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info);

    case(SCode.PARTS(annotationLst = anns, elementLst = elemDecl, externalDecl=SOME(SCode.EXTERNALDECL(annotation_=SOME(ann)))),baseFunc,inCache,inEnv,inIH,inPrefix,info)
    then getDeriveAnnotation2(ann::anns,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info);

    case(SCode.CLASS_EXTENDS(composition=SCode.PARTS(annotationLst = anns, elementLst = elemDecl)),baseFunc,inCache,inEnv,inIH,inPrefix,info)
    then getDeriveAnnotation2(anns,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info);

    case(_,_,_,_,_,_,_) then {};
    
  end matchcontinue;
end getDeriveAnnotation;

protected function getDeriveAnnotation2 "
helper function for getDeriveAnnotation"
  input list<SCode.Annotation> anns;
  input list<SCode.Element> elemDecl;
  input Absyn.Path baseFunc;
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output list<DAE.FunctionDefinition> element;
algorithm
  (element) := matchcontinue(anns,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info)
  local
    list<SCode.SubMod> smlst;

  case({},_,_,_,_,_,_,_) then {};

  case(SCode.ANNOTATION(SCode.MOD(_,_,smlst,_)) :: anns,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info)
     then getDeriveAnnotation3(smlst,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info);

  case(_::anns,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info)
     then getDeriveAnnotation2(anns,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info);
end matchcontinue;
end getDeriveAnnotation2;

protected function getDeriveAnnotation3 "
Author: bjozac
  helper function to getDeriveAnnotation2"
  input list<SCode.SubMod> subs;
  input list<SCode.Element> elemDecl;
  input Absyn.Path baseFunc;
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output list<DAE.FunctionDefinition> element;
algorithm element := matchcontinue(subs,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info)
  local
    Absyn.Exp ae;
    Absyn.ComponentRef acr;
    Absyn.Path deriveFunc;
    Option<Absyn.Path> defaultDerivative;
    SCode.Mod m;
    list<SCode.SubMod> subs2;
    Integer order;
    list<tuple<Integer,DAE.derivativeCond>> conditionRefs;
    DAE.FunctionDefinition mapper;

  case({},_,_,_,_,_,_,_) then fail();

  case(SCode.NAMEMOD("derivative",(m as SCode.MOD(subModLst = subs2,binding=SOME(((ae as Absyn.CREF(acr)),_)))))::subs,
       elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info)
    equation
      deriveFunc = Absyn.crefToPath(acr);
      (_,deriveFunc) = makeFullyQualified(inCache,inEnv,deriveFunc);
      order = getDerivativeOrder(subs2);

      ErrorExt.setCheckpoint("getDeriveAnnotation3") "don't report errors on modifers in functions";
      conditionRefs = getDeriveCondition(subs2,elemDecl,inCache,inEnv,inIH,inPrefix,info);
      ErrorExt.rollBack("getDeriveAnnotation3");

      conditionRefs = Util.sort(conditionRefs,DAEUtil.derivativeOrder);
      defaultDerivative = getDerivativeSubModsOptDefault(subs,inCache,inEnv,inPrefix);


      /*print("\n adding conditions on derivative count: " +& intString(listLength(conditionRefs)) +& "\n");
      dbgString = Absyn.optPathString(defaultDerivative);
      dbgString = Util.if_(stringEq(dbgString,""),"", "**** Default Derivative: " +& dbgString +& "\n");
      print("**** Function derived: " +& Absyn.pathString(baseFunc) +& " \n");
      print("**** Deriving function: " +& Absyn.pathString(deriveFunc) +& "\n");
      print("**** Conditions: " +& Util.stringDelimitList(DAEDump.dumpDerivativeCond(conditionRefs),", ") +& "\n");
      print("**** Order: " +& intString(order) +& "\n");
      print(dbgString);*/


      mapper = DAE.FUNCTION_DER_MAPPER(baseFunc,deriveFunc,order,conditionRefs,defaultDerivative,{});
    then
      {mapper};

  case(_ :: subs,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info)
  then getDeriveAnnotation3(subs,elemDecl,baseFunc,inCache,inEnv,inIH,inPrefix,info);
end matchcontinue;
end getDeriveAnnotation3;

protected function getDeriveCondition "
helper function for getDeriveAnnotation
Extracts conditions for derivative."
  input list<SCode.SubMod> subs;
  input list<SCode.Element> elemDecl;
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output list<tuple<Integer,DAE.derivativeCond>> outconds;
algorithm 
  outconds := matchcontinue(subs,elemDecl,inCache,inEnv,inIH,inPrefix,info)
  local
    SCode.Mod m;
    DAE.Mod elabedMod;
    DAE.SubMod sub;
    String name;
    DAE.derivativeCond cond;
    Absyn.ComponentRef acr;
    Integer varPos;
      
    case({},_,_,_,_,_,_) then {};
      
    case(SCode.NAMEMOD("noDerivative",(m as SCode.MOD(binding = SOME(((Absyn.CREF(acr)),_)))))::subs,elemDecl,inCache,inEnv,inIH,inPrefix,info)
    equation
      name = Absyn.printComponentRefStr(acr);
        outconds = getDeriveCondition(subs,elemDecl,inCache,inEnv,inIH,inPrefix,info);
      varPos = setFunctionInputIndex(elemDecl,name,1);
    then
      (varPos,DAE.NO_DERIVATIVE(DAE.ICONST(99)))::outconds;

    case(SCode.NAMEMOD("zeroDerivative",(m as SCode.MOD(binding =  SOME(((Absyn.CREF(acr)),_)) )))::subs,elemDecl,inCache,inEnv,inIH,inPrefix,info)
    equation
      name = Absyn.printComponentRefStr(acr);
        outconds = getDeriveCondition(subs,elemDecl,inCache,inEnv,inIH,inPrefix,info);
      varPos = setFunctionInputIndex(elemDecl,name,1);
    then
      (varPos,DAE.ZERO_DERIVATIVE())::outconds;
        
    case(SCode.NAMEMOD("noDerivative",(m as SCode.MOD(binding=_)))::subs,elemDecl,inCache,inEnv,inIH,inPrefix,info)
    equation
      (inCache,(elabedMod as DAE.MOD(subModLst={sub}))) = Mod.elabMod(inCache, inEnv, inIH, inPrefix, m, false,info);
      (name,cond) = extractNameAndExp(sub);
      outconds = getDeriveCondition(subs,elemDecl,inCache,inEnv,inIH,inPrefix,info);
      varPos = setFunctionInputIndex(elemDecl,name,1);
    then
      (varPos,cond)::outconds;

    case(_::subs,elemDecl,inCache,inEnv,inIH,inPrefix,info)
    then getDeriveCondition(subs,elemDecl,inCache,inEnv,inIH,inPrefix,info);
end matchcontinue;
end getDeriveCondition;

protected function setFunctionInputIndex "
Author BZ"
input list<SCode.Element> elemDecl;
input String str;
input Integer currPos;
output Integer index;
algorithm
  index := matchcontinue(elemDecl,str,currPos)
  local
    String str2;

  case({},str,currPos)
    equation
      print(" failure in setFunctionInputIndex, didn't find any index for: " +& str +& "\n");
      then fail();

        /* found matching input*/
      case(SCode.COMPONENT(name=str2,attributes =SCode.ATTR(direction=Absyn.INPUT()))::elemDecl,str,currPos)
        equation
          true = stringEq(str2, str);
          then
            currPos;

       /* Non-matching input, increase inputarg pos*/
    case(SCode.COMPONENT(name=_,attributes =SCode.ATTR(direction=Absyn.INPUT()))::elemDecl,str,currPos) 
      then setFunctionInputIndex(elemDecl,str,currPos+1);

       /* Other element, do not increaese inputarg pos*/
      case(_::elemDecl,str,currPos) then setFunctionInputIndex(elemDecl,str,currPos);
  end matchcontinue;
end setFunctionInputIndex;

protected function extractNameAndExp "
Author BZ
could be used by getDeriveCondition, depending on interpretation of spec compared to constructed libraries.
helper function for getDeriveAnnotation
"
  input DAE.SubMod m;
  output String inputVar;
  output DAE.derivativeCond cond;
algorithm
  (inputVar,cond) := matchcontinue(m)
  local
    DAE.EqMod eq;
    DAE.Exp e;
  case(DAE.NAMEMOD(inputVar,mod = DAE.MOD(eqModOption = SOME(eq as DAE.TYPED(modifierAsExp=e)))))
    equation
      then (inputVar,DAE.NO_DERIVATIVE(e));
  case(DAE.NAMEMOD(inputVar,mod = DAE.MOD(eqModOption = NONE())))
    equation
    then (inputVar,DAE.NO_DERIVATIVE(DAE.ICONST(1)));
  case(DAE.NAMEMOD(inputVar,mod = DAE.MOD(eqModOption = NONE()))) // zeroderivative
  then (inputVar,DAE.ZERO_DERIVATIVE());

  case(_) then ("",DAE.ZERO_DERIVATIVE());
  end matchcontinue;
end extractNameAndExp;

protected function getDerivativeSubModsOptDefault "
helper function for getDeriveAnnotation"
input list<SCode.SubMod> subs;
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Prefix.Prefix inPrefix;
output Option<Absyn.Path> defaultDerivative;
algorithm defaultDerivative := matchcontinue(subs,inCache,inEnv,inPrefix)
  local
    Absyn.ComponentRef acr;
    Absyn.Path p;
    Absyn.Exp ae;
    SCode.Mod m;
  case({},inCache,inEnv,inPrefix) then NONE();
  case(SCode.NAMEMOD("derivative",(m as SCode.MOD(binding =SOME(((ae as Absyn.CREF(acr)),_)))))::subs,inCache,inEnv,inPrefix)
    equation
      p = Absyn.crefToPath(acr);
      (_,p) = makeFullyQualified(inCache,inEnv, p);
    then
      SOME(p);
  case(_::subs,inCache,inEnv,inPrefix) then getDerivativeSubModsOptDefault(subs,inCache,inEnv,inPrefix);
  end matchcontinue;
end getDerivativeSubModsOptDefault;

protected function getDerivativeOrder "
helper function for getDeriveAnnotation
Get current derive order
"
input list<SCode.SubMod> subs;
output Integer order;
algorithm order := matchcontinue(subs)
  local
    Absyn.Exp ae;
    SCode.Mod m;
  case({}) then 1;
  case(SCode.NAMEMOD("order",(m as SCode.MOD(binding= SOME(((ae as Absyn.INTEGER(order)),_)))))::subs)
  then order;
  case(_::subs) then getDerivativeOrder(subs);
  end matchcontinue;
end getDerivativeOrder;

protected function setFullyQualifiedTypename
"This function sets the FQ path given as argument in types that have optional path set.
 (The optional path points to the class the type is built from)"
  input DAE.Type inType;
  input Absyn.Path path;
  output DAE.Type resType;
algorithm
  resType := match (inType,path)
    local
      Absyn.Path p,newPath;
      DAE.TType tp;
    case ((tp,NONE()),_) then ((tp,NONE()));
    case ((tp,SOME(p)),newPath) then ((tp,SOME(newPath)));
  end match;
end setFullyQualifiedTypename;

public function isInlineFunc "
Author: stefan
function: isInlineFunc
  looks up a function and returns whether or not it is an inline function"
  input Absyn.Path inPath;
  input Env.Cache inCache;
  input Env.Env inEnv;
  output DAE.InlineType outBoolean;
algorithm
  outBoolean := matchcontinue(inPath,inCache,inEnv)
    local
      Absyn.Path p;
      Env.Cache c;
      Env.Env env;
      SCode.Element cl;
    case(p,c,env)
      equation
        (c,cl,env) = Lookup.lookupClass(c,env,p,true);
      then
        isInlineFunc2(cl);
    case(_,_,_) then DAE.NO_INLINE();
  end matchcontinue;
end isInlineFunc;

public function isInlineFunc2 "
Author: bjozac 2009-12
  helper function to isInlineFunc"
  input SCode.Element inClass;
  output DAE.InlineType outInlineType;
algorithm
  outInlineType := matchcontinue(inClass)
    local
      list<SCode.Annotation> anns;

    case(SCode.CLASS(classDef = SCode.PARTS(annotationLst = anns)))
      then isInlineFunc3(anns);

    case(SCode.CLASS(classDef = SCode.CLASS_EXTENDS(composition = SCode.PARTS(annotationLst = anns))))
      then isInlineFunc3(anns);
    
    case(_) then DAE.NO_INLINE();
  end matchcontinue;
end isInlineFunc2;

protected function isInlineFunc3 "
Author Stefan
  helper function to isInlineFunc2"
  input list<SCode.Annotation> inAnnotationList;
  output DAE.InlineType outBoolean;
algorithm
  outBoolean := matchcontinue(inAnnotationList)
    local
      list<SCode.Annotation> cdr;
      list<SCode.SubMod> smlst;
      DAE.InlineType res;
    
    case({}) then DAE.NO_INLINE();

    case(SCode.ANNOTATION(SCode.MOD(_,_,smlst,_)) :: cdr)
      equation
        res = isInlineFunc4(smlst);
        true = DAEUtil.convertInlineTypeToBool(res);
      then
        res;

    case(_ :: cdr)
      equation
        res = isInlineFunc3(cdr);
      then
        res;

  end matchcontinue;
end isInlineFunc3;

protected function isInlineFunc4 "
Author: stefan
function: isInlineFunc4
  helper function to isInlineFunc3"
  input list<SCode.SubMod> inSubModList;
  output DAE.InlineType res;
algorithm
  res := matchcontinue(inSubModList)
    local
      list<SCode.SubMod> cdr;
    case ({}) then DAE.NO_INLINE();

    case (SCode.NAMEMOD("Inline",SCode.MOD(_,_,_,SOME((Absyn.BOOL(true),_)))) :: cdr)
      equation
        failure(DAE.AFTER_INDEX_RED_INLINE() = isInlineFunc4(cdr));
      then DAE.NORM_INLINE();

    case(SCode.NAMEMOD("LateInline",SCode.MOD(_,_,_,SOME((Absyn.BOOL(true),_)))) :: _)
      then DAE.AFTER_INDEX_RED_INLINE();

    case(SCode.NAMEMOD("__MathCore_InlineAfterIndexReduction",SCode.MOD(_,_,_,SOME((Absyn.BOOL(true),_)))) :: _)
      then DAE.AFTER_INDEX_RED_INLINE();

    case (SCode.NAMEMOD("__Dymola_InlineAfterIndexReduction",SCode.MOD(_,_,_,SOME((Absyn.BOOL(true),_)))) :: _)
      then DAE.AFTER_INDEX_RED_INLINE();

    case (SCode.NAMEMOD("__OpenModelica_EarlyInline",SCode.MOD(_,_,_,SOME((Absyn.BOOL(true),_)))) :: cdr)
      equation
        DAE.NO_INLINE() = isInlineFunc4(cdr);
      then DAE.EARLY_INLINE();

    case(_ :: cdr) then isInlineFunc4(cdr);
  end matchcontinue;
end isInlineFunc4;

protected function stripFuncOutputsMod "strips the assignment modification of the component declared as output"
  input SCode.Element elem;
  output SCode.Element stripped_elem;
algorithm
  stripped_elem := matchcontinue(elem)
    local
      SCode.Ident id;
      Absyn.InnerOuter inOut;
      SCode.Final finPre;
      SCode.Replaceable repPre;
      SCode.Visibility vis;
      SCode.Redeclare redecl;
      SCode.Attributes attr;
      Absyn.TypeSpec typeSpc;
      Option<SCode.Comment> comm;
      Option<Absyn.Exp> cond;
      Absyn.Info info;
      SCode.Final modFinPre;
      SCode.Each modEachPre;
      list<SCode.SubMod> modSubML;
      SCode.Element e;
      SCode.Mod modBla;
      
    case (e as 
      SCode.COMPONENT(
          name = id,
          prefixes = SCode.PREFIXES(
            visibility = vis, 
            redeclarePrefix = redecl, 
            finalPrefix = finPre, 
            innerOuter = inOut, 
            replaceablePrefix = repPre),
          attributes = attr as SCode.ATTR(direction = Absyn.OUTPUT()), 
          typeSpec = typeSpc,
          modifications = SCode.MOD(finalPrefix = modFinPre, eachPrefix = modEachPre, subModLst = modSubML, binding = SOME(_)),
          comment = comm, condition = cond, info = info))
      equation
        modBla = SCode.MOD(modFinPre,modEachPre,modSubML,NONE());
      then 
        SCode.COMPONENT(
          id, 
          SCode.PREFIXES(vis,redecl,finPre,inOut,repPre),
          attr,typeSpc,modBla,comm,cond,info);

    case (e) then (e);
    
  end matchcontinue;
end stripFuncOutputsMod;

public function implicitFunctionTypeInstantiation 
"function implicitFunctionTypeInstantiation
  author: PA
  When looking up a function type it is sufficient to only instantiate the input and output arguments of the function. 
  The implicitFunctionInstantiation function will instantiate the function body, resulting in a DAE for the body. 
  This function does not do that. Therefore this function is the only solution available for recursive functions, 
  where the function body contain a call to the function itself.
  
  Extended 2007-06-29, BZ 
  Now this function also handles Derived function."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Element inClass;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
algorithm
  (outCache,outEnv,outIH) := matchcontinue (inCache,inEnv,inIH,inClass)
    local
      SCode.Element stripped_class;
      list<Env.Frame> env_1,env;
      String id,cn2;
      SCode.Partial p;
      SCode.Encapsulated e;
      SCode.Restriction r;
      Option<SCode.ExternalDecl> extDecl;
      list<SCode.Element> elts, stripped_elts;
      Env.Cache cache;
      InstanceHierarchy ih;
      list<SCode.Annotation> annotationLst;
      Absyn.Info info;
      DAE.DAElist dae;
      list<DAE.Function> funs;
      Absyn.Path cn,fpath;
      Option<list<Absyn.Subscript>> ad;
      SCode.Mod mod1;
      DAE.Mod mod2;
      Env.Env cenv;
      SCode.Element c;
      DAE.Type ty1,ty;
      SCode.Prefixes prefixes;

    // The function type can be determined without the body. Annotations need to be preserved though.
    case (cache,env,ih,SCode.CLASS(name = id,prefixes = prefixes,
                                   encapsulatedPrefix = e,partialPrefix = p,restriction = r,
                                   classDef = SCode.PARTS(elementLst = elts,annotationLst=annotationLst,externalDecl=extDecl),info = info)) 
      equation
        stripped_elts = Util.listMap(elts,stripFuncOutputsMod);
        stripped_class = SCode.CLASS(id,prefixes,e,p,r,SCode.PARTS(elts,{},{},{},{},extDecl,annotationLst,NONE()),info);
        (cache,env_1,ih,funs) = implicitFunctionInstantiation2(cache,env,ih, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, stripped_class, {});
        /* Only external functions are valid without an algorithm section... */
        cache = Env.addDaeExtFunction(cache, funs);
      then
        (cache,env_1,ih);

    /* Short class definitions. */
    case (cache,env,ih,SCode.CLASS(name = id,partialPrefix = p,encapsulatedPrefix = e,restriction = r,
                                   classDef = SCode.DERIVED(typeSpec = Absyn.TPATH(path = cn,arrayDim = ad), 
                                                            modifications = mod1),info = info))  
      equation 
        (cache,(c as SCode.CLASS(name = cn2, restriction = r)),cenv) = Lookup.lookupClass(cache, env, cn, true);
        (cache,mod2) = Mod.elabMod(cache, env, ih, Prefix.NOPRE(), mod1, false, info);
        (cache,_,ih,_,dae,_,ty,_,_,_) =
          instClass(cache,cenv,ih,UnitAbsynBuilder.emptyInstStore(), mod2,
            Prefix.NOPRE(), Connect.emptySet, c, {}, true, INNER_CALL(), ConnectionGraph.EMPTY);
        env_1 = Env.extendFrameC(env,c);
        (cache,fpath) = makeFullyQualified(cache,env_1, Absyn.IDENT(id));
        ty1 = setFullyQualifiedTypename(ty,fpath);
        env_1 = Env.extendFrameT(env_1, id, ty1);
      then
        (cache,env_1,ih);

    case (_,_,_,_)
      equation
        Debug.fprintln("failtrace", "- Inst.implicitFunctionTypeInstantiation failed");
      then fail();
  end matchcontinue;
end implicitFunctionTypeInstantiation;

protected function instOverloadedFunctions 
"function: instOverloadedFunctions 
  This function instantiates the functions in the overload list of a 
  overloading function definition and register the function types using 
  the overloaded name. It also creates dae elements for the functions."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Absyn.Ident inIdent;
  input list<Absyn.Path> inAbsynPathLst;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output list<DAE.Function> outFns;
algorithm 
  (outCache,outEnv,outIH,outFns) := matchcontinue (inCache,inEnv,inIH,inIdent,inAbsynPathLst)
    local
      list<Env.Frame> env,cenv,env_1,env_2;
      SCode.Element c;
      String id,overloadname;
      SCode.Encapsulated encflag;
      list<DAE.Element> daeElts;
      list<tuple<String, DAE.Type>> args;
      DAE.Type tp,ty;
      ClassInf.State st;
      Absyn.Path fpath,ovlfpath,fn;
      list<Absyn.Path> fns;
      Env.Cache cache;
      InstanceHierarchy ih;
      SCode.Partial partialPrefix;
      DAE.FunctionAttributes functionAttributes;
      DAE.ElementSource source "the origin of the element";
      Absyn.Info info;
      list<DAE.Function> resfns;
      DAE.Function resfn;
      Boolean partialPrefixBool;
      
    case (cache,env,ih,_,{}) then (cache,env,ih,{});

    // Instantiate each function, add its FQ name to the type, needed when deoverloading  
    case (cache,env,ih,overloadname,(fn :: fns))
      equation 
        (cache,(c as SCode.CLASS(name=id,partialPrefix=partialPrefix,encapsulatedPrefix=encflag,restriction=SCode.R_FUNCTION(),info=info)),cenv) = Lookup.lookupClass(cache, env, fn, true);
        (cache,_,ih,_,DAE.DAE(daeElts),_,(DAE.T_FUNCTION(args,tp,functionAttributes),_),st,_,_) = 
           instClass(cache,cenv,ih,UnitAbsynBuilder.emptyInstStore(),
             DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, {}, true, INNER_CALL(), ConnectionGraph.EMPTY);
        (cache,fpath) = makeFullyQualified(cache,env, Absyn.IDENT(overloadname));
        (cache,ovlfpath) = makeFullyQualified(cache,cenv, Absyn.IDENT(id));
        ty = (DAE.T_FUNCTION(args,tp,functionAttributes),SOME(ovlfpath));
        env_1 = Env.extendFrameT(env, overloadname, ty);
        (cache,env_2,ih,resfns) = instOverloadedFunctions(cache,env_1,ih, overloadname, fns);
        // TODO: Fix inline here 
        print(" DAE.InlineType FIX HERE \n");
        // set the  of this element
        source = DAEUtil.createElementSource(info, Env.getEnvPath(env), NONE(), NONE(), NONE());
        partialPrefixBool = SCode.partialBool(partialPrefix);
        resfn = DAE.FUNCTION(fpath,{DAE.FUNCTION_DEF(daeElts)},ty,partialPrefixBool,DAE.NO_INLINE(),source,NONE());
      then
        (cache,env_2,ih,resfn::resfns);
    
    // failure
    case (_,env,ih,_,_)
      equation 
        Debug.fprint("failtrace", "- Inst.instOverloaded_functions failed\n");
      then
        fail();
  end matchcontinue;
end instOverloadedFunctions;

protected function instExtDecl 
"function: instExtDecl
  author: LS
  This function handles the external declaration. If there is an explicit 
  call of the external function, the component references are looked up and
  inserted in the argument list, otherwise the input and output parameters
  are inserted in the argument list with their order. The return type is
  determined according to the specification; if there is a explicit call 
  and a lhs, which must be an output parameter, the type of the function is
  that type. If no explicit call and only one output parameter exists, then
  this will be the return type of the function, otherwise the return type 
  will be void."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Ident inIdent;
  input SCode.ClassDef inClassDef;
  input Boolean inBoolean;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
  output DAE.ExternalDecl outExternalDecl;
algorithm 
  (outCache,outIH,outExternalDecl) := matchcontinue (inCache,inEnv,inIH,inIdent,inClassDef,inBoolean,inPrefix,info)
    local
      String fname,lang,n;
      list<DAE.ExtArg> fargs;
      DAE.ExtArg rettype;
      Option<SCode.Annotation> ann;
      DAE.ExternalDecl daeextdecl;
      list<Env.Frame> env;
      SCode.ExternalDecl extdecl,orgextdecl;
      Boolean impl;
      list<SCode.Element> els;
      Env.Cache cache;
      InstanceHierarchy ih;
      Prefix.Prefix pre;
      
    case (cache,env,ih,n,SCode.PARTS(elementLst=els,externalDecl = SOME(extdecl)),impl,pre,info) /* impl */
      equation 
        isExtExplicitCall(extdecl);
        fname = instExtGetFname(extdecl, n);
        (cache,fargs) = instExtGetFargs(cache,env, extdecl, impl,pre,info);
        (cache,rettype) = instExtGetRettype(cache,env, extdecl, impl,pre,info);
        lang = instExtGetLang(extdecl);
        ann = instExtGetAnnotation(extdecl);
        daeextdecl = DAE.EXTERNALDECL(fname,fargs,rettype,lang,ann);
      then
        (cache,ih,daeextdecl);
        
    case (cache,env,ih,n,SCode.PARTS(elementLst = els,externalDecl = SOME(orgextdecl)),impl,pre,info)
      equation 
        failure(isExtExplicitCall(orgextdecl));
        extdecl = instExtMakeExternaldecl(n, els, orgextdecl);
        (fname) = instExtGetFname(extdecl, n);
        (cache,fargs) = instExtGetFargs(cache,env, extdecl, impl,pre,info);
        (cache,rettype) = instExtGetRettype(cache,env, extdecl, impl,pre,info);
        lang = instExtGetLang(extdecl);
        ann = instExtGetAnnotation(orgextdecl);
        daeextdecl = DAE.EXTERNALDECL(fname,fargs,rettype,lang,ann);
      then
        (cache,ih,daeextdecl);
    case (_,env,ih,_,_,_,_,_)
      equation 
        Debug.fprintln("failtrace", "#-- Inst.instExtDecl failed");
      then
        fail();
  end matchcontinue;
end instExtDecl;

protected function isExtExplicitCall 
"function: isExtExplicitCall  
  If the external function id is present, then a function call must
  exist, i.e. explicit call was written in the external clause."
  input SCode.ExternalDecl inExternalDecl;
algorithm 
  _ := match (inExternalDecl)
    local String id;
    case SCode.EXTERNALDECL(funcName = SOME(id)) then ();
  end match;
end isExtExplicitCall;

protected function instExtMakeExternaldecl 
"function: instExtMakeExternaldecl
  author: LS
   This function generates a default explicit function call, 
  when it is omitted. If only one output variable exists, 
  the implicit call is equivalent to:
       external \"C\" output_var=func(input_var1, input_var2,...)
  with the input_vars in their declaration order. If several output 
  variables exists, the implicit call is equivalent to:
      external \"C\" func(var1, var2, ...)
  where each var can be input or output."
  input Ident inIdent;
  input list<SCode.Element> inSCodeElementLst;
  input SCode.ExternalDecl inExternalDecl;
  output SCode.ExternalDecl outExternalDecl;
algorithm 
  outExternalDecl := matchcontinue (inIdent,inSCodeElementLst,inExternalDecl)
    local
      SCode.Element outvar;
      list<SCode.Element> invars,els,inoutvars;
      list<list<Absyn.Exp>> explists;
      list<Absyn.Exp> exps;
      Absyn.ComponentRef retcref;
      SCode.ExternalDecl extdecl;
      String id;
      Option<String> lang;

    /* the case with only one output var, and that cannot be 
     * array, otherwise instExtMakeCrefs outvar will fail 
     */      
    case (id,els,SCode.EXTERNALDECL(lang = lang))
      equation 
        (outvar :: {}) = Util.listFilter(els, isOutputVar);
        invars = Util.listFilter(els, isInputVar);
        explists = Util.listMap(invars, instExtMakeCrefs);
        exps = Util.listFlatten(explists);
        {Absyn.CREF(retcref)} = instExtMakeCrefs(outvar);
        extdecl = SCode.EXTERNALDECL(SOME(id),lang,SOME(retcref),exps,NONE());
      then
        extdecl;
    case (id,els,SCode.EXTERNALDECL(lang = lang))
      equation 
        inoutvars = Util.listFilter(els, isInoutVar);
        explists = Util.listMap(inoutvars, instExtMakeCrefs);
        exps = Util.listFlatten(explists);
        extdecl = SCode.EXTERNALDECL(SOME(id),lang,NONE(),exps,NONE());
      then
        extdecl;
    case (_,_,_)
      equation 
        Debug.fprintln("failtrace", "#-- Inst.instExtMakeExternaldecl failed");
      then
        fail();
  end matchcontinue;
end instExtMakeExternaldecl;

protected function isInoutVar 
"function: isInoutVar  
  Succeds for Elements that are input or output components"
  input SCode.Element inElement;
algorithm 
  _ := matchcontinue (inElement)
    local SCode.Element e;
    case e equation isOutputVar(e); then ();
    case e equation isInputVar(e); then ();
  end matchcontinue;
end isInoutVar;

protected function isOutputVar 
"function: isOutputVar 
  Succeds for element that is output component"
  input SCode.Element inElement;
algorithm 
  _ := match (inElement)
    case SCode.COMPONENT(attributes = SCode.ATTR(direction = Absyn.OUTPUT())) then ();
  end match;
end isOutputVar;

protected function isInputVar 
"function: isInputVar 
  Succeds for element that is input component"
  input SCode.Element inElement;
algorithm 
  _ := match (inElement)
    case SCode.COMPONENT(attributes = SCode.ATTR(direction = Absyn.INPUT())) then ();
  end match;
end isInputVar;

protected function instExtMakeCrefs 
"function: instExtMakeCrefs
  author: LS
  This function is used in external function declarations. 
  It collects the component identifier and the dimension 
  sizes and returns as a Absyn.Exp list"
  input SCode.Element inElement;
  output list<Absyn.Exp> outAbsynExpLst;
algorithm 
  outAbsynExpLst := match (inElement)
    local
      list<Absyn.Exp> sizelist,crlist;
      String id;
      SCode.Final fi;
      SCode.Replaceable re;
      SCode.Visibility pr;
      list<Absyn.Subscript> dims;
      Absyn.TypeSpec path;
      SCode.Mod mod;
      Option<SCode.Comment> comment;

    case SCode.COMPONENT(
           name = id,
           prefixes = SCode.PREFIXES(
                        finalPrefix = fi,
                        replaceablePrefix = re,
                        visibility = pr),
           attributes = SCode.ATTR(arrayDims = dims),
           typeSpec = path,
           modifications = mod,
           comment = comment)
      equation 
        sizelist = instExtMakeCrefs2(id, dims, 1);
        crlist = (Absyn.CREF(Absyn.CREF_IDENT(id,{})) :: sizelist);
      then
        crlist;
  end match;
end instExtMakeCrefs;

protected function instExtMakeCrefs2 
"function: instExtMakeCrefs2 
  Helper function to instExtMakeCrefs, collects array dimension sizes."
  input SCode.Ident inIdent;
  input Absyn.ArrayDim inArrayDim;
  input Integer inInteger;
  output list<Absyn.Exp> outAbsynExpLst;
algorithm 
  outAbsynExpLst := match (inIdent,inArrayDim,inInteger)
    local
      String id;
      Integer nextdimno,dimno;
      list<Absyn.Exp> restlist,exps;
      Absyn.Subscript dim;
      list<Absyn.Subscript> restdim;
    
    case (id,{},_) then {};
    
    case (id,(dim :: restdim),dimno)
      equation 
        nextdimno = dimno + 1;
        restlist = instExtMakeCrefs2(id, restdim, nextdimno);
        exps = (Absyn.CALL(Absyn.CREF_IDENT("size",{}),
          Absyn.FUNCTIONARGS({Absyn.CREF(Absyn.CREF_IDENT(id,{})),
          Absyn.INTEGER(dimno)},{})) :: restlist);
      then
        exps;

  end match;
end instExtMakeCrefs2;

protected function instExtGetFname 
"function: instExtGetFname
  Returns the function name of the externally defined function."
  input SCode.ExternalDecl inExternalDecl;
  input Ident inIdent;
  output Ident outIdent;
algorithm 
  outIdent := match (inExternalDecl,inIdent)
    local String id,fid;
    case (SCode.EXTERNALDECL(funcName = SOME(id)),_) then id;
    case (SCode.EXTERNALDECL(funcName = NONE()),fid) then fid;
  end match;
end instExtGetFname;

protected function instExtGetAnnotation 
"function: instExtGetAnnotation
  author: PA
  Return the annotation associated with an external function declaration.
  If no annotation is found, check the classpart annotations."
  input SCode.ExternalDecl inExternalDecl;
  output Option<SCode.Annotation> outAnnotation;
algorithm 
  outAnnotation := match (inExternalDecl)
    local Option<SCode.Annotation> ann;
    case (SCode.EXTERNALDECL(annotation_ = ann)) then ann;
  end match;
end instExtGetAnnotation;

protected function instExtGetLang 
"function: instExtGetLang
  Return the implementation language of the external function declaration.
  Defaults to \"C\" if no language specified."
  input SCode.ExternalDecl inExternalDecl;
  output String outString;
algorithm 
  outString := match (inExternalDecl)
    local String lang;
    case SCode.EXTERNALDECL(lang = SOME(lang)) then lang;
    case SCode.EXTERNALDECL(lang = NONE()) then "C";
  end match;
end instExtGetLang;

protected function elabExpListExt 
"function: elabExpListExt 
  Special elabExp for explicit external calls. 
  This special function calls elabExpExt which handles size builtin 
  calls specially, and uses the ordinary Static.elab_exp for other 
  expressions."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input list<Absyn.Exp> inAbsynExpLst;
  input Boolean inBoolean;
  input Option<Interactive.InteractiveSymbolTable> inInteractiveInteractiveSymbolTableOption;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output Env.Cache outCache;
  output list<DAE.Exp> outExpExpLst;
  output list<DAE.Properties> outTypesPropertiesLst;
  output Option<Interactive.InteractiveSymbolTable> outInteractiveInteractiveSymbolTableOption;
algorithm 
  (outCache,outExpExpLst,outTypesPropertiesLst,outInteractiveInteractiveSymbolTableOption):=
  match (inCache,inEnv,inAbsynExpLst,inBoolean,inInteractiveInteractiveSymbolTableOption,inPrefix,info)
    local
      Boolean impl;
      Option<Interactive.InteractiveSymbolTable> st,st_1,st_2;
      DAE.Exp exp;
      DAE.Properties p;
      list<DAE.Exp> exps;
      list<DAE.Properties> props;
      list<Env.Frame> env;
      Absyn.Exp e;
      list<Absyn.Exp> rest;
      Env.Cache cache;
      Prefix.Prefix pre;
    case (cache,_,{},impl,st,_,info) then (cache,{},{},st);
    case (cache,env,(e :: rest),impl,st,pre,info)
      equation 
        (cache,exp,p,st_1) = elabExpExt(cache,env, e, impl, st,pre,info);
        (cache,exps,props,st_2) = elabExpListExt(cache,env, rest, impl, st_1,pre,info);
      then
        (cache,(exp :: exps),(p :: props),st_2);
  end match;
end elabExpListExt;

protected function elabExpExt 
"function: elabExpExt
  author: LS
  special elabExp for explicit external calls. 
  This special function calls elabExpExt which handles size builtin calls 
  specially, and uses the ordinary Static.elab_exp for other expressions."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Absyn.Exp inExp;
  input Boolean inBoolean;
  input Option<Interactive.InteractiveSymbolTable> inInteractiveInteractiveSymbolTableOption;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output Env.Cache outCache;
  output DAE.Exp outExp;
  output DAE.Properties outProperties;
  output Option<Interactive.InteractiveSymbolTable> outInteractiveInteractiveSymbolTableOption;
algorithm 
  (outCache,outExp,outProperties,outInteractiveInteractiveSymbolTableOption):=
  matchcontinue (inCache,inEnv,inExp,inBoolean,inInteractiveInteractiveSymbolTableOption,inPrefix,info)
    local
      DAE.Exp dimp,arraycrefe,exp,e;
      DAE.Type dimty;
      DAE.Properties arraycrprop,prop;
      list<Env.Frame> env;
      Absyn.Exp call,arraycr,dim;
      list<Absyn.Exp> args;
      list<Absyn.NamedArg> nargs;
      Boolean impl;
      Option<Interactive.InteractiveSymbolTable> st;
      Env.Cache cache;
      Absyn.Exp absynExp;
      Prefix.Prefix pre;
      
    /* special case for  size */
    case (cache,env,(call as Absyn.CALL(function_ = Absyn.CREF_IDENT(name = "size"),
          functionArgs = Absyn.FUNCTIONARGS(args = (args as {arraycr,dim}),argNames = nargs))),impl,st,pre,info)
      equation         
        (cache,dimp,prop as DAE.PROP(dimty,_),_) = Static.elabExp(cache, env, dim, impl,NONE(),false,pre,info);
        (cache, dimp, prop) = Ceval.cevalIfConstant(cache, env, dimp, prop, impl);
        (cache,arraycrefe,arraycrprop,_) = Static.elabExp(cache, env, arraycr, impl,NONE(),false,pre,info);
        (cache, arraycrefe, arraycrprop) = Ceval.cevalIfConstant(cache, env, arraycrefe, arraycrprop, impl);
        exp = DAE.SIZE(arraycrefe,SOME(dimp));
      then
        (cache,exp,DAE.PROP(DAE.T_INTEGER_DEFAULT,DAE.C_VAR()),st);
    /* For all other expressions, use normal elaboration */
    case (cache,env,absynExp,impl,st,pre,info)
      equation 
        (cache,e,prop,st) = Static.elabExp(cache, env, absynExp, impl, st,false,pre,info);
        (cache, e, prop) = Ceval.cevalIfConstant(cache, env, e, prop, impl);
      then
        (cache,e,prop,st);
    case (cache,env,absynExp,impl,st,pre,info)
      equation 
        Debug.fprintln("failtrace", "-Inst.elabExpExt failed");
      then
        fail();
  end matchcontinue;
end elabExpExt;

protected function instExtGetFargs 
"function: instExtGetFargs
  author: LS
  instantiates function arguments, i.e. actual parameters, in external declaration."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input SCode.ExternalDecl inExternalDecl;
  input Boolean inBoolean;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output Env.Cache outCache;
  output list<DAE.ExtArg> outDAEExtArgLst;
algorithm 
  (outCache,outDAEExtArgLst) :=
  matchcontinue (inCache,inEnv,inExternalDecl,inBoolean,inPrefix,info)
    local
      list<DAE.Exp> exps;
      list<DAE.Properties> props;
      list<DAE.ExtArg> extargs;
      list<Env.Frame> env;
      Option<String> id,lang;
      Option<Absyn.ComponentRef> retcr;
      list<Absyn.Exp> absexps;
      Boolean impl;
      Env.Cache cache;
      Prefix.Prefix pre;
    case (cache,env,SCode.EXTERNALDECL(funcName = id,lang = lang,output_ = retcr,args = absexps),impl,pre,info)
      equation 
        (cache,exps,props,_) = elabExpListExt(cache,env, absexps, impl,NONE(),pre,info);
        (cache,extargs) = instExtGetFargs2(cache,env, exps, props);
      then
        (cache,extargs);
    case (_,_,_,impl,_,_)
      equation 
        Debug.fprintln("failtrace", "- Inst.instExtGetFargs failed");
      then
        fail();
  end matchcontinue;
end instExtGetFargs;

protected function instExtGetFargs2 
"function: instExtGetFargs2
  author: LS
  Helper function to instExtGetFargs"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input list<DAE.Exp> inExpExpLst;
  input list<DAE.Properties> inTypesPropertiesLst;
  output Env.Cache outCache;
  output list<DAE.ExtArg> outDAEExtArgLst;
algorithm 
  (outCache,outDAEExtArgLst) := match (inCache,inEnv,inExpExpLst,inTypesPropertiesLst)
    local
      list<DAE.ExtArg> extargs;
      DAE.ExtArg extarg;
      list<Env.Frame> env;
      DAE.Exp e;
      list<DAE.Exp> exps;
      DAE.Properties p;
      list<DAE.Properties> props;
      Env.Cache cache;
    case (cache,_,{},_) then (cache,{});
    case (cache,env,(e :: exps),(p :: props))
      equation 
        (cache,extargs) = instExtGetFargs2(cache,env, exps, props);
        (cache,extarg) = instExtGetFargsSingle(cache,env, e, p);
      then
        (cache,extarg :: extargs);
  end match;
end instExtGetFargs2;

protected function instExtGetFargsSingle 
"function: instExtGetFargsSingle
  author: LS
  Helper function to instExtGetFargs2, does the work for one argument."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Exp inExp;
  input DAE.Properties inProperties;
  output Env.Cache outCache;
  output DAE.ExtArg outExtArg;
algorithm 
  (outCache,outExtArg) := matchcontinue (inCache,inEnv,inExp,inProperties)
    local
      DAE.Attributes attr;
      DAE.Type ty,varty;
      DAE.Binding bnd;
      list<Env.Frame> env;
      DAE.ComponentRef cref;
      DAE.ExpType crty;
      DAE.Const cnst;
      String crefstr,scope;
      DAE.Exp dim,exp;
      DAE.Properties prop;
      Env.Cache cache;

    case (cache,env,DAE.CREF(componentRef = cref,ty = crty),DAE.PROP(type_ = ty,constFlag = cnst))
      equation
        (cache,attr,ty,bnd,_,_,_,_,_) = Lookup.lookupVarLocal(cache,env, cref);
      then
        (cache,DAE.EXTARG(cref,attr,ty));

    case (cache,env,DAE.CREF(componentRef = cref,ty = crty),DAE.PROP(type_ = ty,constFlag = cnst))
      equation
        failure((_,_,_,_,_,_,_,_,_) = Lookup.lookupVarLocal(cache,env, cref));
        crefstr = ComponentReference.printComponentRefStr(cref);
        scope = Env.printEnvPathStr(env);
        Error.addMessage(Error.LOOKUP_VARIABLE_ERROR, {crefstr,scope});
      then
        fail();

    case (cache,env,DAE.SIZE(exp = DAE.CREF(componentRef = cref,ty = crty),sz = SOME(dim)),DAE.PROP(type_ = ty,constFlag = cnst))
      equation
        (cache,attr,varty,bnd,_,_,_,_,_) = Lookup.lookupVarLocal(cache,env, cref);
      then
        (cache,DAE.EXTARGSIZE(cref,attr,varty,dim));

    case (cache,env,exp,DAE.PROP(type_ = ty,constFlag = cnst)) then (cache,DAE.EXTARGEXP(exp,ty));

    case (cache,_,exp,prop)
      equation 
        Debug.fprintln("failtrace", "#-- Inst.instExtGetFargsSingle failed for expression: " +& ExpressionDump.printExpStr(exp));
      then
        fail();
  end matchcontinue;
end instExtGetFargsSingle;

protected function instExtGetRettype 
"function: instExtGetRettype
  author: LS
  Instantiates the return type of an external declaration."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input SCode.ExternalDecl inExternalDecl;
  input Boolean inBoolean;
  input Prefix.Prefix inPrefix;
  input Absyn.Info info;
  output Env.Cache outCache;
  output DAE.ExtArg outExtArg;
algorithm 
  (outCache,outExtArg) := matchcontinue (inCache,inEnv,inExternalDecl,inBoolean,inPrefix,info)
    local
      DAE.Exp exp;
      DAE.Properties prop;
      DAE.ExtArg extarg;
      list<Env.Frame> env;
      Option<String> n,lang;
      Absyn.ComponentRef cref;
      list<Absyn.Exp> args;
      Boolean impl;
      Env.Cache cache;
      Prefix.Prefix pre;
      DAE.Attributes attr;

    case (cache,_,SCode.EXTERNALDECL(output_ = NONE()),_,_,_) then (cache,DAE.NOEXTARG());  /* impl */ 

    case (cache,env,SCode.EXTERNALDECL(funcName = n,lang = lang,output_ = SOME(cref),args = args),impl,pre,info)
      equation 
        (cache,SOME((exp,prop,attr))) = Static.elabCref(cache,env,cref,impl,false /* Do NOT vectorize arrays; we require a CREF */,pre,info);
        (cache,extarg) = instExtGetFargsSingle(cache,env,exp,prop);
        assertExtArgOutputIsCrefVariable(extarg,Types.getPropType(prop),Types.propAllConst(prop),info);
      then
        (cache,extarg);

    case (_,_,_,_,_,_)
      equation 
        Debug.fprintln("failtrace", "- Inst.instExtRettype failed");
      then
        fail();
  end matchcontinue;
end instExtGetRettype;

protected function assertExtArgOutputIsCrefVariable
  input DAE.ExtArg arg;
  input DAE.Type ty;
  input DAE.Const c;
  input Absyn.Info info;
algorithm
  _ := match (arg,ty,c,info)
    local
      String str;
    case (_,ty as (DAE.T_ARRAY(arrayType=_),_),_,_)
      equation
        str = Types.unparseType(ty);
        Error.addSourceMessage(Error.EXTERNAL_FUNCTION_RESULT_ARRAY_TYPE,{str},info);
      then fail();
    case (DAE.EXTARG(type_=_),_,DAE.C_VAR(),_) then ();
    case (arg,_,DAE.C_VAR(),info)
      equation
        str = DAEDump.dumpExtArgStr(arg);
        Error.addSourceMessage(Error.EXTERNAL_FUNCTION_RESULT_NOT_CREF,{str},info);
      then fail();
    else
      equation
        Error.addSourceMessage(Error.EXTERNAL_FUNCTION_RESULT_NOT_VAR,{},info);
      then fail();
  end match;
end assertExtArgOutputIsCrefVariable;

public function instEnumeration 
"function: instEnumeration
  author: PA
  This function takes an Ident and list of strings, and returns an enumeration class."
  input SCode.Ident n;
  input list<SCode.Enum> l;
  input Option<SCode.Comment> cmt;
  input Absyn.Info info;
  output SCode.Element outClass;
protected
  list<SCode.Element> comp;
algorithm 
  comp := makeEnumComponents(l, info);
  outClass := 
    SCode.CLASS(
     n,
     SCode.defaultPrefixes,
     SCode.NOT_ENCAPSULATED(),
     SCode.NOT_PARTIAL(),
     SCode.R_ENUMERATION(),
     SCode.PARTS(comp,{},{},{},{},NONE(),{},cmt),
     info);
end instEnumeration;

protected function makeEnumComponents
  "Translates a list of Enums to a list of elements of type EnumType."  
  input list<SCode.Enum> inEnumLst;
  input Absyn.Info info;
  output list<SCode.Element> outSCodeElementLst;
algorithm
  outSCodeElementLst := Util.listMap1(inEnumLst, SCode.makeEnumType, info);
end makeEnumComponents;

public function daeDeclare 
"function: daeDeclare 
  Given a global component name, a type, and a set of attributes, this function declares a component for the DAE result.  
  Altough this function returns a list of DAE.Element, only one component is actually declared.
  The functions daeDeclare2 and daeDeclare3 below are helper functions that perform parts of the task.
  Note: Currently, this function can only declare scalar variables, i.e. the element type of an array type is used. To indicate that the variable
  is an array, the InstDims attribute is used. This will need to be redesigned in the futurue, when array variables should not be flattened out in the frontend. 
  "
  input DAE.ComponentRef inComponentRef;
  input ClassInf.State inState;
  input DAE.Type inType;
  input SCode.Attributes inAttributes;
  input SCode.Visibility visibility;
  input Option<DAE.Exp> inExpExpOption;
  input InstDims inInstDims;
  input DAE.StartValue inStartValue;
  input Option<DAE.VariableAttributes> inDAEVariableAttributesOption;
  input Option<SCode.Comment> inAbsynCommentOption;
  input Absyn.InnerOuter io;
  input SCode.Final finalPrefix;
  input DAE.ElementSource source "the origin of the element";
  input Boolean declareComplexVars "if true, declare variables for complex variables, e.g. record vars in functions";
  output DAE.DAElist outDae;
algorithm 
  outDae := matchcontinue (inComponentRef,inState,inType,inAttributes,visibility,inExpExpOption,
                                     inInstDims,inStartValue,inDAEVariableAttributesOption,inAbsynCommentOption,
                                     io,finalPrefix,source,declareComplexVars )
    local
      DAE.Flow flowPrefix1;
      DAE.Stream streamPrefix1;
      DAE.DAElist dae;
      DAE.ComponentRef vn;
      ClassInf.State ci_state;
      DAE.Type ty;
      SCode.Flow flowPrefix;
      SCode.Stream streamPrefix;
      SCode.Visibility vis;
      SCode.Variability par;
      Absyn.Direction dir;
      Option<DAE.Exp> e,start;
      InstDims inst_dims;
      Option<DAE.VariableAttributes> dae_var_attr;
      Option<SCode.Comment> comment;
    
    case (vn,ci_state,ty,
          SCode.ATTR(flowPrefix = flowPrefix,
                     streamPrefix = streamPrefix,
                     variability = par,direction = dir),
          vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars )
      equation 
        flowPrefix1 = DAEUtil.toFlow(flowPrefix, ci_state);
        streamPrefix1 = DAEUtil.toStream(streamPrefix, ci_state);
        dae = daeDeclare2(vn, ty, flowPrefix1, streamPrefix1, par, dir, vis, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars );
      then
        dae;
    case (_,_,_,_,_,_,_,_,_,_,_,_,source,_)
      equation 
        Debug.fprintln("failtrace", "- Inst.daeDeclare failed");
      then
        fail();
  end matchcontinue;
end daeDeclare;

protected function daeDeclare2 
"function: daeDeclare2  
  Helper function to daeDeclare."
  input DAE.ComponentRef inComponentRef;
  input DAE.Type inType;
  input DAE.Flow inFlow;
  input DAE.Stream inStream;
  input SCode.Variability inVariability;
  input Absyn.Direction inDirection;
  input SCode.Visibility visibility;
  input Option<DAE.Exp> inExpExpOption;
  input InstDims inInstDims;
  input DAE.StartValue inStartValue;
  input Option<DAE.VariableAttributes> inDAEVariableAttributesOption;
  input Option<SCode.Comment> inAbsynCommentOption;
  input Absyn.InnerOuter io;
  input SCode.Final finalPrefix;
  input DAE.ElementSource source "the origin of the element";
  input Boolean declareComplexVars;
  output DAE.DAElist outDae;
algorithm 
  outDae := matchcontinue (inComponentRef,inType,inFlow,inStream,inVariability,inDirection,visibility,inExpExpOption,
                           inInstDims,inStartValue,inDAEVariableAttributesOption,inAbsynCommentOption,io,finalPrefix,
                           source,declareComplexVars)
    local
      DAE.DAElist dae;
      DAE.ComponentRef vn;
      DAE.Type ty;
      DAE.Flow flowPrefix;
      DAE.Stream streamPrefix;
      Absyn.Direction dir;
      Option<DAE.Exp> e,start;
      InstDims inst_dims;
      Option<DAE.VariableAttributes> dae_var_attr;
      Option<SCode.Comment> comment;
      SCode.Visibility vis;
      
    case (vn,ty,flowPrefix,streamPrefix,SCode.VAR(),dir,vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        dae = daeDeclare3(vn, ty, flowPrefix, streamPrefix, DAE.VARIABLE(), dir, vis, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars);
      then
        dae;
    case (vn,ty,flowPrefix,streamPrefix,SCode.DISCRETE(),dir,vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars )
      equation 
        dae = daeDeclare3(vn, ty, flowPrefix, streamPrefix, DAE.DISCRETE(), dir, vis, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars );
      then
        dae;
    case (vn,ty,flowPrefix,streamPrefix,SCode.PARAM(),dir,vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars )
      equation 
        dae = daeDeclare3(vn, ty, flowPrefix, streamPrefix, DAE.PARAM(), dir, vis, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars );
      then
        dae;
    case (vn,ty,flowPrefix,streamPrefix,SCode.CONST(),dir,vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars )
      equation 
        dae = daeDeclare3(vn, ty, flowPrefix, streamPrefix,DAE.CONST(), dir, vis, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars );
      then
        dae;
    case (_,_,_,_,_,_,_,_,_,_,_,_,_,_,source,_)
      equation 
        Debug.fprintln("failtrace", "- Inst.daeDeclare2 failed");
      then
        fail();
  end matchcontinue;
end daeDeclare2;

protected function daeDeclare3 
"function: daeDeclare3  
  Helper function to daeDeclare2."
  input DAE.ComponentRef inComponentRef;
  input DAE.Type inType;
  input DAE.Flow inFlow;
  input DAE.Stream inStream;
  input DAE.VarKind inVarKind;
  input Absyn.Direction inDirection;
  input SCode.Visibility visibility;
  input Option<DAE.Exp> inExpExpOption;
  input InstDims inInstDims;
  input DAE.StartValue inStartValue;
  input Option<DAE.VariableAttributes> inDAEVariableAttributesOption;
  input Option<SCode.Comment> inAbsynCommentOption;
  input Absyn.InnerOuter io;
  input SCode.Final finalPrefix;
  input DAE.ElementSource source "the origin of the element";
  input Boolean declareComplexVars;
  output DAE.DAElist outDae;
algorithm 
  outDae := match (inComponentRef,inType,inFlow,inStream,inVarKind,inDirection,visibility,inExpExpOption,inInstDims,
                   inStartValue,inDAEVariableAttributesOption,inAbsynCommentOption,io,finalPrefix,source,declareComplexVars)
    local
      DAE.DAElist dae;
      DAE.ComponentRef vn;
      DAE.Type ty;
      DAE.Flow fl;
      DAE.Stream st;
      DAE.VarKind vk;
      Option<DAE.Exp> e,start;
      InstDims inst_dims;
      Option<DAE.VariableAttributes> dae_var_attr;
      Option<SCode.Comment> comment;
      SCode.Visibility vis;
      DAE.VarVisibility prot1;
      
    case (vn,ty,fl,st,vk,Absyn.INPUT(),vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        prot1 = makeDaeProt(vis);
        dae = daeDeclare4(vn, ty, fl, st, vk, DAE.INPUT(),prot1, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars);
      then
        dae;
    case (vn,ty,fl,st,vk,Absyn.OUTPUT(),vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        prot1 = makeDaeProt(vis);
        dae = daeDeclare4(vn, ty, fl, st, vk, DAE.OUTPUT(),prot1, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars);
      then
        dae;
    case (vn,ty,fl,st,vk,Absyn.BIDIR(),vis,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        prot1 = makeDaeProt(vis);
        dae = daeDeclare4(vn, ty, fl, st, vk, DAE.BIDIR(),prot1, e, inst_dims, start, dae_var_attr, comment,io,finalPrefix,source,declareComplexVars);
      then
        dae;
    case (_,_,_,_,_,_,_,_,_,_,_,_,_,_,source,_)
      equation 
        //Debug.fprintln("failtrace", "- Inst.daeDeclare3 failed");
      then
        fail();
  end match;
end daeDeclare3;

protected function makeDaeProt 
"Creates a DAE.VarVisibility from a SCode.Visibility"
 input SCode.Visibility visibility;
 output DAE.VarVisibility res;
algorithm
  res := matchcontinue(visibility)
    case (SCode.PROTECTED()) then DAE.PROTECTED();
    case (SCode.PUBLIC()) then DAE.PUBLIC();
  end matchcontinue;
end makeDaeProt;

protected function daeDeclare4 
"function: daeDeclare4  
  Helper function to daeDeclare3."
  input DAE.ComponentRef inComponentRef;
  input DAE.Type inType;
  input DAE.Flow inFlow;
  input DAE.Stream inStream;
  input DAE.VarKind inVarKind;
  input DAE.VarDirection inVarDirection;
  input DAE.VarVisibility protection;
  input Option<DAE.Exp> inExpExpOption;
  input InstDims inInstDims;
  input DAE.StartValue inStartValue;
  input Option<DAE.VariableAttributes> inDAEVariableAttributesOption;
  input Option<SCode.Comment> inAbsynCommentOption;
  input Absyn.InnerOuter io;
  input SCode.Final finalPrefix;
  input DAE.ElementSource source "the origin of the element";
  input Boolean declareComplexVars;
  output DAE.DAElist outDAe;
algorithm 
  outDAe :=
  matchcontinue (inComponentRef,inType,inFlow,inStream,inVarKind,inVarDirection,protection,inExpExpOption,inInstDims,
                 inStartValue,inDAEVariableAttributesOption,inAbsynCommentOption,io,finalPrefix,source,declareComplexVars)
    local
      DAE.ComponentRef vn,c;
      DAE.Flow fl;
      DAE.Stream st;
      DAE.VarKind kind;
      DAE.VarDirection dir;
      Option<DAE.Exp> e,start;
      InstDims inst_dims;
      Option<DAE.VariableAttributes> dae_var_attr;
      Option<SCode.Comment> comment;
      list<String> l;
      DAE.DAElist dae;
      ClassInf.State ci;
      Integer dim;
      String s;
      DAE.Type ty,tp;
      DAE.VarVisibility prot;
      list<DAE.Subscript> finst_dims;
      Absyn.Path path;
      DAE.TType tty;

    case (vn,ty,fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars) 
      equation 
        // print("daeDeclare4: " +& ComponentReference.printComponentRefStr(vn) +& " " +& SCode.finalStr(finalPrefix) +& "\n");
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
      then 
        fail();

    case (vn,ty as(DAE.T_INTEGER(varLstInt = _),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars) 
      equation 
        finst_dims = Util.listFlatten(inst_dims);
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,DAE.T_INTEGER_DEFAULT,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
         
    case (vn,ty as(DAE.T_REAL(varLstReal = _),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        finst_dims = Util.listFlatten(inst_dims);
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,DAE.T_REAL_DEFAULT,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
         
    case (vn,ty as(DAE.T_BOOL(varLstBool = _),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars) 
      equation 
        finst_dims = Util.listFlatten(inst_dims);
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,DAE.T_BOOL_DEFAULT,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
         
    case (vn,ty as(DAE.T_STRING(varLstString = _),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars) 
      equation 
        finst_dims = Util.listFlatten(inst_dims);
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,DAE.T_STRING_DEFAULT,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
         
    case (vn,ty as(DAE.T_ENUMERATION(index = SOME(_)),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars) 
    then DAEUtil.emptyDae;
//    case (vn,ty as(DAE.T_ENUM(),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars) then {};

    /* We should not declare each enumeration value of an enumeration when instantiating,
     * e.g Myenum my !=> constant EnumType my.enum1,... {DAE.VAR(vn, kind, dir, DAE.ENUM, e, inst_dims)} 
     * instantiation of complex type extending from basic type 
     */ 
    case (vn,ty as(DAE.T_ENUMERATION(names = l),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        finst_dims = Util.listFlatten(inst_dims);
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,ty,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});

          /* Complex type that is ExternalObject*/
     case (vn, ty as (DAE.T_COMPLEX(complexClassType = ClassInf.EXTERNAL_OBJ(path)),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
       equation 
         finst_dims = Util.listFlatten(inst_dims);
         dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
       then DAE.DAE({DAE.VAR(vn,kind,dir,prot,ty,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
            
      /* instantiation of complex type extending from basic type */ 
    case (vn,(DAE.T_COMPLEX(complexClassType = ci,complexTypeOption = SOME(tp)),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation
        (_,dae_var_attr) = instDaeVariableAttributes(Env.emptyCache(),Env.emptyEnv, DAE.NOMOD(), tp, {});
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
        dae = daeDeclare4(vn,tp,fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars);
    then dae;
    
    /* Array that extends basic type */          
    case (vn,(DAE.T_ARRAY(arrayDim = DAE.DIM_INTEGER(integer = dim),arrayType = tp),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        dae = daeDeclare4(vn, tp, fl, st, kind, dir, prot,e, inst_dims, start, dae_var_attr,comment,io,finalPrefix,source,declareComplexVars);
      then dae;

    /* Arrays with unknown dimension are allowed if not expanded */
    case (vn,(DAE.T_ARRAY(arrayDim = _,arrayType = tp),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation
        false = RTOpts.splitArrays();
        dae = daeDeclare4(vn, tp, fl, st, kind, dir, prot,e, inst_dims, start, dae_var_attr,comment,io,finalPrefix,source,declareComplexVars);
      then dae;
        
    /* If arrays are expanded and dimension is unknown, report an error */
    case (vn,(DAE.T_ARRAY(arrayDim = DAE.DIM_UNKNOWN(),arrayType = tp),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation 
        true = RTOpts.splitArrays();
        s = ComponentReference.printComponentRefStr(vn);
        Error.addMessage(Error.DIMENSION_NOT_KNOWN, {s});
      then
        fail();
        
        /* Complex/Record components, only if declareComplexVars is true */
    case(vn,ty as (DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(_)),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,true)
      equation
        finst_dims = Util.listFlatten(inst_dims);
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,ty,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
     
    /* MetaModelica extensions */
    case (vn,(tty as DAE.T_FUNCTION(_,_,_),_),fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation
        finst_dims = Util.listFlatten(inst_dims);
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
        path = ComponentReference.crefToPath(vn);
        ty = (tty,SOME(path));
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,ty,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
    
    // MetaModelica extension
    case (vn,ty,fl,st,kind,dir,prot,e,inst_dims,start,dae_var_attr,comment,io,finalPrefix,source,declareComplexVars)
      equation
        true = RTOpts.acceptMetaModelicaGrammar();
        true = Types.isBoxedType(ty);
        finst_dims = Util.listFlatten(inst_dims);
        dae_var_attr = DAEUtil.setFinalAttr(dae_var_attr,SCode.finalBool(finalPrefix));
      then DAE.DAE({DAE.VAR(vn,kind,dir,prot,ty,e,finst_dims,fl,st,source,dae_var_attr,comment,io)});
    /*----------------------------*/
    
    case (c,ty,_,_,_,_,_,_,_,_,_,_,_,_,source,_)
      equation
        true = Types.isBoxedType(ty);
      then
        fail();
        
    case (c,ty,_,_,_,_,_,_,_,_,_,_,_,_,source,_) then DAEUtil.emptyDae;
  end matchcontinue;
end daeDeclare4;

protected function mktype
"function: mktype
  From a class typename, its inference state, and a list of subcomponents,
  this function returns DAE.Type.  If the class inference state
  indicates that the type should be a built-in type, one of the
  built-in type constructors is used.  Otherwise, a T_COMPLEX is
  built."
  input Absyn.Path inPath;
  input ClassInf.State inState;
  input list<DAE.Var> inTypesVarLst;
  input Option<DAE.Type> inTypesTypeOption;
  input DAE.EqualityConstraint inEqualityConstraint;
  input SCode.Element inClass;
  output DAE.Type outType;
algorithm
  outType := matchcontinue (inPath,inState,inTypesVarLst,inTypesTypeOption,inEqualityConstraint,inClass)
    local
      Option<Absyn.Path> somep;
      Absyn.Path p;
      list<DAE.Var> v,vl,l;
      DAE.Type bc2,functype,enumtype;
      ClassInf.State st;
      Option<DAE.Type> bc;
      SCode.Element cl;
      DAE.TType arrayType;
      DAE.Type resType;
      ClassInf.State classState;
      DAE.EqualityConstraint equalityConstraint;
      DAE.FunctionAttributes funcattr;
    
    case (p,ClassInf.TYPE_INTEGER(path = _),v,_,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_INTEGER(v),somep));
    case (p,ClassInf.TYPE_REAL(path = _),v,_,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_REAL(v),somep));
    case (p,ClassInf.TYPE_STRING(path = _),v,_,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_STRING(v),somep));
    case (p,ClassInf.TYPE_BOOL(path = _),v,_,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_BOOL(v),somep));
    case (p,ClassInf.TYPE_ENUM(path = _),_,_,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_ENUMERATION(NONE(), p,{},{},{}),somep));
    /* Insert function type construction here after checking input/output arguments? see Types.mo T_FUNCTION */
    case (p,(st as ClassInf.FUNCTION(path = _)),vl,_,_,cl)
      equation
        funcattr = getFunctionAttributes(cl,vl);
        functype = Types.makeFunctionType(p, vl, funcattr);
      then
        functype;
    case (_, ClassInf.ENUMERATION(path = p), _, SOME(enumtype), _, _)
      equation
        enumtype = Types.makeEnumerationType(p, enumtype);
      then
        enumtype;
    /* Array of type extending from base type. */
    case (_, ClassInf.TYPE(path = _), _, SOME((DAE.T_ARRAY(_, (arrayType, _)), _)), _, _)
      equation
        classState = arrayTTypeToClassInfState(arrayType);
        resType = mktype(inPath, classState, inTypesVarLst, inTypesTypeOption, inEqualityConstraint, inClass);
      then resType;

    /* MetaModelica extension */
    case (p,ClassInf.META_TUPLE(_),_,SOME(bc2),_,_) then bc2;
    case (p,ClassInf.META_OPTION(_),_,SOME(bc2),_,_) then bc2;
    case (p,ClassInf.META_LIST(_),_,SOME(bc2),_,_) then bc2;
    case (p,ClassInf.META_POLYMORPHIC(_),_,SOME(bc2),_,_) then bc2;
    case (p,ClassInf.META_ARRAY(_),_,SOME(bc2),_,_) then bc2;
    case (p,ClassInf.UNIONTYPE(_),_,SOME(bc2),_,_) then bc2;
    case (p,ClassInf.UNIONTYPE(_),_,_,_,_)
      equation
        Error.addMessage(Error.META_UNIONTYPE_ALIAS_MODS, {});
      then fail();
    /*------------------------*/

    case (p,st,l,bc,equalityConstraint,_)
      equation
        failure(ClassInf.UNIONTYPE(_) = st);
        somep = getOptPath(p);
      then
        ((DAE.T_COMPLEX(st,l,bc,equalityConstraint),somep));
  end matchcontinue;
end mktype;

protected function arrayTTypeToClassInfState
  input DAE.TType arrayType;
  output ClassInf.State classInfState;
algorithm
  classInfState := match(arrayType)
    local
      DAE.TType t;
      ClassInf.State cs;
    case (DAE.T_INTEGER(_)) then ClassInf.TYPE_INTEGER(Absyn.IDENT(""));
    case (DAE.T_REAL(_)) then ClassInf.TYPE_REAL(Absyn.IDENT(""));
    case (DAE.T_STRING(_)) then ClassInf.TYPE_STRING(Absyn.IDENT(""));
    case (DAE.T_BOOL(_)) then ClassInf.TYPE_BOOL(Absyn.IDENT(""));
    case (DAE.T_ARRAY(arrayType = (t, _)))
      equation
        cs = arrayTTypeToClassInfState(t);
      then cs;
  end match;
end arrayTTypeToClassInfState;

protected function mktypeWithArrays
"function: mktypeWithArrays
  author: PA
  This function is similar to mktype with the exception
  that it will create array types based on the last argument,
  which indicates wheter the class extends from a basictype.
  It is used only in the inst_class_basictype function."
  input Absyn.Path inPath;
  input ClassInf.State inState;
  input list<DAE.Var> inTypesVarLst;
  input Option<DAE.Type> inTypesTypeOption;
  input SCode.Element inClass;
  output DAE.Type outType;
algorithm
  outType := matchcontinue (inPath,inState,inTypesVarLst,inTypesTypeOption,inClass)
    local
      Absyn.Path p;
      ClassInf.State ci,st;
      list<DAE.Var> vs,v,vl,l;
      DAE.Type tp,functype,enumtype;
      Option<Absyn.Path> somep;
      SCode.Element cl;
      Option<DAE.Type> bc;
      DAE.FunctionAttributes funcattr;
    
    case (p,ci,vs,SOME(tp),_)
      equation
        true = Types.isArray(tp);
        failure(ClassInf.isConnector(ci));
      then
        tp;
    case (p,ClassInf.TYPE_INTEGER(path = _),v,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_INTEGER(v),somep));
    case (p,ClassInf.TYPE_REAL(path = _),v,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_REAL(v),somep));
    case (p,ClassInf.TYPE_STRING(path = _),v,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_STRING(v),somep));
    case (p,ClassInf.TYPE_BOOL(path = _),v,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_BOOL(v),somep));
    case (p,ClassInf.TYPE_ENUM(path = _),_,_,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_ENUMERATION(NONE(), p,{},{},{}),somep));
//        ((DAE.T_ENUM(),somep));
    /* Insert function type construction here after checking input/output arguments? see Types.mo T_FUNCTION */
    case (p,(st as ClassInf.FUNCTION(path = _)),vl,_,cl)
      equation
        funcattr = getFunctionAttributes(cl,vl);
        functype = Types.makeFunctionType(p, vl, funcattr);
      then
        functype;
    case (p, ClassInf.ENUMERATION(path = _), _, SOME(enumtype), _)
      equation
        enumtype = Types.makeEnumerationType(p, enumtype);
      then
        enumtype;
    case (p,st,l,bc,_)
      equation
        somep = getOptPath(p);
      then
        ((DAE.T_COMPLEX(st,l,bc,NONE()/* HN ??? */),somep));

    case (p,st,l,bc,_)
      equation
        print("Inst.mktypeWithArrays failed\n");
      then fail();

  end matchcontinue;
end mktypeWithArrays;

protected function getOptPath
"function: getOptPath
  Helper function to mktype
  Transforms a Path into a Path option."
  input Absyn.Path inPath;
  output Option<Absyn.Path> outAbsynPathOption;
algorithm
  outAbsynPathOption := matchcontinue (inPath)
    local Absyn.Path p;
    case Absyn.IDENT(name = "") then NONE();
    case p then SOME(p);
  end matchcontinue;
end getOptPath;

public function instList
"function: instList
  This is a utility used to do instantiation of list
  of things, collecting the result in another list."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input DAE.Mod inMod;
  input Prefix.Prefix inPrefix;
  input Connect.Sets inSets;
  input ClassInf.State inState;
  input InstFunc instFunc;
  input list<Type_a> inTypeALst;
  input Boolean inBoolean;
  input Boolean unrollForLoops "we should unroll for loops if they are part of an algorithm in a model";
  input ConnectionGraph.ConnectionGraph inGraph;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
  output Connect.Sets outSets;
  output ClassInf.State outState;
  output ConnectionGraph.ConnectionGraph outGraph;
  partial function InstFunc
    input Env.Cache inCache;
    input Env.Env inEnv;
    input InstanceHierarchy inIH;
    input DAE.Mod inMod;
    input Prefix.Prefix inPrefix;
    input Connect.Sets inSets;
    input ClassInf.State inState;
    input Type_a inTypeA;
    input Boolean inBoolean;
    input Boolean unrollForLoops "we should unroll for loops if they are part of an algorithm in a model";
    input ConnectionGraph.ConnectionGraph inGraph;
    output Env.Cache outCache;
    output Env.Env outEnv;
    output InstanceHierarchy outIH;
    output DAE.DAElist outDAe;
    output Connect.Sets outSets;
    output ClassInf.State outState;
    output ConnectionGraph.ConnectionGraph outGraph;
    replaceable type Type_a subtypeof Any;
  end InstFunc;
  replaceable type Type_a subtypeof Any;
algorithm
  (outCache,outEnv,outIH,outDae,outSets,outState,outGraph):=
  match (inCache,inEnv,inIH,inMod,inPrefix,inSets,inState,instFunc,inTypeALst,inBoolean,unrollForLoops,inGraph)
    local
      list<Env.Frame> env,env_1,env_2;
      DAE.Mod mod;
      Prefix.Prefix pre;
      Connect.Sets csets,csets_1,csets_2;
      ClassInf.State ci_state,ci_state_1,ci_state_2;
      Boolean impl;
      DAE.DAElist dae1,dae2,dae;
      Type_a e;
      list<Type_a> es;
      Env.Cache cache;
      ConnectionGraph.ConnectionGraph graph;
      InstanceHierarchy ih;
      
    case (cache,env,ih,mod,pre,csets,ci_state,_,{},impl,unrollForLoops,graph) 
      then (cache,env,ih,DAEUtil.emptyDae,csets,ci_state,graph);
         
    case (cache,env,ih,mod,pre,csets,ci_state,_,(e :: es),impl,unrollForLoops,graph)
      equation
        (cache,env_1,ih,dae1,csets_1,ci_state_1,graph) = instFunc(cache, env, ih, mod, pre, csets, ci_state, e, impl, unrollForLoops, graph);
        (cache,env_2,ih,dae2,csets_2,ci_state_2,graph) = instList(cache, env_1, ih, mod, pre, csets_1, ci_state_1, instFunc, es, impl, unrollForLoops, graph);
        dae = DAEUtil.joinDaes(dae1, dae2);
      then
        (cache,env_2,ih,dae,csets_2,ci_state_2,graph);
  end match;
end instList;

protected function instBinding
"function: instBinding
  This function investigates a modification and extracts the
  <...> modification. E.g. Real x(<...>=1+3) => 1+3
  It also handles the case Integer T0[2](final <...>={5,6})={9,10} becomes
  Integer T0[1](<...>=5); Integer T0[2](<...>=6);

   If no modifier is given it also investigates the type to check for binding there.
   I.e. type A = Real(start=1); A a; will set the start attribute since it's found in the type.

  Arg 1 is the modification
  Arg 2 are the type variables.
  Arg 3 is the expected type that the modification should have
  Arg 4 is the index list for the element: for T0{1,2} is {1,2}"
  input DAE.Mod inMod;
  input list<DAE.Var> varLst;
  input DAE.Type inType;
  input list<Integer> inIntegerLst;
  input String inString;
  input Boolean useConstValue "if true use constant value present in TYPED (if present)";
  output Option<DAE.Exp> outExpExpOption;
algorithm
  outExpExpOption := matchcontinue (inMod,varLst,inType,inIntegerLst,inString,useConstValue)
    local
      DAE.Mod mod2,mod;
      DAE.Exp e,e_1;
      DAE.Type ty2,ty_1,expected_type,etype;
      String bind_name;
      Option<DAE.Exp> result;
      list<Integer> index_list;
      DAE.Binding binding;
      Ident name;
      Option<Values.Value> optVal;
    
    case (mod,varLst,expected_type,{},bind_name,useConstValue) /* No subscript/index */
      equation
        mod2 = Mod.lookupCompModification(mod, bind_name);
        SOME(DAE.TYPED(e,optVal,DAE.PROP(ty2,_),_)) = Mod.modEquation(mod2);
        (e_1,ty_1) = Types.matchType(e, ty2, expected_type, true);
        e_1 = checkUseConstValue(useConstValue,e_1,optVal);
      then
        SOME(e_1);
    
    case (mod,varLst,etype,index_list,bind_name,useConstValue) /* Have subscript/index */
      equation
        mod2 = Mod.lookupCompModification(mod, bind_name);
        result = instBinding2(mod2, etype, index_list, bind_name,useConstValue);
      then
        result;
    
    case (mod,varLst,expected_type,{},bind_name,useConstValue) /* No modifier for this name. */
      equation
        failure(_ = Mod.lookupCompModification(mod, bind_name));
      then
        NONE();
    
    case (mod,DAE.TYPES_VAR(name,binding=binding)::_,etype,index_list,bind_name,useConstValue) 
      equation
        true = stringEq(name, bind_name);
      then 
        bindingExp(binding);
    
    case (mod,_::varLst,etype,index_list,bind_name,useConstValue)
    then instBinding(mod,varLst,etype,index_list,bind_name,useConstValue);
    
    case (mod,{},etype,index_list,bind_name,useConstValue)
    then NONE();
  end matchcontinue;
end instBinding;

protected function bindingExp
"help function to instBinding, returns the expression of a binding"
input DAE.Binding bind;
output Option<DAE.Exp> exp;
algorithm
  exp := match(bind)
  local DAE.Exp e; Values.Value v;
    case(DAE.UNBOUND()) then NONE();
    case(DAE.EQBOUND(exp=e)) then SOME(e);
    case(DAE.VALBOUND(valBound=v)) equation
      e = ValuesUtil.valueExp(v);
    then SOME(e);
  end match;
end bindingExp;

protected function instBinding2
"function: instBinding2
  This function investigates a modification and extracts the <...>
  modification if the modification is in array of components.
  Help-function to instBinding"
  input DAE.Mod inMod;
  input DAE.Type inType;
  input list<Integer> inIntegerLst;
  input String inString;
  input Boolean useConstValue "if true, use constant value in TYPED (if present)";
  output Option<DAE.Exp> outExpExpOption;
algorithm
  outExpExpOption:=
  matchcontinue (inMod,inType,inIntegerLst,inString,useConstValue)
    local
      DAE.Mod mod2,mod;
      DAE.Exp e,e_1;
      DAE.Type ty2,ty_1,etype;
      Integer index;
      String bind_name;
      Option<DAE.Exp> result;
      list<Integer> res;
      Option<Values.Value> optVal;
    case (mod,etype,(index :: {}),bind_name,useConstValue) /* Only one element in the index-list */
      equation
        mod2 = Mod.lookupIdxModification(mod, index);
        SOME(DAE.TYPED(e,optVal,DAE.PROP(ty2,_),_)) = Mod.modEquation(mod2);
        (e_1,ty_1) = Types.matchType(e, ty2, etype, true);
        e_1 = checkUseConstValue(useConstValue,e_1,optVal);
      then
        SOME(e_1);
    case (mod,etype,(index :: res),bind_name,useConstValue) /* Several elements in the index-list */
      equation
        mod2 = Mod.lookupIdxModification(mod, index);
        result = instBinding2(mod2, etype, res, bind_name,useConstValue);
      then
        result;
    case (mod,etype,(index :: res),bind_name,useConstValue)
      equation
        failure(mod2 = Mod.lookupIdxModification(mod, index));
      then
        NONE();
    case (_,_,_,_,_)
      then fail();
  end matchcontinue;
end instBinding2;

protected function instStartBindingExp
"function: instStartBindingExp
  This function investigates a modification and extracts the
  start modification. E.g. Real x(start=1+3) => 1+3
  It also handles the case Integer T0{2}(final start={5,6})={9,10} becomes
  Integer T0{1}(start=5); Integer T0{2}(start=6);

  Arg 1 is the start modification
  Arg 2 is the expected type that the modification should have
  Arg 3 is variability of the element"
  input DAE.Mod inMod;
  input DAE.Type inExpectedType;
  input SCode.Variability inVariability;
  output DAE.StartValue outStartValue;
protected 
  DAE.Type eltType;
algorithm
  outStartValue := match(inMod, inExpectedType, inVariability)
    local
      DAE.Type element_ty;
      DAE.StartValue start_val;

    case (_, _, SCode.CONST()) then NONE();

    else
      equation
        element_ty = Types.arrayElementType(inExpectedType);
        // When instantiating arrays, the array type is passed
        // But binding is performed on the element type.
        // Also removed index, since indexing is already performed on the modifier.
        start_val = instBinding(inMod, {}, element_ty, {}, "start", false);
      then
        start_val;

  end match;
end instStartBindingExp;

protected function instDaeVariableAttributes
"function: instDaeVariableAttributes
  this function extracts the attributes from the modification
  It returns a DAE.VariableAttributes option because
  somtimes a varible does not contain the variable-attr."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Mod inMod;
  input DAE.Type inType;
  input list<Integer> inIntegerLst;
  output Env.Cache outCache;
  output Option<DAE.VariableAttributes> outDAEVariableAttributesOption;
algorithm
  (outCache,outDAEVariableAttributesOption) :=
  matchcontinue (inCache,inEnv,inMod,inType,inIntegerLst)
    local
      Option<DAE.Exp> quantity_str,unit_str,displayunit_str,nominal_val,fixed_val,exp_bind_select,exp_bind_min,exp_bind_max,exp_bind_start,min_val,max_val,start_val;
      Option<DAE.StateSelect> stateSelect_value;
      list<Env.Frame> env;
      DAE.Mod mod;
      Option<Absyn.Path> path;
      list<Integer> index_list;
      DAE.Type enumtype;
      Env.Cache cache;
      DAE.Type tp;
      list<DAE.Var> varLst;
    /* Real */
    case (cache,env,mod,tp as (DAE.T_REAL(varLstReal = varLst),path),index_list)
      equation
        (quantity_str) = instBinding(mod, varLst, DAE.T_STRING_DEFAULT,index_list, "quantity",false);
        (unit_str) = instBinding( mod, varLst, DAE.T_STRING_DEFAULT, index_list, "unit",false);
        (displayunit_str) = instBinding(mod, varLst,DAE.T_STRING_DEFAULT, index_list, "displayUnit",false);
        (min_val) = instBinding( mod, varLst, DAE.T_REAL_DEFAULT,index_list, "min",false);
        (max_val) = instBinding(mod, varLst, DAE.T_REAL_DEFAULT,index_list, "max",false);
        (start_val) = instBinding(mod, varLst, DAE.T_REAL_DEFAULT,index_list, "start",false);
        (fixed_val) = instBinding( mod, varLst, DAE.T_BOOL_DEFAULT,index_list, "fixed",false);
        (nominal_val) = instBinding(mod, varLst, DAE.T_REAL_DEFAULT,index_list, "nominal",false);
        
        (cache,exp_bind_select) = instEnumerationBinding(cache,env, mod, varLst, index_list, "stateSelect",stateSelectType,true);
        (stateSelect_value) = getStateSelectFromExpOption(exp_bind_select);
        //TODO: check for protected attribute (here and below matches)
      then
        (cache,SOME(
          DAE.VAR_ATTR_REAL(quantity_str,unit_str,displayunit_str,(min_val,max_val),
          start_val,fixed_val,nominal_val,stateSelect_value,NONE(),NONE(),NONE())));
    /* Integer */
    case (cache,env,mod,tp as (DAE.T_INTEGER(varLstInt = varLst),_),index_list)
      equation
        (quantity_str) = instBinding(mod, varLst, DAE.T_STRING_DEFAULT, index_list, "quantity",false);
        (min_val) = instBinding(mod, varLst, DAE.T_INTEGER_DEFAULT, index_list, "min",false);
        (max_val) = instBinding(mod, varLst, DAE.T_INTEGER_DEFAULT, index_list, "max",false);
        (start_val) = instBinding(mod, varLst, DAE.T_INTEGER_DEFAULT, index_list, "start",false);
        (fixed_val) = instBinding(mod, varLst, DAE.T_BOOL_DEFAULT,index_list, "fixed",false);
      then
        (cache,SOME(DAE.VAR_ATTR_INT(quantity_str,(min_val,max_val),start_val,fixed_val,NONE(),NONE(),NONE())));
    /* Boolean */
    case (cache,env,mod,tp as (DAE.T_BOOL(varLstBool = varLst),_),index_list)
      equation
        (quantity_str) = instBinding( mod, varLst, DAE.T_STRING_DEFAULT, index_list, "quantity",false);
        (start_val) = instBinding(mod, varLst, tp, index_list, "start",false);
        (fixed_val) = instBinding(mod, varLst, tp, index_list, "fixed",false);
      then
        (cache,SOME(DAE.VAR_ATTR_BOOL(quantity_str,start_val,fixed_val,NONE(),NONE(),NONE())));
    /* String */
    case (cache,env,mod,tp as (DAE.T_STRING(varLstString = varLst),_),index_list)
      equation
        (quantity_str) = instBinding(mod, varLst, tp, index_list, "quantity",false);
        (start_val) = instBinding(mod, varLst, tp, index_list, "start",false);
      then
        (cache,SOME(DAE.VAR_ATTR_STRING(quantity_str,start_val,NONE(),NONE(),NONE())));
    /* Enumeration */
    case (cache,env,mod,(enumtype as (DAE.T_ENUMERATION(attributeLst=varLst),_)),index_list)
      equation
        (quantity_str) = instBinding(mod, varLst, DAE.T_STRING_DEFAULT,index_list, "quantity",false);
        (exp_bind_min) = instBinding(mod, varLst, enumtype, index_list, "min",false);
        (exp_bind_max) = instBinding(mod, varLst, enumtype, index_list, "max",false);
        (exp_bind_start) = instBinding(mod, varLst, enumtype, index_list, "start",false);
        (fixed_val) = instBinding( mod, varLst, DAE.T_BOOL_DEFAULT, index_list, "fixed",false);
      then
        (cache,SOME(DAE.VAR_ATTR_ENUMERATION(quantity_str,(exp_bind_min,exp_bind_max),exp_bind_start,fixed_val,NONE(),NONE(),NONE())));
    case (cache,env,mod,_,_)
      then (cache,NONE());
  end matchcontinue;
end instDaeVariableAttributes;

protected function instBoolBinding
"function instBoolBinding
  author: LP
  instantiates a bool binding and retrieves the value.
  FIXME: check the type of variable for the fixed because
         there is a difference between parameters and variables."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Mod inMod;
  input list<DAE.Var> varLst;
  input list<Integer> inIntegerLst;
  input String inString;
  output Env.Cache outCache;
  output Option<Boolean> outBooleanOption;
algorithm
  (outCache,outBooleanOption) := matchcontinue (inCache,inEnv,inMod,varLst,inIntegerLst,inString)
    local
      DAE.Exp e;
      Boolean result;
      list<Env.Frame> env;
      DAE.Mod mod;
      list<Integer> index_list;
      String bind_name;
      Env.Cache cache;
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod,varLst, DAE.T_BOOL_DEFAULT, index_list, bind_name,false);
        (cache,Values.BOOL(result),_) = Ceval.ceval(cache,env, e, false,NONE(), NONE(), Ceval.NO_MSG());
      then
        (cache,SOME(result));
    /* Non constant expression return NONE() */
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod, varLst,DAE.T_BOOL_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        NONE() = instBinding(mod, varLst, DAE.T_BOOL_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        Error.addMessage(Error.TYPE_ERROR, {bind_name,"Boolean"});
      then
        fail();
  end matchcontinue;
end instBoolBinding;

protected function instRealBinding
"function: instRealBinding
  author: LP
  instantiates a real binding and retrieves the value."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Mod inMod;
  input list<DAE.Var> varLst;
  input list<Integer> inIntegerLst;
  input String inString;
  output Env.Cache outCache;
  output Option<Real> outRealOption;
algorithm
  (outCache,outRealOption) := matchcontinue (inCache,inEnv,inMod,varLst,inIntegerLst,inString)
    local
      DAE.Exp e;
      Real result;
      list<Env.Frame> env;
      DAE.Mod mod;
      list<Integer> index_list;
      String bind_name;
      Env.Cache cache;
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod, varLst, DAE.T_REAL_DEFAULT, index_list, bind_name,false);
        (cache,Values.REAL(result),_) = Ceval.ceval(cache,env, e, false,NONE(), NONE(), Ceval.NO_MSG());
      then
        (cache,SOME(result));
    /* non constant expression, return NONE() */
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod, varLst,DAE.T_REAL_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        NONE() = instBinding(mod, varLst,DAE.T_REAL_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        Error.addMessage(Error.TYPE_ERROR, {bind_name,"Real"});
      then
        fail();
  end matchcontinue;
end instRealBinding;

protected function instIntBinding
"function: instIntBinding
  author: LP
  instantiates an int binding and retrieves the value."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Mod inMod;
  input list<DAE.Var> varLst;
  input list<Integer> inIntegerLst;
  input String inString;
  output Env.Cache outCache;
  output Option<Integer> outIntegerOption;
algorithm
  (outCache,outIntegerOption) := matchcontinue (inCache,inEnv,inMod,varLst,inIntegerLst,inString)
    local
      DAE.Exp e;
      Integer result;
      list<Env.Frame> env;
      DAE.Mod mod;
      list<Integer> index_list;
      String bind_name;
      Env.Cache cache;
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod, varLst, DAE.T_INTEGER_DEFAULT, index_list, bind_name,false);
        (cache,Values.INTEGER(result),_) = Ceval.ceval(cache,env, e, false,NONE(), NONE(), Ceval.NO_MSG());
      then
        (cache,SOME(result));
    /* got non-constant expression, return NONE() */
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod, varLst,DAE.T_INTEGER_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        NONE() = instBinding(mod, varLst,DAE.T_INTEGER_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        Error.addMessage(Error.TYPE_ERROR, {bind_name,"Integer"});
      then
        fail();
  end matchcontinue;
end instIntBinding;

protected function instStringBinding
"function: instStringBinding
  author: LP
  instantiates a string binding and retrieves the value."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Mod inMod;
  input list<DAE.Var> varLst;
  input list<Integer> inIntegerLst;
  input String inString;
  output Env.Cache outCache;
  output Option<String> outStringOption;
algorithm
  (outCache,outStringOption) :=
  matchcontinue (inCache,inEnv,inMod,varLst,inIntegerLst,inString)
    local
      DAE.Exp e;
      String result,bind_name;
      list<Env.Frame> env;
      DAE.Mod mod;
      list<Integer> index_list;
      Env.Cache cache;
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod, varLst,DAE.T_STRING_DEFAULT, index_list, bind_name,false);
        (cache,Values.STRING(result),_) = Ceval.ceval(cache,env, e, false,NONE(), NONE(), Ceval.NO_MSG());
      then
        (cache,SOME(result));
    /* Non constant expression return NONE() */
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        SOME(e) = instBinding(mod, varLst,DAE.T_STRING_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        NONE() = instBinding(mod, varLst,DAE.T_STRING_DEFAULT, index_list, bind_name,false);
      then
        (cache,NONE());
    case (cache,env,mod,varLst,index_list,bind_name)
      equation
        Error.addMessage(Error.TYPE_ERROR, {bind_name,"String"});
      then
        fail();
  end matchcontinue;
end instStringBinding;

protected function instEnumerationBinding
"function: instEnumerationBinding
  author: LP
  instantiates a enumeration binding and retrieves the value."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input DAE.Mod inMod;
  input list<DAE.Var> varLst;
  input list<Integer> inIntegerLst;
  input String inString;
  input DAE.Type expected_type;
  input Boolean useConstValue "if true, use constant value in TYPED (if present)";
  output Env.Cache outCache;
  output Option<DAE.Exp> outExpExpOption;
algorithm
  (outCache,outExpExpOption) := matchcontinue (inCache,inEnv,inMod,varLst,inIntegerLst,inString,expected_type,useConstValue)
    local
      Option<DAE.Exp> result;
      list<Env.Frame> env;
      DAE.Mod mod;
      list<Integer> index_list;
      String bind_name;
      Env.Cache cache;
      
    case (cache,env,mod,varLst,index_list,bind_name,expected_type,useConstValue)
      equation       
        result = instBinding(mod, varLst, expected_type, index_list, bind_name,useConstValue);
      then
        (cache,result);
        
    case (cache,env,mod,varLst,index_list,bind_name,expected_type,useConstValue)
      equation
        Error.addMessage(Error.TYPE_ERROR, {bind_name,"enumeration type"});
      then
        fail();
  end matchcontinue;
end instEnumerationBinding;

protected function getStateSelectFromExpOption
"function: getStateSelectFromExpOption
  author: LP
  Retrieves the stateSelect value, as defined in DAE,  from an Expression option."
  input Option<DAE.Exp> inExpExpOption;
  output Option<DAE.StateSelect> outDAEStateSelectOption;
algorithm
  outDAEStateSelectOption:=
  matchcontinue (inExpExpOption)
    case (SOME(DAE.ENUM_LITERAL(name = Absyn.QUALIFIED("StateSelect", path = Absyn.IDENT("never"))))) then SOME(DAE.NEVER());
    case (SOME(DAE.ENUM_LITERAL(name = Absyn.QUALIFIED("StateSelect", path = Absyn.IDENT("avoid"))))) then SOME(DAE.AVOID());
    case (SOME(DAE.ENUM_LITERAL(name = Absyn.QUALIFIED("StateSelect", path = Absyn.IDENT("default"))))) then SOME(DAE.DEFAULT());
    case (SOME(DAE.ENUM_LITERAL(name = Absyn.QUALIFIED("StateSelect", path = Absyn.IDENT("prefer"))))) then SOME(DAE.PREFER());
    case (SOME(DAE.ENUM_LITERAL(name = Absyn.QUALIFIED("StateSelect", path = Absyn.IDENT("always"))))) then SOME(DAE.ALWAYS());
    case (NONE()) then NONE();
    case (_) then NONE();
  end matchcontinue;
end getStateSelectFromExpOption;

protected function instModEquation
"function: instModEquation
  This function adds the equation in the declaration
  of a variable, if such an equation exists."
  input DAE.ComponentRef inComponentRef;
  input DAE.Type inType;
  input DAE.Mod inMod;
  input DAE.ElementSource source "the origin of the element";
  input Boolean inBoolean;
  output DAE.DAElist outDae;
algorithm
  outDae:= matchcontinue (inComponentRef,inType,inMod,source,inBoolean)
    local
      DAE.ExpType t;
      DAE.DAElist dae;
      DAE.ComponentRef cr,c;
      DAE.Type ty1;
      DAE.Mod mod,m;
      DAE.Exp e,lhs;
      DAE.Properties prop2;
      Boolean impl;

    // Record constructors are different
    // If it's a constant binding, all fields will already be bound correctly. Don't return a DAE.
    case (cr,(DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(_)),_),(DAE.MOD(eqModOption = SOME(DAE.TYPED(e,_,DAE.PROP(_,DAE.C_CONST()),_)))),source,impl)
      then DAEUtil.emptyDae;
    
    // Special case if the dimensions of the expression is 0.
    // If this is true, and it is instantiated normally, matching properties
    // will result in error messages (Real[0] is not Real), so we handle it here.      
    case (cr,ty1,(mod as DAE.MOD(eqModOption = SOME(DAE.TYPED(e,_,prop2,_)))),source,impl)
      equation
        ((DAE.T_ARRAY(arrayDim = DAE.DIM_INTEGER(0)),_)) = Types.getPropType(prop2);
      then
        DAEUtil.emptyDae;
    
    // Regular cases
    case (cr,ty1,(mod as DAE.MOD(eqModOption = SOME(DAE.TYPED(e,_,prop2,_)))),source,impl)
      equation
        t = Types.elabType(ty1);
        lhs = Expression.makeCrefExp(cr, t);
        dae = InstSection.instEqEquation(lhs, DAE.PROP(ty1,DAE.C_VAR()), e, prop2, source, SCode.NON_INITIAL(), impl);
      then
        dae;
    
    case (_,_,DAE.MOD(eqModOption = NONE()),_,impl) then DAEUtil.emptyDae;
    case (_,_,DAE.NOMOD(),_,impl) then DAEUtil.emptyDae;
    case (_,_,DAE.REDECL(finalPrefix = _),_,impl) then DAEUtil.emptyDae;
    
    case (c,ty1,m,source,impl)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprint("failtrace", "- Inst.instModEquation failed\n type: ");
        Debug.fprint("failtrace", Types.printTypeStr(ty1));
        Debug.fprint("failtrace", "\n  cref: ");
        Debug.fprint("failtrace", ComponentReference.printComponentRefStr(c));
        Debug.fprint("failtrace", "\n mod:");
        Debug.fprint("failtrace", Mod.printModStr(m));
        Debug.fprint("failtrace", "\n");
      then
        fail();
  end matchcontinue;
end instModEquation;

protected function checkProt
"function: checkProt
  This function is used to check that a
  protected element is not modified."
  input SCode.Visibility inVisibility;
  input DAE.Mod inMod;
  input DAE.ComponentRef inComponentRef;
algorithm
  _ := matchcontinue (inVisibility,inMod,inComponentRef)
    local
      DAE.ComponentRef cref;
      String str;
    case (SCode.PUBLIC(),_,cref) then ();
    case (_,DAE.NOMOD(),_) then ();
    case (SCode.PROTECTED(),_,cref)
      equation
        str = ComponentReference.printComponentRefStr(cref);
        Error.addMessage(Error.MODIFY_PROTECTED, {str});
      then
        fail();
  end matchcontinue;
end checkProt;

public function makeBinding
"function: makeBinding
  This function looks at the equation part of a modification, and
  if there is a declaration equation builds a DAE.Binding for it."
  input Env.Cache inCache;
  input Env.Env inEnv;
  input SCode.Attributes inAttributes;
  input DAE.Mod inMod;
  input DAE.Type inType;
  input Prefix.Prefix inPrefix;
  input String componentName;
  input Absyn.Info info;
  output Env.Cache outCache;
  output DAE.Binding outBinding;
algorithm
  (outCache,outBinding) := matchcontinue (inCache,inEnv,inAttributes,inMod,inType,inPrefix,componentName,info)
    local
      DAE.Type tp,e_tp;
      DAE.Exp e_1,e;
      Option<Values.Value> e_val;
      DAE.Const c;
      String e_tp_str,tp_str,e_str,e_str_1,str;
      Env.Cache cache;
      DAE.Properties prop;
      DAE.Binding binding;
      DAE.Mod startValueModification;
      list<DAE.Var> complex_vars;
      Absyn.Path tpath;
      list<DAE.SubMod> sub_mods;

    case (cache,_,_,DAE.NOMOD(),tp,_,_,_) then (cache,DAE.UNBOUND());
    case (cache,_,_,DAE.REDECL(finalPrefix = _),tp,_,_,_) then (cache,DAE.UNBOUND());

    // adrpo: if the binding is missing for a parameter and 
    //        the parameter has a start value modification, 
    //        use that to create the binding as if we have 
    //        a modification from outside it will be re-written.
    //        this fixes: 
    //             Modelica.Electrical.Machines.Examples.SMEE_Generator 
    //             (BUG: #1156 at https://openmodelica.org:8443/cb/issue/1156)
    //             and maybe a lot others.
    case (cache,_,SCode.ATTR(variability = SCode.PARAM()),inMod as DAE.MOD(eqModOption = NONE()),tp,inPrefix,componentName,_)
      equation
        startValueModification = Mod.lookupCompModification(inMod, "start");
        (cache,binding) = makeBinding(cache,inEnv,inAttributes,startValueModification,inType,inPrefix,componentName,info);
        binding = DAEUtil.setBindingSource(binding, DAE.BINDING_FROM_START_VALUE());
      then 
        (cache,binding);

    // A record might have bindings for each component instead of a single
    // binding for the whole record, in which case we need to assemble them into
    // a binding.
    case (cache, _, _, DAE.MOD(subModLst = sub_mods as _ :: _), _, _, _, _)
      equation
        ((DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(path = tpath),
           complexVarLst = complex_vars), _)) = Types.arrayElementType(inType);
        binding = makeRecordBinding(tpath, inType, complex_vars, sub_mods, info);
      then
        (cache, binding);
        
    case (cache,_,_,DAE.MOD(eqModOption = NONE()),tp,_,_,_) then (cache,DAE.UNBOUND());
    /* adrpo: CHECK! do we need this here? numerical values
    case (cache,env,_,DAE.MOD(eqModOption = SOME(DAE.TYPED(e,_,DAE.PROP(e_tp,_)))),tp,_,_)
      equation
        (e_1,_) = Types.matchType(e, e_tp, tp);
        (cache,v,_) = Ceval.ceval(cache,env, e_1, false,NONE(), NONE(), Ceval.NO_MSG());
      then
        (cache,DAE.VALBOUND(v, DAE.BINDING_FROM_DEFAULT_VALUE()));
    */
    case (cache,_,_,DAE.MOD(eqModOption = SOME(DAE.TYPED(e,e_val,prop,_))),tp,_,_,_) /* default */
      equation
        e_tp = Types.getPropType(prop);
        c = Types.propAllConst(prop);
        (e_1,_) = Types.matchType(e, e_tp, tp, true);
        (e_1,_) = ExpressionSimplify.simplify(e_1);
      then
        (cache,DAE.EQBOUND(e_1,e_val,c,DAE.BINDING_FROM_DEFAULT_VALUE()));
    case (cache,_,_,DAE.MOD(eqModOption = SOME(DAE.TYPED(e,e_val,prop,_))),tp,_,_,_)
      equation
        e_tp = Types.getPropType(prop);
        c = Types.propAllConst(prop);
        (e_1,_) = Types.matchType(e, e_tp, tp, false);
      then
        (cache,DAE.EQBOUND(e_1,e_val,c,DAE.BINDING_FROM_DEFAULT_VALUE()));
    case (cache,_,_,DAE.MOD(eqModOption = SOME(DAE.TYPED(e,e_val,prop,_))),tp,inPrefix,componentName,_)
      equation
        e_tp = Types.getPropType(prop);
        c = Types.propAllConst(prop);
        failure((_,_) = Types.matchType(e, e_tp, tp, false));
        e_tp_str = Types.unparseType(e_tp);
        tp_str = Types.unparseType(tp);
        e_str = ExpressionDump.printExpStr(e);
        e_str_1 = stringAppend("=", e_str);
        str = PrefixUtil.printPrefixStrIgnoreNoPre(inPrefix) +& "." +& componentName;
        Error.addSourceMessage(Error.MODIFIER_TYPE_MISMATCH_ERROR, {str,tp_str,e_str_1,e_tp_str}, info);
      then
        fail();
    case (_,_,_,_,_,inPrefix,componentName,_)
      equation
        Debug.fprint("failtrace", "- Inst.makeBinding failed on component:" +& PrefixUtil.printPrefixStr(inPrefix) +& "." +& componentName +& "\n");
      then
        fail();
  end matchcontinue;
end makeBinding;

protected function makeRecordBinding
  "Creates a binding for a record given a list of submodifiers. This is the case
   when a record is given a binding by modifiers, ex:
    
     record R
       Real x; Real y;
     end R;

     constant R r(x = 2.0, y = 3.0);

  This is translated to:
     constant R r = R(2.0, 3.0);

  This is needed when we assign a record to another record.
  "
  input Absyn.Path inRecordName;
  input DAE.Type inRecordType;
  input list<DAE.Var> inRecordVars;
  input list<DAE.SubMod> inMods;
  input Absyn.Info inInfo;
  output DAE.Binding outBinding;
algorithm
  outBinding := makeRecordBinding2(inRecordName, inRecordType, inRecordVars,
    inMods, inInfo, {}, {}, {});
end makeRecordBinding;

protected function makeRecordBinding2
  "Helper function to makeRecordBinding. Goes through each record component and
  finds out it's binding, and at the end it assembles a single binding from
  these components."
  input Absyn.Path inRecordName;
  input DAE.Type inRecordType;
  input list<DAE.Var> inRecordVars;
  input list<DAE.SubMod> inMods;
  input Absyn.Info inInfo;
  input list<DAE.Exp> inAccumExps;
  input list<Values.Value> inAccumVals;
  input list<String> inAccumNames;
  output DAE.Binding outBinding;
algorithm
  outBinding := matchcontinue(inRecordName, inRecordType, inRecordVars, inMods,
      inInfo, inAccumExps, inAccumVals, inAccumNames)
    local
      DAE.ExpType ety;
      DAE.Exp exp;
      Values.Value val;
      list<DAE.Var> rest_vars;
      list<DAE.SubMod> sub_mods;
      String name;
      DAE.Binding binding;
      Option<DAE.SubMod> opt_mod;

    // No more components, assemble the binding.
    case (_, _, {}, _, _, _, _, _)
      equation
        inAccumExps = listReverse(inAccumExps);
        inAccumVals = listReverse(inAccumVals);
        inAccumNames = listReverse(inAccumNames);

        ety = Types.elabType(Types.arrayElementType(inRecordType));
        exp = DAE.CALL(inRecordName, inAccumExps, false, false, ety, 
          DAE.NORM_INLINE());
        val = Values.RECORD(inRecordName, inAccumVals, inAccumNames, -1);
        (exp, val) = liftRecordBinding(inRecordType, exp, val);
        binding = DAE.EQBOUND(exp, SOME(val), DAE.C_CONST(), 
          DAE.BINDING_FROM_DEFAULT_VALUE());
      then
        binding;

    // Take the first component and look for a submod that gives it a binding.
    case (_, _, DAE.TYPES_VAR(name = name) :: rest_vars, sub_mods, _, _, _, _)
      equation
        (sub_mods, opt_mod) =
          Util.listDeleteMemberOnTrue(name, sub_mods, isSubModNamed);
        (exp, val) = makeRecordBinding3(opt_mod, inRecordType, inInfo);
        binding = makeRecordBinding2(inRecordName, inRecordType, rest_vars, sub_mods, 
          inInfo, exp :: inAccumExps, val :: inAccumVals, name :: inAccumNames);
      then
        binding;

    // If the previous case fails, check if the component already has a binding.
    case (_, _, DAE.TYPES_VAR(name = name, binding = DAE.EQBOUND(exp = exp, 
        evaluatedExp = SOME(val))) :: rest_vars, sub_mods, _, _, _, _)
      equation
        binding = makeRecordBinding2(inRecordName, inRecordType, rest_vars, sub_mods, 
          inInfo, exp :: inAccumExps, val :: inAccumVals, name :: inAccumNames);
      then
        binding;

    case (_, _, DAE.TYPES_VAR(name = name) :: _, _, _, _, _, _)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.traceln("- Inst.makeRecordBinding2 failed for " +&
          Absyn.pathString(inRecordName) +& "." +& name +& "\n");
      then
        fail();

  end matchcontinue;
end makeRecordBinding2;

protected function makeRecordBinding3
  "Helper function to makeRecordBinding2. Fetches the binding expression and
  value from an optional submod."
  input Option<DAE.SubMod> inSubMod;
  input DAE.Type inType;
  input Absyn.Info inInfo;
  output DAE.Exp outExp;
  output Values.Value outValue;
algorithm
  (outExp, outValue) := match(inSubMod, inType, inInfo)
    local
      DAE.Exp exp;
      Values.Value val;

    case (_, _, _) then fail();

    // Array type and each prefix => return the expression and value.
    case (SOME(DAE.NAMEMOD(mod = DAE.MOD(eachPrefix = SCode.EACH(), eqModOption = 
        SOME(DAE.TYPED(modifierAsExp = exp, modifierAsValue = SOME(val)))))),
        (DAE.T_ARRAY(arrayDim = _), _), _)
      then (exp, val);

    // Array type and no each prefix => need to split the expression and value.
    case (SOME(DAE.NAMEMOD(mod = DAE.MOD(eachPrefix = SCode.NOT_EACH()))),
        (DAE.T_ARRAY(arrayDim = _), _), _)
      equation
        Error.addSourceMessage(Error.INTERNAL_ERROR, 
          {"Inst.makeRecordBinding3: array modifier not yet implemented."}, inInfo);
      then
        fail();

    // Scalar type and no each prefix => return the expression and value.
    case (SOME(DAE.NAMEMOD(mod = DAE.MOD(eachPrefix = SCode.NOT_EACH(), eqModOption = 
        SOME(DAE.TYPED(modifierAsExp = exp, modifierAsValue = SOME(val)))))), _, _)
      then (exp, val);
  end match;
end makeRecordBinding3;
    
protected function isSubModNamed
  "Returns true if the given submod is a namemod with the same name as the given
  name, otherwise false."
  input String inName;
  input DAE.SubMod inSubMod;
  output Boolean isNamed;
algorithm
  isNamed := matchcontinue(inName, inSubMod)
    local
      String submod_name;

    case (_, DAE.NAMEMOD(ident = submod_name))
      then stringEqual(inName, submod_name);

    else then false;
  end matchcontinue;
end isSubModNamed;

protected function liftRecordBinding
  "If the type is an array type this function creates an array of the given
  record, otherwise it just returns the input arguments."
  input DAE.Type inType;
  input DAE.Exp inExp;
  input Values.Value inValue;
  output DAE.Exp outExp;
  output Values.Value outValue;
algorithm
  (outExp, outValue) := matchcontinue(inType, inExp, inValue)
    local
      DAE.Dimension dim;
      DAE.Type ty;
      DAE.Exp exp;
      Values.Value val;
      DAE.ExpType ety;
      Integer int_dim;
      list<DAE.Exp> expl;
      list<Values.Value> vals;

    case ((DAE.T_ARRAY(arrayDim = dim, arrayType = ty), _), _, _)
      equation
        int_dim = Expression.dimensionSize(dim);
        (exp, val) = liftRecordBinding(ty, inExp, inValue);
        ety = Types.elabType(inType);
        expl = Util.listFill(exp, int_dim);
        vals = Util.listFill(val, int_dim);
        exp = DAE.ARRAY(ety, true, expl);
        val = Values.ARRAY(vals, {int_dim});
      then
        (exp, val);

    else
      equation
        false = Types.isArray(inType);
      then
        (inExp, inValue);
  end matchcontinue;
end liftRecordBinding;

public function instRecordConstructorElt
"function: instRecordConstructorElt
  author: PA
  This function takes an Env and an Element and builds a input argument to
  a record constructor.
  E.g if the element is Real x; the resulting Var is \"input Real x;\""
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Element inElement;
  input DAE.Mod outerMod;
  input Boolean inImplicit;
  output Env.Cache outCache;
  output InstanceHierarchy outIH;
  output DAE.Var outVar;
algorithm
  (outCache,outIH,outVar) := 
  matchcontinue (inCache,inEnv,inIH,inElement,outerMod,inImplicit)
    local
      SCode.Element cl;
      list<Env.Frame> cenv,env;
      DAE.Mod mod_1;
      Absyn.ComponentRef owncref;
      list<DAE.Dimension> dimexp;
      DAE.Type tp_1;
      DAE.Binding bind;
      String id,str;
      SCode.Replaceable repl;
      SCode.Visibility vis;
      SCode.Flow f;
      SCode.Stream s;
      Boolean impl;
      SCode.Attributes attr;
      list<Absyn.Subscript> dim;
      SCode.Variability var;
      Absyn.Direction dir;
      Absyn.Path t;
      SCode.Mod mod;
      Option<SCode.Comment> comment;
      SCode.Element elt;
      Env.Cache cache;
      Absyn.InnerOuter io;
      SCode.Final finalPrefix;
      Absyn.Info info;
      InstanceHierarchy ih;
      Option<Absyn.ConstrainClass> cc;
      SCode.Prefixes prefixes;

    case (cache,env,ih,
          SCode.COMPONENT(name = id,
                          prefixes = prefixes as SCode.PREFIXES(
                            replaceablePrefix = repl,
                            visibility = vis,
                            finalPrefix = finalPrefix,
                            innerOuter = io
                          ),
                          attributes = (attr as 
                          SCode.ATTR(arrayDims = dim,flowPrefix = f,streamPrefix=s,
                                     variability = var,direction = dir)),
                          typeSpec = Absyn.TPATH(t, _),modifications = mod,
                          comment = comment,
                          info = info),
          outerMod,impl)
      equation
        // - Prefixes (constant, parameter, final, discrete, input, output, ...) of the remaining record components are removed.
        var = SCode.VAR();
        dir = Absyn.INPUT();
        attr = SCode.ATTR(dim,f,s,var,dir);

        //Debug.fprint("recconst", "inst_record_constructor_elt called\n");
        (cache,cl,cenv) = Lookup.lookupClass(cache,env, t, true);
        //Debug.fprint("recconst", "looked up class\n");
        (cache,mod_1) = Mod.elabMod(cache, env, ih, Prefix.NOPRE(), mod, impl, info);
        mod_1 = Mod.merge(outerMod,mod_1,cenv,Prefix.NOPRE());
        owncref = Absyn.CREF_IDENT(id,{});
        (cache,dimexp) = elabArraydim(cache, env, owncref, t, dim, NONE(), false, NONE(), true, false, Prefix.NOPRE(), info, {});
        //Debug.fprint("recconst", "calling inst_var\n");
        (cache,_,ih,_,_,_,tp_1,_) = instVar(cache, cenv, ih, UnitAbsyn.noStore, ClassInf.FUNCTION(Absyn.IDENT("")), mod_1, Prefix.NOPRE(),
          Connect.emptySet, id, cl, attr, prefixes, dimexp, {}, {}, impl, comment, info, ConnectionGraph.EMPTY, env);
        //Debug.fprint("recconst", "Type of argument:");
        Debug.fprint("recconst", Types.printTypeStr(tp_1));
        //Debug.fprint("recconst", "\nMod=");
        Debug.fcall("recconst", Mod.printMod, mod_1);
        (cache,bind) = makeBinding(cache,env, attr, mod_1, tp_1, Prefix.NOPRE(), id, info);
      then
        (cache,ih,DAE.TYPES_VAR(id,DAE.ATTR(f,s,var,dir,Absyn.NOT_INNER_OUTER()),vis,tp_1,bind,NONE()));

    case (cache,env,ih,elt,outerMod,impl)
      equation
        true = RTOpts.debugFlag("failtrace");
        Debug.fprint("failtrace", "- Inst.instRecordConstructorElt failed.,elt:");
        str = SCodeDump.printElementStr(elt);
        Debug.fprint("failtrace", str);
        Debug.fprint("failtrace", "\n");
      then
        fail();
  end matchcontinue;
end instRecordConstructorElt;

protected function isTopCall
"function: isTopCall
  author: PA
  The topmost instantiation call is treated specially with for instance unconnected connectors.
  This function returns true if the CallingScope indicates the top call."
  input CallingScope inCallingScope;
  output Boolean outBoolean;
algorithm
  outBoolean:=
  match (inCallingScope)
    case TOP_CALL() then true;
    case INNER_CALL() then false;
  end match;
end isTopCall;

public function instantiateBoschClass "
Author BZ 2008-06,
Instantiate a class, but _allways_ as inner class. This due to that we do not want flow equations equal to zero.
Called from Interactive.mo, boschsection.
"
  input Env.Cache inCache;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDAElist;
algorithm
  (outCache,outEnv,outIH,outDAElist) :=
  matchcontinue (inCache,inIH,inProgram,inPath)
    local
      Absyn.Path cr,path;
      list<Env.Frame> env,env_1,env_2;
      DAE.DAElist dae1,dae;
      list<SCode.Element> cdecls;
      String name2,n,pathstr,name,cname_str;
      SCode.Element cdef;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,ih,{},cr)
      equation
        Error.addMessage(Error.NO_CLASSES_LOADED, {});
      then
        fail();

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.IDENT(name = name2))) /* top level class */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,dae1) = instClassDecls(cache,env,ih, cdecls, path);
        (cache,env_2,ih,dae) = instBoschClassInProgram(cache,env_1,ih, cdecls, path);
      then
        (cache,env_2,ih,dae);

    case (cache,ih,(cdecls as (_ :: _)),(path as Absyn.QUALIFIED(name = name))) /* class in package */
      equation
        (cache,env) = Builtin.initialEnv(cache);
        (cache,env_1,ih,_) = instClassDecls(cache,env,ih, cdecls, path);
        (cache,(cdef as SCode.CLASS(name = n)),env_2) = Lookup.lookupClass(cache,env_1, path, true);
        (cache,env_2,ih,_,dae,_,_,_,_,_) =
          instClass(cache,env_2,ih,UnitAbsyn.noStore, DAE.NOMOD(), Prefix.NOPRE(),
            Connect.emptySet, cdef, {}, false, INNER_CALL(), ConnectionGraph.EMPTY) "impl" ;
        pathstr = Absyn.pathString(path);
      then
        (cache,env_2,ih,dae);

    case (cache,ih,cdecls,path) /* error instantiating */
      equation
        cname_str = Absyn.pathString(path);
        Error.addMessage(Error.ERROR_FLATTENING, {cname_str});
      then
        fail();
  end matchcontinue;
end instantiateBoschClass;

protected function instBoschClassInProgram
"Helper function for instantiateBoschClass"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input SCode.Program inProgram;
  input SCode.Path inPath;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output DAE.DAElist outDae;
algorithm
  (outCache,outEnv,outIH,outDae):=
  matchcontinue (inCache,inEnv,inIH,inProgram,inPath)
    local
      DAE.DAElist dae;
      list<Env.Frame> env_1,env;
      SCode.Element c;
      String name1,name2;
      list<SCode.Element> cs;
      Absyn.Path path;
      Env.Cache cache;
      InstanceHierarchy ih;

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),Absyn.IDENT(name = name2))
      equation
        true = stringEq(name1, name2);
        (cache,env_1,ih,_,dae,_,_,_,_,_) =
          instClass(cache,env,ih, UnitAbsyn.noStore, DAE.NOMOD(), Prefix.NOPRE(), Connect.emptySet, c, 
                    {}, false, INNER_CALL(), ConnectionGraph.EMPTY) "impl" ;
      then
        (cache,env_1,ih,dae);

    case (cache,env,ih,((c as SCode.CLASS(name = name1)) :: cs),(path as Absyn.IDENT(name = name2)))
      equation
        false = stringEq(name1, name2);
        (cache,env,ih,dae) = instBoschClassInProgram(cache,env,ih, cs, path);
      then
        (cache,env,ih,dae);

    case (cache,env,ih,{},_) then (cache,env,ih,DAEUtil.emptyDae);

    case (cache,env,ih,_,_)
      /* //Debug.fprint(\"failtrace\", \"inst_class_in_program failed\\n\") */
      then fail();
  end matchcontinue;
end instBoschClassInProgram;

protected function extractCurrentName
"function: extractCurrentName
 Extracts SCode.Element name."
  input SCode.Element sele;
  output String ostring;
  output Absyn.Info oinfo;
algorithm
  (ostring ,oinfo) := match(sele)
    local
      Absyn.Path path;
      String name,ret;
      Absyn.Import imp;
      Absyn.Info info;

    case(SCode.CLASS(name = name, info = info)) then (name, info);
    case(SCode.COMPONENT(name = name, info=info)) then (name, info);      
    case(SCode.EXTENDS(baseClassPath=path))
      equation
        ret = Absyn.pathString(path);
      then 
        (ret, Absyn.dummyInfo);
    case(SCode.IMPORT(imp = imp, info = info))
      equation 
        name = Absyn.printImportString(imp);
      then 
        (name, info);
  end match;
end extractCurrentName;

protected function orderConnectEquationsPutNonExpandableFirst
"@author: adrpo
  Reorder the connect equations to have non-expandable connect first:
    connect(non_expandable, non_expandable);
    connect(non_expandable, expandable);
    connect(expandable, non_expandable);
    connect(expandable, expandable);"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPre;
  input list<SCode.Equation> inEquations;
  input Boolean impl;
  output Env.Cache outCache;
  output list<SCode.Equation> outEquations;
algorithm
  (outCache,outEquations) := matchcontinue(inCache, inEnv, inIH, inPre, inEquations, impl)
    local 
      list<SCode.Equation> equations, rest;
      SCode.Equation eq;
      Absyn.ComponentRef crefLeft, crefRight;
      Env.Cache cache;
      Absyn.Info info;
    
    // if we have no expandable connectors, return the same   
    case (cache, inEnv, inIH, inPre, eq::rest, _)
      equation
        false = System.getHasExpandableConnectors();
        equations = inEquations;
      then 
        (cache, equations);
    
    // handle empty case
    case (cache, inEnv, inIH, inPre, {}, _) then (cache, {});
    
    // connect, both expandable
    case (cache, inEnv, inIH, inPre, (eq as SCode.EQUATION(SCode.EQ_CONNECT(crefLeft, crefRight, _, info)))::rest, impl)
      equation
        // type of left var is an expandable connector!
        (cache,SOME((DAE.CREF(ty=DAE.ET_COMPLEX(complexClassType=ClassInf.CONNECTOR(_, true))),_,_))) = 
            Static.elabCref(cache, inEnv, crefLeft, impl, false, inPre,info);
        // type of right left var is an expandable connector!
        (cache,SOME((DAE.CREF(ty=DAE.ET_COMPLEX(complexClassType=ClassInf.CONNECTOR(_, true))),_,_))) = 
            Static.elabCref(cache, inEnv, crefRight, impl, false, inPre,info);
        (cache, equations) = orderConnectEquationsPutNonExpandableFirst(cache, inEnv, inIH, inPre, rest, impl);
        equations = listAppend(equations, {eq});
      then
        (cache, equations);
    
    // anything else, put at the begining (keep the order)
    case (cache, inEnv, inIH, inPre, eq::rest, impl)
      equation
        (cache, equations) = orderConnectEquationsPutNonExpandableFirst(cache, inEnv, inIH, inPre, rest, impl);
      then
        (cache, eq::equations);
  end matchcontinue;
end orderConnectEquationsPutNonExpandableFirst;

protected function sortInnerFirstTplLstElementMod
"@author: adrpo
  This function will move all the *inner* 
  elements first in the given list of elements"
  input list<tuple<SCode.Element, DAE.Mod>> inTplLstElementMod;
  output list<tuple<SCode.Element, DAE.Mod>> outTplLstElementMod;
algorithm
  outTplLstElementMod := matchcontinue(inTplLstElementMod)
    local
      list<tuple<SCode.Element, DAE.Mod>> innerElts, innerouterElts, otherElts, sorted;

    // no sorting if we don't have any inner/outer in the model
    case (inTplLstElementMod) 
      equation
        false = System.getHasInnerOuterDefinitions();
      then
        inTplLstElementMod;

    // do sorting only if we have inner-outer
    case (inTplLstElementMod)
      equation
        // split into inner, inner outer and other elements
        (innerElts, innerouterElts, otherElts) = splitInnerAndOtherTplLstElementMod(inTplLstElementMod);
        // put the inner elements first
        sorted = listAppend(innerElts, innerouterElts);
        // put the innerouter elements second
        sorted = listAppend(sorted, otherElts);
      then 
        sorted;
  end matchcontinue;
end sortInnerFirstTplLstElementMod;

public function splitInnerAndOtherTplLstElementMod 
"@author: adrpo
  Split the elements into inner, inner outer and others"
  input list<tuple<SCode.Element, DAE.Mod>> inTplLstElementMod;
  output list<tuple<SCode.Element, DAE.Mod>> outInnerTplLstElementMod;
  output list<tuple<SCode.Element, DAE.Mod>> outInnerOuterTplLstElementMod;
  output list<tuple<SCode.Element, DAE.Mod>> outOtherTplLstElementMod;
algorithm
  (outInnerTplLstElementMod, outInnerOuterTplLstElementMod, outOtherTplLstElementMod) := matchcontinue (inTplLstElementMod)
    local
      list<tuple<SCode.Element, DAE.Mod>> rest,innerComps,innerouterComps,otherComps;
      tuple<SCode.Element, DAE.Mod> comp;
      Absyn.InnerOuter io;

    // empty case
    case ({}) then ({},{},{});

    // inner components
    case ( ( comp as (SCode.COMPONENT(name=_,prefixes=SCode.PREFIXES(innerOuter = io)), _) ) :: rest)
      equation
        true = Absyn.isInner(io);
        false = Absyn.isOuter(io);
        (innerComps,innerouterComps,otherComps) = splitInnerAndOtherTplLstElementMod(rest);
      then
        (comp::innerComps,innerouterComps,otherComps);
        
    // inner outer components
    case ( ( comp as (SCode.COMPONENT(name=_,prefixes=SCode.PREFIXES(innerOuter = io)), _) ) :: rest)
      equation
        true = Absyn.isInner(io);
        true = Absyn.isOuter(io);
        (innerComps,innerouterComps,otherComps) = splitInnerAndOtherTplLstElementMod(rest);
      then
        (innerComps,comp::innerouterComps,otherComps);

    // any other components
    case (comp :: rest)
      equation
        (innerComps,innerouterComps,otherComps) = splitInnerAndOtherTplLstElementMod(rest);
      then
        (innerComps,innerouterComps,comp::otherComps);
  end matchcontinue;
end splitInnerAndOtherTplLstElementMod;

public function splitEltsOrderInnerOuter "
This function splits the Element list into four lists
1. Class definitions , imports and defineunits
2. Class-extends class definitions
3. Extends elements
4. Components which are ordered by inner/outer, inner first"
  input list<SCode.Element> elts;
  output list<SCode.Element> cdefImpElts;
  output list<SCode.Element> classextendsElts;
  output list<SCode.Element> extElts;
  output list<SCode.Element> compElts;
algorithm
  (cdefImpElts,classextendsElts,extElts,compElts) := matchcontinue (elts)
    local
      list<SCode.Element> innerComps,otherComps,comps;
      SCode.Element cdef,imp,ext;
      Absyn.InnerOuter io;

    case (elts)
      equation
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(elts);
        // put inner elements first in the list of
        // elements so they are instantiated first!
        comps = listAppend(innerComps, otherComps);
      then
        (cdefImpElts,classextendsElts,extElts,comps);
  end matchcontinue;
end splitEltsOrderInnerOuter;

public function splitElts "
This function splits the Element list into four lists
1. Class definitions , imports and defineunits
2. Class-extends class definitions
3. Extends elements
4. Components"
  input list<SCode.Element> elts;
  output list<SCode.Element> cdefImpElts;
  output list<SCode.Element> classextendsElts;
  output list<SCode.Element> extElts;
  output list<SCode.Element> compElts;
algorithm
  (cdefImpElts,classextendsElts,extElts,compElts) := matchcontinue (elts)
    local
      list<SCode.Element> comps,xs;
      SCode.Element cdef,imp,ext,comp;

    // empty case
    case ({}) then ({},{},{},{});

    // class definitions with class extends
    case ((cdef as SCode.CLASS(classDef = SCode.CLASS_EXTENDS(baseClassName = _)))::xs)
      equation
        (cdefImpElts,classextendsElts,extElts,comps) = splitElts(xs);
      then
        (cdefImpElts,cdef :: classextendsElts,extElts,comps);

    // class definitions without class extends
    case (((cdef as SCode.CLASS(name = _)) :: xs))
      equation
        (cdefImpElts,classextendsElts,extElts,comps) = splitElts(xs);
      then
        (cdef :: cdefImpElts,classextendsElts,extElts,comps);
        
    // imports
    case (((imp as SCode.IMPORT(imp = _)) :: xs))
      equation
        (cdefImpElts,classextendsElts,extElts,comps) = splitElts(xs);
      then
        (imp :: cdefImpElts,classextendsElts,extElts,comps);
        
    // units
    case (((imp as SCode.DEFINEUNIT(name = _)) :: xs))
      equation
        (cdefImpElts,classextendsElts,extElts,comps) = splitElts(xs);
      then
        (imp :: cdefImpElts,classextendsElts,extElts,comps);
        
    // extends elements
    case((ext as SCode.EXTENDS(baseClassPath =_))::xs)
      equation
        (cdefImpElts,classextendsElts,extElts,comps) = splitElts(xs);
      then
        (cdefImpElts,classextendsElts,ext::extElts,comps);

    // components
    case ((comp as SCode.COMPONENT(name=_)) :: xs)
      equation
        (cdefImpElts,classextendsElts,extElts,comps) = splitElts(xs);
      then
        (cdefImpElts,classextendsElts,extElts,comp::comps);
  end matchcontinue;
end splitElts;

public function splitEltsNoComponents "
This function splits the Element list into these categories:
1. Imports
2. Define units and class definitions
3. Class-extends class definitions
4. Filtered class extends and imports"
  input list<SCode.Element> elts;
  output list<SCode.Element> impElts;
  output list<SCode.Element> defElts;
  output list<SCode.Element> classextendsElts;
  output list<SCode.Element> filtered;
algorithm
  (impElts,defElts,classextendsElts,filtered) := matchcontinue (elts)
    local
      list<SCode.Element> xs;
      SCode.Element elt;

    // empty case
    case ({}) then ({},{},{},{});

    // class definitions with class extends
    case ((elt as SCode.CLASS(classDef = SCode.CLASS_EXTENDS(baseClassName = _)))::xs)
      equation
        (impElts,defElts,classextendsElts,filtered) = splitEltsNoComponents(xs);
      then
        (impElts,defElts,elt::classextendsElts,filtered);

    // class definitions without class extends
    case (((elt as SCode.CLASS(name = _)) :: xs))
      equation
        (impElts,defElts,classextendsElts,filtered) = splitEltsNoComponents(xs);
      then
        (impElts,elt::defElts,classextendsElts,elt::filtered);
        
    // imports
    case (((elt as SCode.IMPORT(imp = _)) :: xs))
      equation
        (impElts,defElts,classextendsElts,filtered) = splitEltsNoComponents(xs);
      then
        (elt::impElts,defElts,classextendsElts,filtered);
        
    // units
    case (((elt as SCode.DEFINEUNIT(name = _)) :: xs))
      equation
        (impElts,defElts,classextendsElts,filtered) = splitEltsNoComponents(xs);
      then
        (impElts,elt::defElts,classextendsElts,elt::filtered);
        
    // extends and components elements
    case (elt::xs)
      equation
        (impElts,defElts,classextendsElts,filtered) = splitEltsNoComponents(xs);
      then
        (impElts,defElts,classextendsElts,elt::filtered);

  end matchcontinue;
end splitEltsNoComponents;

public function splitEltsInnerAndOther "
 @author: adrpo
  Splits elements into these categories:
  1. Class definitions, imports and defineunits
  2. Class-extends class definitions
  3. Extends elements
  4. Inner Components
  5. Any Other Components"
  input list<SCode.Element> elts;
  output list<SCode.Element> cdefImpElts;
  output list<SCode.Element> classextendsElts;
  output list<SCode.Element> extElts;
  output list<SCode.Element> innerCompElts;
  output list<SCode.Element> otherCompElts;
algorithm
  (cdefImpElts,classextendsElts,extElts,innerCompElts,otherCompElts) := matchcontinue (elts)
    local
      list<SCode.Element> res,xs,innerComps,otherComps;
      SCode.Element cdef,imp,ext,comp;
      Absyn.InnerOuter io;

    // empty case
    case ({}) then ({},{},{},{},{});

    // class definitions with class extends
    case ((cdef as SCode.CLASS(classDef = SCode.CLASS_EXTENDS(baseClassName = _)))::xs)
      equation
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(xs);
      then
        (cdefImpElts,cdef :: classextendsElts,extElts,innerComps,otherComps);

    // class definitions without class extends
    case (((cdef as SCode.CLASS(name = _)) :: xs))
      equation
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(xs);
      then
        (cdef :: cdefImpElts,classextendsElts,extElts,innerComps,otherComps);
        
    // imports
    case (((imp as SCode.IMPORT(imp = _)) :: xs))
      equation
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(xs);
      then
        (imp :: cdefImpElts,classextendsElts,extElts,innerComps,otherComps);
        
    // units
    case (((imp as SCode.DEFINEUNIT(name = _)) :: xs))
      equation
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(xs);
      then
        (imp :: cdefImpElts,classextendsElts,extElts,innerComps,otherComps);
        
    // extends elements
    case((ext as SCode.EXTENDS(baseClassPath =_))::xs)
      equation
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(xs);
      then
        (cdefImpElts,classextendsElts,ext::extElts,innerComps,otherComps);

    // inner components
    case ((comp as SCode.COMPONENT(name=_,prefixes = SCode.PREFIXES(innerOuter = io))) :: xs)
      equation
        true = Absyn.isInner(io);
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(xs);
      then
        (cdefImpElts,classextendsElts,extElts,comp::innerComps,otherComps);

    // any other components
    case ((comp as SCode.COMPONENT(name=_) ):: xs)
      equation
        (cdefImpElts,classextendsElts,extElts,innerComps,otherComps) = splitEltsInnerAndOther(xs);
      then
        (cdefImpElts,classextendsElts,extElts,innerComps,comp::otherComps);
  end matchcontinue;
end splitEltsInnerAndOther;

protected function orderComponents
"@author: adrpo
 this functions puts the component in front of the list if
 is inner or innerouter and at the end of the list otherwise"
  input SCode.Element inComp;
  input list<SCode.Element> inCompElts;
  output list<SCode.Element> outCompElts;
algorithm
  outCompElts := matchcontinue(inComp, inCompElts)
    local
      list<SCode.Element> compElts;

    // input/output come first!
    case (SCode.COMPONENT(name=_,attributes = SCode.ATTR(direction = Absyn.INPUT())), inCompElts)
      then inComp::inCompElts;
    case (SCode.COMPONENT(name=_,attributes = SCode.ATTR(direction = Absyn.OUTPUT())), inCompElts)
      then inComp::inCompElts;
    // put inner/outer in front.
    case (SCode.COMPONENT(name=_,prefixes = SCode.PREFIXES(innerOuter = Absyn.INNER())), inCompElts)
      then inComp::inCompElts;
    case (SCode.COMPONENT(name=_,prefixes = SCode.PREFIXES(innerOuter = Absyn.INNER_OUTER())), inCompElts)
      then inComp::inCompElts;
    // put constants in front
    case (SCode.COMPONENT(name=_,attributes = SCode.ATTR(variability = SCode.CONST())), inCompElts)
      then inComp::inCompElts;
    // put parameters in front
    case (SCode.COMPONENT(name=_,attributes = SCode.ATTR(variability = SCode.PARAM())), inCompElts)
      then inComp::inCompElts;
    // all other append to the end.
    case (SCode.COMPONENT(name=_), inCompElts)
      equation
        compElts = listAppend(inCompElts, {inComp});
      then compElts;
  end matchcontinue;
end orderComponents;

protected function splitClassExtendsElts
"This function splits the Element list into two lists
1. Class-extends class definitions
2. Any other element"
  input list<SCode.Element> elts;
  output list<SCode.Element> classextendsElts;
  output list<SCode.Element> outElts;
algorithm
  (classextendsElts,outElts) := matchcontinue (elts)
    local
      list<SCode.Element> res,xs;
      SCode.Element cdef;
    case ({}) then ({},{});

    case ((cdef as SCode.CLASS(classDef = SCode.CLASS_EXTENDS(baseClassName = _)))::xs)
      equation
        (classextendsElts,res) = splitClassExtendsElts(xs);
      then 
        (cdef :: classextendsElts, res);

    case cdef::xs
      equation
        (classextendsElts,res) = splitClassExtendsElts(xs);
      then 
        (classextendsElts, cdef :: res);

  end matchcontinue;
end splitClassExtendsElts;

protected function addClassdefsToEnv3
"function: addClassdefsToEnv3 "
  input Env.Env env;
  input InstanceHierarchy inIH;
  input Prefix.Prefix inPrefix;
  input Option<DAE.Mod> inMod;
  input SCode.Element sele;
  output Env.Env oenv;
  output InstanceHierarchy outIH;
  output SCode.Element osele;
algorithm
  (oenv,outIH,osele) := match(env,inIH,inPrefix,inMod,sele)
    local
      DAE.Mod mo,mo2;
      SCode.Element sele2;
      Env.Env env2;
      String str;
      SCode.Element retcl;
      InstanceHierarchy ih;
      list<DAE.SubMod> lsm,lsm2;
      Prefix.Prefix pre;

    case(_,ih,pre,NONE(),_) then fail();

    case(env,ih,pre, SOME(mo as DAE.MOD(_,_, lsm ,_)), sele as SCode.CLASS(name=str))
      equation
        (mo2,lsm2) = extractCorrectClassMod2(lsm,str,{});
        // TODO: classinf below should be FQ
        (_,env2,ih, sele2 as SCode.CLASS(name = _) , _, _) =
        redeclareType(Env.emptyCache(), env, ih, mo2, sele, pre, ClassInf.MODEL(Absyn.IDENT(str)), Connect.emptySet, true, DAE.NOMOD());
      then
        (env2,ih,sele2);
    
  end match;
end addClassdefsToEnv3;

protected function extractCorrectClassMod2
"function: extractCorrectClassMod2
 This function extracts a modifier on a specific component.
 Referenced by the name."
  input list<DAE.SubMod> smod;
  input String name;
  input list<DAE.SubMod> premod;
  output DAE.Mod omod;
  output list<DAE.SubMod> restmods;
algorithm (omod,restmods) := matchcontinue( smod , name , premod)
  local
    DAE.Mod mod;
    DAE.SubMod sub;
    String id;
    list<DAE.SubMod> rest,rest2;
    
    case({},_,premod) then (DAE.NOMOD(),premod);
    
  case(DAE.NAMEMOD(id, mod) :: rest, name, premod)
    equation
        true = stringEq(id, name);
    rest2 = listAppend(premod,rest);
    then
      (mod, rest2);
    
  case(sub::rest,name,premod)
    equation
    (mod,rest2) = extractCorrectClassMod2(rest,name,premod);
    then
      (mod, sub::rest2);
    
  case(_,_,_)
    equation
      Debug.fprint("failtrace", "- extract_Correct_Class_Mod_2 failed\n");
    then
      fail();
  end matchcontinue;
end extractCorrectClassMod2;

public function traverseModAddFinal
"This function takes a modifer and a bool
 to represent wheter it is final or not.
 If it is final, traverses down in the
 modifier setting all final elements to true."
  input SCode.Mod mod;
  input SCode.Final finalPrefix;
  output SCode.Mod mod2;
algorithm 
  mod2 := matchcontinue(mod,finalPrefix)
    case(mod, SCode.NOT_FINAL()) then mod;
    case(mod, SCode.FINAL())
      equation 
        mod = traverseModAddFinal2(mod);
      then
        mod;
    case(_,_)
      equation 
        print(" we failed with traverseModAddFinal\n");
      then 
        fail();
  end matchcontinue;
end traverseModAddFinal;

protected function traverseModAddFinal2
"Helper function for traverseModAddFinal"
  input SCode.Mod mod;
  output SCode.Mod mod2;
algorithm 
  mod2 := matchcontinue(mod)
    local
      list<SCode.Element> lelement;
      SCode.Each each_;
      list<SCode.SubMod> subs;
      Option<tuple<Absyn.Exp,Boolean>> eq;
  
    case(SCode.NOMOD()) then SCode.NOMOD();
  
    case(SCode.REDECL(_,each_,lelement))
      equation
        lelement = traverseModAddFinal3(lelement);
      then
        SCode.REDECL(SCode.FINAL(),each_,lelement);
  
    case(SCode.MOD(_,each_,subs,eq))
      equation
        subs = traverseModAddFinal4(subs);
      then
        SCode.MOD(SCode.FINAL(),each_,subs,eq);
  
    case(_) equation print(" we failed with traverseModAddFinal2\n"); then fail();
    
  end matchcontinue;
end traverseModAddFinal2;

protected function traverseModAddFinal3
"Helper function for traverseModAddFinal2"
  input list<SCode.Element> ltuple;
  output list<SCode.Element> oltuple;
algorithm 
  oltuple := matchcontinue(ltuple)
    local
      list<SCode.Element> rest;
      SCode.Element ele;
      SCode.Attributes attr;
      Absyn.TypeSpec tySpec;
      SCode.Mod mod, oldmod;
      Ident name;
      SCode.Visibility vis;
      SCode.Prefixes prefixes;
      Option<SCode.Comment> cmt;
      Option<Absyn.Exp> cond;
      Absyn.Path p;
      Option<SCode.Annotation> ann;
      Absyn.Info info;
      
    case({}) then {};
      
    case( SCode.COMPONENT(name,prefixes,attr,tySpec,oldmod,cmt,cond,info)::rest )
      equation
        rest = traverseModAddFinal3(rest);
        mod = traverseModAddFinal2(oldmod);
      then
        SCode.COMPONENT(name,prefixes,attr,tySpec,mod,cmt,cond,info)::rest;
        
    case((ele as SCode.IMPORT(imp = _))::rest)
      equation
        rest = traverseModAddFinal3(rest);
      then 
        ele::rest;
        
    case((ele as SCode.CLASS(name = _))::rest)
      equation
        rest = traverseModAddFinal3(rest);
      then 
        ele::rest;
        
    case(SCode.EXTENDS(p,vis,mod,ann,info)::rest)
      equation
        mod = traverseModAddFinal2(mod);
      then 
        SCode.EXTENDS(p,vis,mod,ann,info)::rest;
        
    case(_) 
      equation 
        print(" we failed with traverseModAddFinal3\n"); 
      then 
        fail();
    
  end matchcontinue;
end traverseModAddFinal3;

protected function traverseModAddFinal4
"Helper function for traverseModAddFinal2"
  input list<SCode.SubMod> subs;
  output list<SCode.SubMod> osubs;
algorithm osubs:= matchcontinue(subs)
  local
    String ident;
    SCode.Mod mod;
    list<Absyn.Subscript> intList;
    list<SCode.SubMod> rest;
  case({}) then {};
  case((SCode.NAMEMOD(ident,mod))::rest )
    equation
      rest = traverseModAddFinal4(rest);
      mod = traverseModAddFinal2(mod);
    then
      SCode.NAMEMOD(ident,mod)::rest;
  case((SCode.IDXMOD(intList,mod))::rest )
    equation
      rest = traverseModAddFinal4(rest);
      mod = traverseModAddFinal2(mod);
    then
      SCode.IDXMOD(intList, mod)::rest;
  case(_)
    equation print(" we failed with traverseModAddFinal4\n");
    then fail();
end matchcontinue;
end traverseModAddFinal4;

protected function traverseModAddDims
"The function used to modify modifications for non-expanded arrays"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Prefix.Prefix inPrefix;
  input SCode.Mod inMod;
  input InstDims inInstDims;
  input list<Absyn.Subscript> inDecDims;
  output SCode.Mod outMod;
algorithm 
  outMod := matchcontinue(inCache,inEnv,inPrefix,inMod,inInstDims,inDecDims)
  local
    Env.Cache cache;
    Env.Env env;
    Prefix.Prefix pre;
    SCode.Mod mod, mod2;
    InstDims inst_dims;
    list<Absyn.Subscript> decDims;
    list<list<DAE.Exp>> exps;
    list<list<Absyn.Exp>> aexps;
    list<Option<Absyn.Exp>> adims;
    
  case (_,_,_,mod,_,_) //If arrays are expanded, no action is needed
    equation
      true = RTOpts.splitArrays();
    then
      mod; 
/*  case (_,_,_,mod,inst_dims,decDims)
    equation
      subs = Util.listFlatten(inst_dims);
      exps = Util.listMap(subs,Expression.subscriptNonExpandedExp);
      aexps = Util.listMap(exps, Expression.unelabExp);
      adims = Util.listMap(decDims, Absyn.subscriptExpOpt);
      mod2 = traverseModAddDims2(mod, aexps, adims, true);
      
    then       
      mod2;*/
  case (cache,env,pre,mod,inst_dims,decDims)
    equation
      exps = Util.listListMap(inst_dims,Expression.subscriptNonExpandedExp);
      aexps = Util.listListMap(exps, Expression.unelabExp);
      adims = Util.listMap(decDims, Absyn.subscriptExpOpt);
      mod2 = traverseModAddDims4(cache,env,pre,mod, aexps, adims, true);
      
    then       
      mod2;
  end matchcontinue;
end traverseModAddDims;

protected function traverseModAddDims4
"Helper function  for traverseModAddDims"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Prefix.Prefix inPrefix;
  input SCode.Mod inMod;
  input list<list<Absyn.Exp>> inExps;
  input list<Option<Absyn.Exp>> inExpOpts;
  input Boolean inIsTop;
  output SCode.Mod outMod;
algorithm 
  outMod := matchcontinue(inCache,inEnv,inPrefix,inMod,inExps,inExpOpts,inIsTop)
  local
    Env.Cache cache;
    Env.Env env;
    Prefix.Prefix pre;
    SCode.Mod mod;
    Boolean is_top;
    SCode.Final f;
    list<SCode.SubMod> submods,submods2;
    Option<tuple<Absyn.Exp,Boolean>> tup,tup2;
    list<list<Absyn.Exp>> exps;
    list<Option<Absyn.Exp>> expOpts;
    
    case (_,_,_,SCode.NOMOD(),_,_,_) then SCode.NOMOD();
    case (_,_,_,mod as SCode.REDECL(finalPrefix=_),_,_,_) then mod;  // Though redeclarations may need some processing as well
    case (cache,env,pre,SCode.MOD(f, SCode.NOT_EACH(),submods,tup),exps,expOpts,_)
      equation
        submods2 = traverseModAddDims5(cache,env,pre,submods,exps,expOpts);
        tup2 = insertSubsInTuple2(tup,exps);
      then
        SCode.MOD(f, SCode.NOT_EACH(),submods2,tup2); 
/*    case (SCode.MOD(f, Absyn.EACH(),submods,tup),exps,expOpts,is_top)
      equation
        submods2 = traverseModAddDims3(submods,exps,expOpts);
        tup2 = insertSubsInTuple(tup,exps);
      then
        SCode.MOD(f, Absyn.NON_EACH(),submods2,tup2); */
  end matchcontinue;
end traverseModAddDims4;

protected function traverseModAddDims5
"Helper function  for traverseModAddDims2"
  input Env.Cache inCache;
  input Env.Env inEnv;
  input Prefix.Prefix inPrefix;
  input list<SCode.SubMod> inMods;
  input list<list<Absyn.Exp>> inExps;
  input list<Option<Absyn.Exp>> inExpOpts;
  output list<SCode.SubMod> outMods;
algorithm 
  outMods := matchcontinue(inCache,inEnv,inPrefix,inMods,inExps,inExpOpts)
  local
    Env.Cache cache;
    Env.Env env;
    Prefix.Prefix pre;
    SCode.Mod mod,mod2;
    list<SCode.SubMod> smods,smods2;
    Ident n;
    case (_,_,_,{},_,_) then {};
    case (cache,env,pre,SCode.NAMEMOD(n,mod)::smods,inExps,inExpOpts)
      equation
        mod2 = traverseModAddDims4(cache,env,pre,mod,inExps,inExpOpts,false);
        smods2 = traverseModAddDims5(cache,env,pre,smods,inExps,inExpOpts);
      then
        SCode.NAMEMOD(n,mod2)::smods2;
    case (_,_,_,SCode.IDXMOD(an=_)::_,_,_)
      equation
        print("Cannot process IDXMOD in the case of non-expanded arrays");
      then
        fail();      
  end matchcontinue;
end traverseModAddDims5;


/*protected function traverseModAddDims2
"Helper function  for traverseModAddDims"
  input SCode.Mod inMod;
  input list<Absyn.Exp> inExps;
  input list<Option<Absyn.Exp>> inExpOpts;
  input Boolean inIsTop;
  output SCode.Mod outMod;
algorithm 
  outMod := matchcontinue(inMod,inExps,inExpOpts,inIsTop)
  local
    SCode.Mod mod;
    Boolean f,is_top;
    list<SCode.SubMod> submods,submods2;
    Option<tuple<Absyn.Exp,Boolean>> tup,tup2;
    list<Absyn.Exp> exps;
    list<Option<Absyn.Exp>> expOpts;
    
    case (SCode.NOMOD(),_,_,_) then SCode.NOMOD();
    case (mod as SCode.REDECL(finalPrefix=_),_,_,_) then mod;  // Though redeclarations may need some processing as well
    case (SCode.MOD(f, Absyn.NON_EACH(),submods,tup),exps,expOpts,_)
      equation
        submods2 = traverseModAddDims3(submods,exps,expOpts);
        tup2 = insertSubsInTuple(tup,exps);
      then
        SCode.MOD(f, Absyn.NON_EACH(),submods2,tup2); 
  end matchcontinue;
end traverseModAddDims2;

protected function traverseModAddDims3
"Helper function  for traverseModAddDims2"
  input list<SCode.SubMod> inMods;
  input list<Absyn.Exp> inExps;
  input list<Option<Absyn.Exp>> inExpOpts;
  output list<SCode.SubMod> outMods;
algorithm 
  outMods := matchcontinue(inMods,inExps,inExpOpts)
  local
    SCode.Mod mod,mod2;
    list<SCode.SubMod> smods,smods2;
    Ident n;
    case ({},_,_) then {};
    case (SCode.NAMEMOD(n,mod)::smods,inExps,inExpOpts)
      equation
        mod2 = traverseModAddDims2(mod,inExps,inExpOpts,false);
        smods2 = traverseModAddDims3(smods,inExps,inExpOpts);
      then
        SCode.NAMEMOD(n,mod2)::smods2;
    case (SCode.IDXMOD(an=_)::_,_,_)
      equation
        print("Cannot process IDXMOD in the case of non-expanded arrays");
      then
        fail();      
  end matchcontinue;
end traverseModAddDims3;

protected function insertSubsInTuple
input Option<tuple<Absyn.Exp,Boolean>> inOpt;
input list<Absyn.Exp> inExps;
output Option<tuple<Absyn.Exp,Boolean>> outOpt;
algorithm
  outOpt := matchcontinue(inOpt,inExps)
  local
    list<Absyn.Exp> exps;
    Absyn.Exp e,e2;
    Boolean b;
    list<Absyn.Subscript> subs;
    list<Absyn.Ident> vars;
    tuple<Absyn.Exp,Boolean> tp;
    
    case (NONE(),_) then NONE();
    case (SOME(tp as (e,b)), exps)
      equation
        vars = generateUnusedNames(e,exps);
        subs = stringsSubs(vars);
        ((e2,_)) = Absyn.traverseExp(e,Absyn.crefInsertSubscripts2, subs);
        e2 = wrapIntoFor(e2,vars,exps);
      then
        SOME((e2,b));
  end matchcontinue;
end insertSubsInTuple;*/

protected function insertSubsInTuple2
input Option<tuple<Absyn.Exp,Boolean>> inOpt;
input list<list<Absyn.Exp>> inExps;
output Option<tuple<Absyn.Exp,Boolean>> outOpt;
algorithm
  outOpt := matchcontinue(inOpt,inExps)
  local
    list<list<Absyn.Exp>> exps;
    Absyn.Exp e,e2;
    Boolean b;
    list<list<Absyn.Subscript>> subs;
    list<list<Absyn.Ident>> vars;
    tuple<Absyn.Exp,Boolean> tp;
    
    case (NONE(),_) then NONE();
    case (SOME(tp as (e,b)), exps)
      equation
        vars = generateUnusedNamesLstCall(e,exps);
        subs = Util.listListMap(vars,stringSub);
        ((e2,_)) = Absyn.traverseExp(e,Absyn.crefInsertSubscriptLstLst, subs);
        e2 = wrapIntoForLst(e2,vars,exps);
      then
        SOME((e2,b));
  end matchcontinue;
end insertSubsInTuple2;

protected function generateUnusedNames
"Generates a list of variable names which are not used in any of expressions.
The number of variables is the same as the length of input list.
TODO: Write the REAL function!"
input Absyn.Exp inExp;
input list<Absyn.Exp> inList;
output list<String> outNames;
algorithm
  (outNames,_) := generateUnusedNames2(inList,1);
end generateUnusedNames;

protected function generateUnusedNames2
input list<Absyn.Exp> inList;
input Integer inInt;
output list<String> outNames;
output Integer outInt;
algorithm
  (outNames,outInt) := matchcontinue(inList,inInt)
  local
    Integer i,i1,i2;
    String s;
    list<String> names;
    list<Absyn.Exp> exps;
    case ({},i) then ({},i);
    case (_::exps,i)
      equation
        s = intString(i);
        s = "i" +& s;
        i1 = i + 1;
        (names,i2) = generateUnusedNames2(exps,i1);
      then
        (s::names,i2);    
  end matchcontinue;
end generateUnusedNames2;

protected function generateUnusedNamesLst
input list<list<Absyn.Exp>> inList;
input Integer inInt;
output list<list<String>> outNames;
output Integer outInt;
algorithm
  (outNames,outInt) := matchcontinue(inList,inInt)
  local
    Integer i,i1,i2;
    String s;
    list<list<String>> names;
    list<String> ns;
    list<list<Absyn.Exp>> exps;
    list<Absyn.Exp> e0;
    case ({},i) then ({},i);
    case (e0::exps,i)
      equation
        (ns,i1) = generateUnusedNames2(e0,i);
        (names,i2) = generateUnusedNamesLst(exps,i1);
      then
        (ns::names,i2);    
  end matchcontinue;
end generateUnusedNamesLst;

protected function generateUnusedNamesLstCall
"Generates a list of lists of variable names which are not used in any of expressions.
The structure of lsis of lists is the same as of input list of lists.
TODO: Write the REAL function!"
input Absyn.Exp inExp;
input list<list<Absyn.Exp>> inList;
output list<list<String>> outNames;
algorithm
  (outNames,_) := generateUnusedNamesLst(inList,1);
end generateUnusedNamesLstCall;

protected function stringsSubs
input list<String> inNames;
output list<Absyn.Subscript> outSubs;
algorithm
  outSubs := matchcontinue(inNames)
  local
    String n;
    list<String> names;
    list<Absyn.Subscript> subs;
    case {} then {};
    case n::names
      equation
        subs = stringsSubs(names);
      then
        Absyn.SUBSCRIPT(Absyn.CREF(Absyn.CREF_IDENT(n,{})))::subs;    
  end matchcontinue;
end stringsSubs;

protected function stringSub
input String inName;
output Absyn.Subscript outSub;
algorithm
  outSub := matchcontinue(inName)
  local
    String n;
    case n
      then
        Absyn.SUBSCRIPT(Absyn.CREF(Absyn.CREF_IDENT(n,{})));    
  end matchcontinue;
end stringSub;

protected function wrapIntoFor
input Absyn.Exp inExp;
input list<String> inNames;
input list<Absyn.Exp> inRanges;
output Absyn.Exp outExp;
algorithm
  outExp := matchcontinue(inExp,inNames,inRanges)
  local
    Absyn.Exp e,e2,r;
    String n;
    list<String> names;
    list<Absyn.Exp> ranges;
    case (e,{},{}) then e;
    case (e,n::names,r::ranges)
      equation
        e2 = wrapIntoFor(e, names, ranges);
      then
        Absyn.CALL(Absyn.CREF_IDENT("array",{}),
           Absyn.FOR_ITER_FARG(e2,{Absyn.ITERATOR(n,NONE(),SOME(Absyn.RANGE(Absyn.INTEGER(1),NONE(),r)))}));
  end matchcontinue;
end wrapIntoFor;           
    
protected function wrapIntoForLst
input Absyn.Exp inExp;
input list<list<String>> inNames;
input list<list<Absyn.Exp>> inRanges;
output Absyn.Exp outExp;
algorithm
  outExp := matchcontinue(inExp,inNames,inRanges)
  local
    Absyn.Exp e,e2,e3;
    list<String> n;
    list<list<String>> names;
    list<Absyn.Exp> r;
    list<list<Absyn.Exp>> ranges;
    case (e,{},{}) then e;
    case (e,n::names,r::ranges)
      equation
        e2 = wrapIntoForLst(e, names, ranges);
        e3 = wrapIntoFor(e2, n, r);
      then
        e3;
  end matchcontinue;
end wrapIntoForLst;           
    
protected function modifyInstantiateClass
"function: modifyInstantiateClass
 Here we check a modifier and a path,
 if we have a redeclaration of the class
 pointed by the path, we add this to a
 special reclaration modifier.
 Function returning 2 modifiers:
 - one (first output) to represent the redeclaration of
                      'current' class (class-name equal to path)
 - two (second output) to represent any other modifier."
  input DAE.Mod inMod;
  input Absyn.Path path;
  output DAE.Mod omod1;
  output DAE.Mod omod2;
algorithm
  (omod1,omod2) := matchcontinue(inMod,path)
    local
      SCode.Final f;
      SCode.Each e;
      list<tuple<SCode.Element, DAE.Mod>> redecls,p1,p2;
      Integer i1;
      
    case(DAE.REDECL(f,e,redecls), path)
      equation
        (p1,p2) = modifyInstantiateClass2(redecls,path);
        i1 = listLength(p1);
        omod1 = Util.if_(i1==0,DAE.NOMOD(), DAE.REDECL(f,e,p1));
        i1 = listLength(p2);
        omod2 = Util.if_(i1==0,DAE.NOMOD(), DAE.REDECL(f,e,p2));
      then
        (omod1,omod2);
    
    case(inMod,_)
      then (DAE.NOMOD(), inMod);

  end matchcontinue;
end modifyInstantiateClass;

protected function modifyInstantiateClass2
"Helper function for modifyInstantiateClass"
  input list<tuple<SCode.Element, DAE.Mod>> redecls;
  input Absyn.Path path;
  output list<tuple<SCode.Element, DAE.Mod>> omod1;
  output list<tuple<SCode.Element, DAE.Mod>> omod2;
algorithm
  (omod1,omod2) := matchcontinue(redecls,path)
    local
      list<tuple<SCode.Element, DAE.Mod>> rest,rec2,rec1;
      tuple<SCode.Element, DAE.Mod> head;
      DAE.Mod m;
      String id1,id2;
    case({},_) then ({},{});
    case( (head as  (SCode.CLASS(name = id1),m))::rest, path)
      equation
        id2 = Absyn.pathString(path);
        true = stringEq(id1,id2);
        (rec1,rec2) = modifyInstantiateClass2(rest,path);
      then
        (head::rec1,rec2);
    case(head::rest,path)
      equation
        (rec1,rec2) = modifyInstantiateClass2(rest,path);
      then
        (rec1,head::rec2);
  end matchcontinue;
end modifyInstantiateClass2;

protected function removeSelfReferenceAndUpdate
"function removeSelfReferenceAndUpdate
 BZ 2007-07-03
 This function checks if there is a reference to itself.
 If it is, it removes the reference.
 But also instantiate the declared type, if any.
 If it fails (declarations of array dimensions using
 the size of itself) it will just remove the element."
  input Env.Cache cache;
  input Env.Env inEnv;
  input InstanceHierarchy inIH;
  input UnitAbsyn.InstStore store;
  input list<Absyn.ComponentRef> inRefs;
  input Absyn.ComponentRef inRef;
  input Absyn.Path inPath;
  input ClassInf.State inState;
  input Connect.Sets icsets;
  input SCode.Attributes iattr;
  input SCode.Prefixes inPrefixes;
  input Boolean impl;
  input InstDims inst_dims;
  input Prefix.Prefix pre;
  input DAE.Mod mods;
  input Absyn.Info info;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output UnitAbsyn.InstStore outStore;
  output list<Absyn.ComponentRef> o1;
algorithm
  (outCache,outEnv,outIH,outStore,o1) :=
  matchcontinue(cache,inEnv,inIH,store,inRefs,inRef,inPath,inState,icsets,iattr,inPrefixes,impl,inst_dims,pre,mods,info)
    local
      Absyn.Path sty;
      Absyn.ComponentRef c1;
      list<Absyn.ComponentRef> cl1,cl2;
      Env.Env env,compenv,cenv;
      Integer i1,i2;
      list<Absyn.Subscript> ad;
      SCode.Variability param;
      Absyn.Direction dir;
      Ident n;
      SCode.Element c;
      DAE.Type ty;
      ClassInf.State state;
      SCode.Visibility vis;
      SCode.Flow flowPrefix;
      SCode.Stream streamPrefix;
      Connect.Sets csets;
      SCode.Attributes attr;
      list<DAE.Dimension> dims;
      DAE.Var new_var;
      InstanceHierarchy ih;
      Absyn.InnerOuter io;

    case(cache,env,ih,store,cl1,c1,_,_,_,_,_,_,_,_,_,_)
      equation
        cl2 = removeCrefFromCrefs(cl1, c1);
        i1 = listLength(cl2);
        i2 = listLength(cl1);
        true = ( i1 == i2);
      then
        (cache,env,ih,store,cl2);

    case(cache,env,ih,store,cl1,c1 as Absyn.CREF_IDENT(name = n) ,sty,state,csets,
         (attr as SCode.ATTR(arrayDims = ad, flowPrefix = flowPrefix, streamPrefix = streamPrefix,
                             variability = param, direction = dir)),
         _,impl,inst_dims,pre,mods,info)
         // we have reference to ourself, try to instantiate type.
      equation
        cl2 = removeCrefFromCrefs(cl1, c1);
        (cache,c,cenv) = Lookup.lookupClass(cache,env, sty, true);
        (cache,dims) = elabArraydim(cache,cenv, c1, sty, ad,NONE(), impl,NONE(),true, false,pre,info,inst_dims);
        (cache,compenv,ih,store,_,_,ty,_) = 
          instVar(cache,cenv,ih, store,state, DAE.NOMOD(), pre, csets, n, c, attr, inPrefixes, dims, {}, inst_dims, true,NONE(),info,ConnectionGraph.EMPTY,env);

        // print("component: " +& n +& " ty: " +& Types.printTypeStr(ty) +& "\n");

        io = SCode.prefixesInnerOuter(inPrefixes);
        vis = SCode.prefixesVisibility(inPrefixes);
        new_var = DAE.TYPES_VAR(n,DAE.ATTR(flowPrefix,streamPrefix,param,dir,io),vis,ty,DAE.UNBOUND(),NONE());
        env = Env.updateFrameV(env, new_var, Env.VAR_TYPED(), compenv);
      then
        (cache,env,ih,store,cl2);

    case(cache,env,ih,store,cl1,c1,_,_,_,_,_,_,_,_,_,_)
      equation
        cl2 = removeCrefFromCrefs(cl1, c1);
      then
        (cache,env,ih,store,cl2);

  end matchcontinue;
end removeSelfReferenceAndUpdate;

protected function replaceClassname
"function to replace the class name"
  input SCode.Element isc;
  input Ident name;
  output SCode.Element osc;
algorithm
  (osc) := matchcontinue(isc,name)
    local
      SCode.Element sc1;
      SCode.Encapsulated e;
      SCode.Partial p;
      SCode.Prefixes prefixes;
      SCode.Restriction r;
      SCode.ClassDef cd;
      Absyn.Info i;

    case( sc1 as SCode.CLASS(_,prefixes,e,p,r,cd,i),name)
      then
        SCode.CLASS(name,prefixes,e,p,r,cd,i);
  end matchcontinue;
end replaceClassname;

protected function componentHasCondition
  input tuple<SCode.Element, DAE.Mod> component;
  output Boolean hasCondition;
algorithm
  hasCondition := matchcontinue(component)
    case ((SCode.COMPONENT(condition = SOME(_)), _)) then true;
    case _ then false;
  end matchcontinue;
end componentHasCondition;
      
protected function isConditionalComponent
  input Env.Cache cache;
  input Env.Env env;
  input SCode.Element component;
  input Prefix.Prefix prefix;
  input Absyn.Info info;
  output Boolean isConditional;
  output Env.Cache outCache;
algorithm
  (isConditional, outCache) := matchcontinue(cache, env, component, prefix, info)
    local
      String name;
      Absyn.Exp cond_exp;
      Boolean is_cond;
    case (_, _, SCode.COMPONENT(name = name, condition = SOME(cond_exp)), _, info)
      equation
        (is_cond, cache) = instConditionalDeclaration(cache, env, cond_exp, name, prefix, info);
      then
        (not is_cond, cache);
    case (_, _, _, _, _) then (false, cache);
  end matchcontinue;
end isConditionalComponent;

protected function instConditionalDeclaration
  input Env.Cache cache;
  input Env.Env env;
  input Absyn.Exp cond;
  input Ident compName;
  input Prefix.Prefix pre;
  input Absyn.Info info;
  output Boolean isConditional;
  output Env.Cache outCache;
algorithm
  (isConditional, outCache) := matchcontinue(cache, env, cond, compName, pre, info)
    local
      DAE.Exp e;
      DAE.Type t;
      DAE.Const c;
      Boolean b;
      String exp_str, type_str;
    case (_, _, _, _, _, info)
      equation
        (cache, e, DAE.PROP(type_ = t, constFlag = c), _) = 
          Static.elabExp(cache, env, cond, false, NONE(), false, pre, info);
        true = Types.isBoolean(t);
        true = Types.isParameterOrConstant(c);
        (cache, Values.BOOL(b), _) = Ceval.ceval(cache, env, e, false, NONE(), NONE(), Ceval.MSG());
      then
        (b, cache);
    case (_, _, _, _, _, info)
      equation
        (cache, e, DAE.PROP(type_ = t), _) = 
          Static.elabExp(cache, env, cond, false, NONE(), false, pre, info);
        false = Types.isBoolean(t);
        exp_str = ExpressionDump.printExpStr(e);
        type_str = Types.unparseType(t);
        Error.addSourceMessage(Error.IF_CONDITION_TYPE_ERROR, {exp_str, type_str}, info);
      then
        fail();
    case (_, _, _, _, _, info)
      equation
        (cache, e, DAE.PROP(type_ = t, constFlag = c), _) = 
          Static.elabExp(cache, env, cond, false, NONE(), false, pre, info);
        true = Types.isBoolean(t);
        false = Types.isParameterOrConstant(c);
        exp_str = ExpressionDump.printExpStr(e);
        Error.addSourceMessage(Error.COMPONENT_CONDITION_VARIABILITY, {exp_str}, info);
      then
        fail();
    case (_, _, _, _, _, _)
      equation
        Debug.fprintln("failtrace", 
          "- Inst.instConditionalDeclaration failed on component: " +& compName +& 
          " for cond: " +& Dump.printExpStr(cond));
      then
        fail();
  end matchcontinue;
end instConditionalDeclaration;

protected function checkRecursiveDefinitionRecConst
"help function to checkRecursiveDefinition
 Makes exception for record constructor
 functions which have the output record
 name being the same as the function name.

 This function returns false if class
 restriction is record and ci_state
 is function"
  input ClassInf.State ci_state;
  input SCode.Element cl;
  output Boolean res;
algorithm
  res := matchcontinue(ci_state,cl)
    case(ClassInf.FUNCTION(_),SCode.CLASS(restriction=SCode.R_RECORD())) then false;
    case(_,_) then true;
  end matchcontinue;
end checkRecursiveDefinitionRecConst;

protected function propagateClassPrefix
"Propagate ClassPrefix, i.e. variability to a component.
 This is needed to make sure that e.g. a parameter does
 not generate an equation but a binding."
  input SCode.Attributes attr;
  input Prefix.Prefix pre;
  output SCode.Attributes outAttr;
algorithm
  outAttr := matchcontinue(attr,pre)
    local
      Absyn.ArrayDim ad;
      SCode.Flow fl;
      SCode.Stream st;
      Absyn.Direction dir;
      SCode.Variability vt;

    // if classprefix is variable, keep component variability
    case(attr,Prefix.PREFIX(_,Prefix.CLASSPRE(SCode.VAR()))) then attr;
    // if variability is constant, do not override it!
    case(attr as SCode.ATTR(variability = SCode.CONST()),_) then attr;
    // if classprefix is parameter or constant, override component variability
    case(SCode.ATTR(ad,fl,st,_,dir),Prefix.PREFIX(_,Prefix.CLASSPRE(vt)))
      then SCode.ATTR(ad,fl,st,vt,dir);
    // anything else
    case(attr,_) then attr;
  end matchcontinue;
end propagateClassPrefix;

protected function checkUseConstValue
"help function to instBinding.
 If first arg is true, it returns the constant expression found in Value option.
 This is used to ensure that e.g. stateSelect attribute gets a constant value
 and not a parameter expression."
  input Boolean useConstValue;
  input DAE.Exp e;
  input Option<Values.Value> v;
  output DAE.Exp outE;
algorithm
  outE := matchcontinue(useConstValue,e,v)
    local Values.Value val;
    case(false,e,v) then e;
    case(true,_,SOME(val)) equation
      e = ValuesUtil.valueExp(val);
    then e;
    case(_,e,_) then e;
  end matchcontinue;
end checkUseConstValue;

protected function propagateAbSCDirection
  input SCode.Variability inVariability;
  input SCode.Attributes inAttributes;
  input Option<SCode.Attributes> inClassAttributes;
  output SCode.Attributes outAttributes;
algorithm
  outAttributes := match(inVariability, inAttributes, inClassAttributes)
    local
      Absyn.Direction dir;

    case (SCode.CONST(), _, _) then inAttributes;
    case (SCode.PARAM(), _, _) then inAttributes;
    else
      equation
        SCode.ATTR(direction = dir) = inAttributes;
        dir = propagateAbSCDirection2(dir, inClassAttributes);
      then
        SCode.setAttributesDirection(inAttributes, dir);
  end match;
end propagateAbSCDirection;
        
public function propagateAbSCDirection2 "
Author BZ 2008-05
This function merged derived SCode.Attributes with the current input SCode.Attributes."
  input Absyn.Direction v1;
  input Option<SCode.Attributes> optDerAttr;
  output Absyn.Direction v3;
algorithm 
  v3 := matchcontinue(v1,optDerAttr)
    local Absyn.Direction v2;
    case(v1,NONE()) then v1;
    case(Absyn.BIDIR(),SOME(SCode.ATTR(direction=v2))) then v2;
    case(v1,SOME(SCode.ATTR(direction=Absyn.BIDIR()))) then v1;
    case(v1,SOME(SCode.ATTR(direction=v2)))
      equation
        equality(v1 = v2);
      then v1;
    case(_,_)
      equation
        print(" failure in propagateAbSCDirection2, Absyn.DIRECTION mismatch");
        Error.addMessage(Error.COMPONENT_INPUT_OUTPUT_MISMATCH, {"",""});
      then
        fail();
  end matchcontinue;
end propagateAbSCDirection2;

protected function makeCrefBaseType "Function: makeCrefBaseType"
  input DAE.Type baseType;
  input InstDims dims;
  output DAE.ExpType ety;
algorithm ety := matchcontinue(baseType,dims)
  local
    DAE.ExpType ty;
    DAE.Type tp_1,btp;
    list<DAE.Dimension> lst;
    
    // Types extending basic type has dimensions already added
    case(baseType as (DAE.T_COMPLEX(complexTypeOption=SOME(btp)),_),dims) equation
      ty = Types.elabType(btp);
    then ty;
           
   case(baseType, dims)
    equation
      lst = instdimsIntOptList(Util.listLast(dims));
      tp_1 = arrayBasictypeBaseclass2(lst, baseType);
      ty = Types.elabType(tp_1);
    then
      ty;
     
  case(baseType, dims)
    equation
      failure(_ = instdimsIntOptList(Util.listLast(dims)));
      ty = Types.elabType(baseType);
    then
      ty;

  case(_,_)
    equation
    Debug.fprint("failtrace", "- make_makeCrefBaseType failed\n");
    print("makCrefBaseType failed\n");
    then
      fail();
end matchcontinue;
end makeCrefBaseType;

protected function liftNonBasicTypesNDimensions "Function: liftNonBasicTypesNDimensions
This is to handle a Option<integer> list of dimensions.
"
  input DAE.Type tp;
  input list<DAE.Dimension> dimt;
  output DAE.Type otype;
algorithm otype := matchcontinue(tp,dimt)
  local DAE.Dimension x;
  case(tp,{}) then tp;
  case(tp, x::dimt)
    equation
      tp = liftNonBasicTypes(tp,x);
      tp = liftNonBasicTypesNDimensions(tp,dimt);
    then
      tp;
end matchcontinue;
end liftNonBasicTypesNDimensions;

protected function getCrefFromCompDim "
Author: BZ, 2009-07
Get Absyn.ComponentRefs from dimension in SCode.COMPONENT"
  input SCode.Element inEle;
  output list<Absyn.ComponentRef> cref;
algorithm cref := matchcontinue(inEle)
  local
    list<Absyn.Subscript> ads;
  case(SCode.COMPONENT(attributes = SCode.ATTR(arrayDims = ads)))
    then
      Absyn.getCrefsFromSubs(ads);
  case(_) then {};
end matchcontinue;
end getCrefFromCompDim;

protected function getCrefFromCond "
  author: PA
  Return all variables in a conditional component clause.
  Done to instantiate components referenced in other components, See also getCrefFromMod and
  updateComponentsInEnv."
  input Option<Absyn.Exp> cond;
  output list<Absyn.ComponentRef> crefs;
algorithm
  crefs := match(cond)
    local  Absyn.Exp e;
    case(NONE()) then {};
    case SOME(e) then Absyn.getCrefFromExp(e,true);
  end match;
end getCrefFromCond;

protected function updateComponentsInEnv2
"function updateComponentsInEnv2
  author: PA
  Help function to updateComponentsInEnv."
  input Env.Cache cache;
  input Env.Env env;
  input InstanceHierarchy inIH;
  input Prefix.Prefix pre;
  input DAE.Mod mod;
  input list<Absyn.ComponentRef> crefs;
  input ClassInf.State ci_state;
  input Connect.Sets csets;
  input Boolean impl;
  input HashTable5.HashTable updatedComps;
  output Env.Cache outCache;
  output Env.Env outEnv;
  output InstanceHierarchy outIH;
  output Connect.Sets outSets;
  output HashTable5.HashTable outUpdatedComps;
algorithm
  (outCache,outEnv,outIH,outSets,outUpdatedComps) :=
  matchcontinue (cache,env,inIH,pre,mod,crefs,ci_state,csets,impl,updatedComps)
    local
      list<Env.Frame> env_1,env_2;
      DAE.Mod mods;
      Absyn.ComponentRef cr;
      list<Absyn.ComponentRef> rest;
      InstanceHierarchy ih;
      String n;

      // two first cases catches when we want to update an already typed and bound var.
    case (cache,env,ih,pre,mods,(cr :: rest),ci_state,csets,impl,updatedComps)
      equation
        n = Absyn.printComponentRefStr(cr);
        (_,DAE.TYPES_VAR(binding = DAE.VALBOUND(valBound=_)),SOME((_,_)),_,_) = Lookup.lookupIdentLocal(cache, env, n);
        (cache,env_2,ih,csets,updatedComps) = updateComponentsInEnv2(cache, env, ih, pre, mods, rest, ci_state, csets, impl, updatedComps);
      then
        (cache,env_2,ih,csets,updatedComps);

    case (cache,env,ih,pre,mods,(cr :: rest),ci_state,csets,impl,updatedComps)
      equation
        n = Absyn.printComponentRefStr(cr);
        (_,DAE.TYPES_VAR(binding = DAE.EQBOUND(exp=_)),SOME((_,_)),_,_) = Lookup.lookupIdentLocal(cache, env, n);
        (cache,env_2,ih,csets,updatedComps) = updateComponentsInEnv2(cache, env, ih, pre, mods, rest, ci_state, csets, impl, updatedComps);
      then
        (cache,env_2,ih,csets,updatedComps);

    case (cache,env,ih,pre,mods,(cr :: rest),ci_state,csets,impl,updatedComps) /* Implicit instantiation */
      equation
        //ErrorExt.setCheckpoint();
        // this line below "updateComponentInEnv" can not fail so no need to catch that checkpoint(error).
        //print(" Updating component: " +& Absyn.printComponentRefStr(cr) +& " mods: " +& Mod.printModStr(mods)+& "\n");
        (cache,env_1,ih,csets,updatedComps) = updateComponentInEnv(cache, env, ih, pre, mods, cr, ci_state, csets, impl,updatedComps);
        //ErrorExt.rollBack();
        (cache,env_2,ih,csets,updatedComps) = updateComponentsInEnv2(cache, env_1, ih, pre, mods, rest, ci_state, csets, impl, updatedComps);
      then
        (cache,env_2,ih,csets,updatedComps);

    case (cache,env,ih,pre,_,{},ci_state,csets,impl,updatedComps)
      then (cache,env,ih,csets,updatedComps);

    case (cache,env,ih,pre,_,_,ci_state,csets,impl,updatedComps) equation
        Debug.fprint("failtrace","-updateComponentsInEnv failed\n");
      then fail();
  end matchcontinue;
end updateComponentsInEnv2;

protected function noModForUpdatedComponents "help function for updateComponentInEnv,

For components that already have been visited by updateComponentsInEnv, they must be instantiated without
modifiers to prevent infinite recursion"
  input SCode.Variability variability;
  input HashTable5.HashTable updatedComps;
  input Absyn.ComponentRef cref;
  input  DAE.Mod mods;
  input  DAE.Mod cmod;
  input  SCode.Mod m;
  output DAE.Mod outMods;
  output DAE.Mod outCmod;
  output SCode.Mod outM;
algorithm
  (outMods,outCmod,outM) := matchcontinue(variability,updatedComps,cref,mods,cmod,m)
    case (variability,updatedComps,cref,mods,cmod,m)
      equation
        _ = BaseHashTable.get(cref,updatedComps);
        checkVariabilityOfUpdatedComponent(variability,cref);
      then (DAE.NOMOD(),DAE.NOMOD(),SCode.NOMOD());

    case (_,updatedComps,cref,mods,cmod,m) then (mods,cmod,m);
  end matchcontinue;
end noModForUpdatedComponents;

protected function checkVariabilityOfUpdatedComponent "
For components that already have been visited by updateComponentsInEnv, they must be instantiated without
modifiers to prevent infinite recursion. However, parameters and constants may not have recursive definitions.
So we print errors for those instead."
  input SCode.Variability variability;
  input Absyn.ComponentRef cref;
algorithm
  _ := match (variability,cref)
    local
    case (SCode.VAR(),_) then ();
    case (SCode.DISCRETE(),_) then ();
    case (variability,cref)
      equation
        /* Doesn't work anyway right away
        crefStr = Absyn.printComponentRefStr(cref);
        varStr = SCodeDump.variabilityString(variability);
        Error.addMessage(Error.CIRCULAR_PARAM,{crefStr,varStr});*/
      then fail();
  end match;
end checkVariabilityOfUpdatedComponent;

protected function makeFullyQualified2
"help function to makeFullyQualified"
  input Env.Env env;
  input Ident className;
output Absyn.Path path;
algorithm
  path := matchcontinue(env,className)
    local
      Absyn.Path scope;
    case(env,className)
      equation
        SOME(scope) = Env.getEnvPath(env);
        path = Absyn.joinPaths(scope, Absyn.IDENT(className));
      then path;
    case(env,className)
      equation
        NONE() = Env.getEnvPath(env);
      then Absyn.IDENT(className);
  end matchcontinue;
end makeFullyQualified2;

protected function propagateBinding "
This function modifies equations into bindings for parameters"
  input DAE.DAElist inVarsDae;
  input DAE.DAElist inEquationsDae "Note: functions from here are not considered";
  output DAE.DAElist outVarsDae;
algorithm
  outVarsDae := matchcontinue(inVarsDae,inEquationsDae)
  local
    list<DAE.Element> vars, vars1, equations;
    DAE.Element var;
    DAE.Exp e;
    DAE.ComponentRef componentRef;
    DAE.VarKind kind;
    DAE.VarDirection direction;
    DAE.VarVisibility protection;
    DAE.Type ty;
    DAE.InstDims  dims;
    DAE.Flow flowPrefix;
    DAE.Stream streamPrefix;
    Option<DAE.VariableAttributes> variableAttributesOption;
    Option<SCode.Comment> absynCommentOption;
    Absyn.InnerOuter innerOuter;
    DAE.ElementSource source "the origin of the element";
    case (DAE.DAE(vars),DAE.DAE({})) then DAE.DAE(vars);
    case (DAE.DAE({}),_) then DAE.DAE({});
    case (DAE.DAE(DAE.VAR(componentRef,kind,direction,protection,ty,NONE(),dims,
                  flowPrefix,streamPrefix,source,variableAttributesOption,
                  absynCommentOption,innerOuter)::vars), DAE.DAE(equations))
      equation
        SOME(e)=findCorrespondingBinding(componentRef, equations);
        DAE.DAE(vars1) = propagateBinding(DAE.DAE(vars),DAE.DAE(equations));
      then
        DAE.DAE(DAE.VAR(componentRef,kind,direction,protection,ty,SOME(e),dims,
                flowPrefix,streamPrefix,source,variableAttributesOption,
                absynCommentOption,innerOuter)::vars1);

    case (DAE.DAE(var::vars), DAE.DAE(equations))
      equation
        DAE.DAE(vars1)=propagateBinding(DAE.DAE(vars),DAE.DAE(equations));
      then
        DAE.DAE(var::vars1);
  end matchcontinue;
end propagateBinding;

protected function findCorrespondingBinding "
Helper function for propagateBinding"
  input DAE.ComponentRef inCref;
  input list<DAE.Element> inEquations;
  output Option<DAE.Exp> outExp;
algorithm
  outExp:=matchcontinue(inCref, inEquations)
    local
      DAE.ComponentRef cref,cref2,cref3;
      DAE.Exp e;
      list<DAE.Element> equations;

    case (_, {}) then NONE();
    
    case (cref, DAE.DEFINE(componentRef=cref2, exp=e)::_)
      equation
        true = ComponentReference.crefEqual(cref,cref2);
      then
        SOME(e);
    
    case (cref, DAE.EQUATION(exp=DAE.CREF(cref2,_),scalar=e)::_)
      equation
        true = ComponentReference.crefEqual(cref,cref2);
      then
        SOME(e);
    
    case (cref, DAE.EQUEQUATION(cr1=cref2,cr2=cref3)::_)
      equation
        true = ComponentReference.crefEqual(cref,cref2);
        e = Expression.crefExp(cref3);
      then
        SOME(e);
    
    case (cref, DAE.COMPLEX_EQUATION(lhs=DAE.CREF(cref2,_),rhs=e)::_)
      equation
        true = ComponentReference.crefEqual(cref,cref2);
      then
        SOME(e);
    
    case (cref, _::equations)
      then 
        findCorrespondingBinding(cref,equations);
    
  end matchcontinue;
end findCorrespondingBinding;



// *********************************************************************
//    hash table implementation for cashing instantiation results
// *********************************************************************

function addToInstCache
  input Absyn.Path fullEnvPathPlusClass;
  input Option<CachedInstItem> fullInstOpt;
  input Option<CachedInstItem> partialInstOpt;
algorithm
  _ := matchcontinue(fullEnvPathPlusClass,fullInstOpt, partialInstOpt)
    local
      CachedInstItem fullInst, partialInst;
      InstHashTable instHash;

    // nothing is we have +d=noCache
    case (_, _, _)
      equation
        true = RTOpts.debugFlag("noCache");
       then
         ();
      
    // we have them both
    case (fullEnvPathPlusClass, SOME(fullInst), SOME(partialInst))
      equation
        instHash = getGlobalRoot(instHashIndex);
        instHash = BaseHashTable.add((fullEnvPathPlusClass,{fullInstOpt,partialInstOpt}),instHash);
        setGlobalRoot(instHashIndex, instHash);
      then
        ();

    // we have a partial inst result and the full in the cache
    case (fullEnvPathPlusClass, NONE(), SOME(partialInst))
      equation
        instHash = getGlobalRoot(instHashIndex);
        // see if we have a full inst here
        {SOME(fullInst),_} = BaseHashTable.get(fullEnvPathPlusClass, instHash);
        instHash = BaseHashTable.add((fullEnvPathPlusClass,{SOME(fullInst),partialInstOpt}),instHash);
        setGlobalRoot(instHashIndex, instHash);
      then
        ();

    // we have a partial inst result and the full is NOT in the cache
    case (fullEnvPathPlusClass, NONE(), SOME(partialInst))
      equation
        instHash = getGlobalRoot(instHashIndex);
        // see if we have a full inst here
        // failed above {SOME(fullInst),_} = get(fullEnvPathPlusClass, instHash);
        instHash = BaseHashTable.add((fullEnvPathPlusClass,{NONE(),partialInstOpt}),instHash);
        setGlobalRoot(instHashIndex, instHash);
      then
        ();

    // we have a full inst result and the partial in the cache
    case (fullEnvPathPlusClass, SOME(fullInst), NONE())
      equation
        instHash = getGlobalRoot(instHashIndex);
        // see if we have a partial inst here
        {_,SOME(partialInst)} = BaseHashTable.get(fullEnvPathPlusClass, instHash);
        instHash = BaseHashTable.add((fullEnvPathPlusClass,{fullInstOpt,SOME(partialInst)}),instHash);
        setGlobalRoot(instHashIndex, instHash);
      then
        ();

    // we have a full inst result and the partial is NOT in the cache
    case (fullEnvPathPlusClass, SOME(fullInst), NONE())
      equation
        instHash = getGlobalRoot(instHashIndex);
        // see if we have a partial inst here
        // failed above {_,SOME(partialInst)} = get(fullEnvPathPlusClass, instHash);
        instHash = BaseHashTable.add((fullEnvPathPlusClass,{fullInstOpt,NONE()}),instHash);
        setGlobalRoot(instHashIndex, instHash);
      then
        ();

    // we failed above??!!
    case (fullEnvPathPlusClass, fullInstOpt, partialInstOpt)
      equation
      then
        ();
  end matchcontinue;
end addToInstCache;

public
uniontype CachedInstItem
  // *important* inputs/outputs for instClassIn
  record FUNC_instClassIn
    tuple<Env.Cache, Env.Env, InstanceHierarchy, UnitAbsyn.InstStore,
          DAE.Mod, Prefix.Prefix, Connect.Sets, ClassInf.State, SCode.Element,
          SCode.Visibility, InstDims, Boolean, ConnectionGraph.ConnectionGraph,
          Option<DAE.ComponentRef>> inputs;
    tuple</*Env.Cache, */
          Env.Env, 
          /*InstanceHierarchy, */
          /*UnitAbsyn.InstStore, */
          DAE.DAElist, 
          Connect.Sets, 
          ClassInf.State, 
          list<DAE.Var>,
          Option<DAE.Type>, 
          Option<SCode.Attributes>, 
          DAE.EqualityConstraint,
          ConnectionGraph.ConnectionGraph
         > outputs;
  end FUNC_instClassIn;

  // *important* inputs/outputs for partialInstClassIn
  record FUNC_partialInstClassIn
    tuple<Env.Cache, Env.Env, InstanceHierarchy, DAE.Mod, Prefix.Prefix,
          Connect.Sets, ClassInf.State, SCode.Element, SCode.Visibility,
          InstDims> inputs;
    tuple</*Env.Cache,*/ 
          Env.Env, 
          /*InstanceHierarchy,*/ 
          ClassInf.State
         > outputs;
  end FUNC_partialInstClassIn;

end CachedInstItem;

public type CachedInstItems = list<Option<CachedInstItem>>;

/* Begin inline HashTable */
public type Key = Absyn.Path;
public type Value = CachedInstItems;

public type HashTableKeyFunctionsType = tuple<FuncHashKey,FuncKeyEqual,FuncKeyStr,FuncValueStr>;
public type InstHashTable = tuple<
  array<list<tuple<Key,Integer>>>,
  tuple<Integer,Integer,array<Option<tuple<Key,Value>>>>,
  Integer,
  Integer,
  HashTableKeyFunctionsType
>;

partial function FuncHashKey
  input Key cr;
  input Integer mod;
  output Integer res;
end FuncHashKey;

partial function FuncKeyEqual
  input Key cr1;
  input Key cr2;
  output Boolean res;
end FuncKeyEqual;

partial function FuncKeyStr
  input Key cr;
  output String res;
end FuncKeyStr;

partial function FuncValueStr
  input Value exp;
  output String res;
end FuncValueStr;

protected function opaqVal
"Don't actually print what is stored in the value... It's too damn long."
  input Value v;
  output String str;
algorithm
  str := "OPAQUE_VALUE";
end opaqVal;

public function emptyInstHashTable
"
  Returns an empty HashTable.
  Using the default bucketsize..
"
  output InstHashTable hashTable;
algorithm
  hashTable := emptyInstHashTableSized(BaseHashTable.defaultBucketSize);
end emptyInstHashTable;

public function emptyInstHashTableSized
"Returns an empty HashTable.
  Using the bucketsize size"
  input Integer size;
  output InstHashTable hashTable;
algorithm
  hashTable := BaseHashTable.emptyHashTableWork(size,(Absyn.pathHashMod,Absyn.pathEqual,Absyn.pathString,opaqVal));
end emptyInstHashTableSized;

/* end HashTable */

/*protected function checkModelBalancing
"@author adrpo
 this function checks the balancing of the given model"
  input Option<Absyn.Path> classNameOpt;
  input DAE.DAElist inDae;
algorithm
  _ := matchcontinue(classNameOpt, inDae)
    local
      DAE.DAElist dae;
      Integer eqnSize,varSize,simpleEqnSize;
      String warnings,eqnSizeStr,varSizeStr,retStr,classNameStr,simpleEqnSizeStr;
      BackendDAE.EquationArray eqns;
      Integer elimLevel;
      BackendDAE.BackendDAE dlow,dlow_1,indexed_dlow,indexed_dlow_1;
    // check the balancing of the instantiated model
    // special case for no elements!
    case (classNameOpt, DAE.DAE({},_))
      equation
        //classNameStr = Absyn.optPathString(classNameOpt);
        //warnings = Error.printMessagesStr();
        //retStr= stringAppendList({"# CHECK: ", classNameStr, " inst has 0 equation(s) and 0 variable(s)", warnings, "."});
        // do not show empty elements with 0 vars and 0 equs
        // Debug.fprintln("checkModel", retStr);
    then ();
    // check the balancing of the instantiated model
    case (classNameOpt, dae)
      equation
        dae = DAEUtil.transformIfEqToExpr(dae,false);
        elimLevel = RTOpts.eliminationLevel();
        RTOpts.setEliminationLevel(0); // No variable elimination
        (dlow as BackendDAE.DAE(orderedVars = BackendDAE.VARIABLES(numberOfVars = varSize),orderedEqs = eqns))
        = BackendDAECreate.lower(dae, false, true);
        // Debug.fcall("dumpdaelow", BackendDump.dump, dlow);
        RTOpts.setEliminationLevel(elimLevel); // reset elimination level.
        eqnSize = BackendEquation.equationSize(eqns);
        (eqnSize,varSize) = CevalScript.subtractDummy(BackendVariable.daeVars(dlow),eqnSize,varSize);
        simpleEqnSize = BackendDAEOptimize.countSimpleEquations(eqns);
        eqnSizeStr = intString(eqnSize);
        varSizeStr = intString(varSize);
        simpleEqnSizeStr = intString(simpleEqnSize);
        classNameStr = Absyn.optPathString(classNameOpt);
        warnings = Error.printMessagesStr();
        retStr= stringAppendList({"# CHECK: ", classNameStr, " inst has ", eqnSizeStr,
                                       " equation(s) and ", varSizeStr," variable(s). ",
                                       simpleEqnSizeStr, " of these are trivial equation(s).",
                                       warnings});
        Debug.fprintln("checkModel", retStr);
    then ();
    // we might fail, show a message
    case (classNameOpt, inDAEElements)
      equation
        classNameStr = Absyn.optPathString(classNameOpt);
        Debug.fprintln("checkModel", "# CHECK: " +& classNameStr +& " inst failed!");
      then ();
  end matchcontinue;
end checkModelBalancing;
*/


/*protected function checkModelBalancingFilterByRestriction
"@author: adrpo
 filter out some restricted classes"
  input SCode.Restriction r;
  input Option<Absyn.Path> pathOpt;
  input list<DAE.Element> dae;
algorithm
  _ := matchcontinue(r, pathOpt, dae)
    // no checking for these!
    case (SCode.R_FUNCTION(), _, _) then ();
    case (SCode.R_EXT_FUNCTION(), _, _) then ();
    case (SCode.R_TYPE(), _, _) then ();
    case (SCode.R_RECORD(), _, _) then ();
    case (SCode.R_PACKAGE(), _, _) then ();
    case (SCode.R_ENUMERATION(), _, _) then ();
    case (SCode.R_PREDEFINED_BOOLEAN(), _, _) then ();
    case (SCode.R_PREDEFINED_INTEGER(), _, _) then ();
    case (SCode.R_PREDEFINED_REAL(), _, _) then ();
    case (SCode.R_PREDEFINED_STRING(), _, _) then ();
    // check anything else
    case (_, pathOpt, dae)
      equation
        true = RTOpts.debugFlag("checkModel");
        checkModelBalancing(pathOpt, dae);
      then ();
    // do nothing if the debug flag checkModel is not set
    case (_, pathOpt, dae) then ();
  end matchcontinue;
end checkModelBalancingFilterByRestriction;
*/

protected function isPartial
  input SCode.Partial partialPrefix;
  input DAE.Mod mods;
  output SCode.Partial outPartial;
algorithm
  outPartial := matchcontinue (partialPrefix,mods)
    case (SCode.PARTIAL(),DAE.NOMOD()) then SCode.PARTIAL();
    case (_,_) then SCode.NOT_PARTIAL();
  end matchcontinue;
end isPartial;

protected function isFunctionInput
  input ClassInf.State classState;
  input Absyn.Direction direction;
  output Boolean functionInput;
algorithm
  functionInput := matchcontinue(classState, direction)
    case (ClassInf.FUNCTION(path = _), Absyn.INPUT()) then true;
    case (_, _) then false;
  end matchcontinue;
end isFunctionInput;

protected function extractClassDefComment
  "This function extracts the comment section from a class definition."
  input Env.Cache cache;
  input Env.Env env;
  input SCode.ClassDef classDef;
  output Option<SCode.Comment> comment;
algorithm
  comment := matchcontinue(cache, env, classDef)
    local 
      Option<SCode.Comment> c;
      list<SCode.Annotation> al;
      Absyn.Path p;
      SCode.ClassDef cd;
      Option<SCode.Comment> cmt;

    case (_, _, SCode.PARTS(annotationLst = al, comment = c))
      then 
        SOME(SCode.CLASS_COMMENT(al, c));

    case (_, _, SCode.CLASS_EXTENDS(composition = SCode.PARTS(annotationLst = al, comment = c)))
      then 
        SOME(SCode.CLASS_COMMENT(al, c));

    case (_, _, SCode.DERIVED(typeSpec = Absyn.TPATH(path = p), comment = c))
      equation
        (_, SCode.CLASS(classDef = cd), _) = Lookup.lookupClass(cache, env, p, true);
        cmt = extractClassDefComment(cache, env, cd);
        cmt = mergeClassComments(c, cmt);
      then
        cmt;

    case (_, _, SCode.DERIVED(comment = c)) then c;
    case (_, _, SCode.ENUMERATION(comment = c)) then c;
    case (_, _, SCode.OVERLOAD(comment = c)) then c;
    case (_, _, SCode.PDER(comment = c)) then c;
  end matchcontinue;
end extractClassDefComment;

protected function mergeClassComments
  "This function merges two comments together. The rule is that the string
  comment is taken from the first comment, and the annotations from both
  comments are merged."
  input Option<SCode.Comment> comment1;
  input Option<SCode.Comment> comment2;
  output Option<SCode.Comment> outComment;
algorithm
  outComment := matchcontinue(comment1, comment2)
    local
      Option<SCode.Annotation> oa1, oa2;
      list<SCode.Annotation> al1, al2;
      Option<String> strcmt;
      Option<SCode.Comment> cmt;
    case (NONE(), _) then comment2;
    case (_, NONE()) then comment1;
    case (SOME(SCode.COMMENT(annotation_ = oa1, comment = strcmt)),
          SOME(SCode.COMMENT(annotation_ = oa2)))
      equation
        al1 = Util.genericOption(oa1);
        al2 = Util.genericOption(oa2);
        al1 = listAppend(al1, al2);
      then
        SOME(SCode.CLASS_COMMENT(al1, SOME(SCode.COMMENT(NONE(), strcmt))));
    case (SOME(SCode.COMMENT(annotation_ = oa1, comment = strcmt)),
          SOME(SCode.CLASS_COMMENT(annotations = al2)))
      equation
        al1 = Util.genericOption(oa1);
        al1 = listAppend(al1, al2);
      then
        SOME(SCode.CLASS_COMMENT(al1, SOME(SCode.COMMENT(NONE(), strcmt))));
    case (SOME(SCode.CLASS_COMMENT(annotations = al1, comment = cmt)),
          SOME(SCode.COMMENT(annotation_ = oa2)))
      equation
        al2 = Util.genericOption(oa2);
        al1 = listAppend(al1, al2);
      then
        SOME(SCode.CLASS_COMMENT(al1, cmt));
    case (SOME(SCode.CLASS_COMMENT(annotations = al1, comment = cmt)),
          SOME(SCode.CLASS_COMMENT(annotations = al2)))
      equation
        al1 = listAppend(al1, al2);
      then
        SOME(SCode.CLASS_COMMENT(al1, cmt));
  end matchcontinue;
end mergeClassComments;

protected function toConst
"Translates SCode.Variability to DAE.Const"
input SCode.Variability inVar;
output DAE.Const outConst;
algorithm
  outConst := matchcontinue (inVar)
    case(SCode.CONST()) then DAE.C_CONST();
    case(SCode.PARAM()) then DAE.C_PARAM();
    case _ then DAE.C_VAR();
  end matchcontinue;
end toConst;

protected function addConnectorVariablesFromDAE
  "If the class state indicates a connector, this function adds all flow
  variables in the dae as inside connectors to the connection sets."
  input ClassInf.State inClassState;
  input DAE.DAElist inDae;
  input list<DAE.Var> inVars;
  input Connect.Sets inConnectionSet;
  input Absyn.Info info;
  output Connect.Sets outConnectionSet;
algorithm
  outConnectionSet := match(inClassState, inDae, inVars, inConnectionSet, info)
    local
      Absyn.Path class_path;
      list<DAE.Element> el, streams, flows;
      Connect.Sets cs;
    case (ClassInf.CONNECTOR(path = class_path), DAE.DAE(elementLst = el), _, cs, _)
      equation
        ConnectUtil.checkConnectorBalance(inVars, class_path, info);
        flows = Util.listFilter(el, DAEUtil.isFlowVar);
        streams = Util.listFilter(el, DAEUtil.isStreamVar);
        cs = Util.listFold(flows, addFlowVariable, cs);
        cs = addStreamFlowAssociations(cs, streams, flows);
      then
        cs;
    else then inConnectionSet;
  end match;
end addConnectorVariablesFromDAE;

protected function addStreamFlowAssociations
  "Adds information to the connection sets about which flow variables each
  stream variable is associated to."
  input Connect.Sets inSets;
  input list<DAE.Element> inStreamVars;
  input list<DAE.Element> inFlowVars;
  output Connect.Sets outSets;
algorithm
  outSets := match(inSets, inStreamVars, inFlowVars)
    local
      DAE.ComponentRef flow_cr;
      list<DAE.ComponentRef> stream_crs;
      Connect.Sets sets;

    // No stream variables => not a stream connector.
    case (_, {}, _) then inSets;

    // Stream variables and exactly one flow => add associations.
    case (_, _, {DAE.VAR(componentRef = flow_cr)})
      equation
        stream_crs = Util.listMap(inStreamVars, DAEUtil.varCref);
        sets = Util.listFold1(stream_crs, ConnectUtil.addStreamFlowAssociation,
          flow_cr, inSets);
      then sets;
  end match;
end addStreamFlowAssociations;

protected function addFlowVariable
  "This function checks if a dae element is a flow variable, and if so it adds
  the variable as an inside connector to the connection sets."
  input DAE.Element inElement;
  input Connect.Sets inConnectionSet;
  output Connect.Sets outConnectionSet;
algorithm
  outConnectionSet := matchcontinue(inElement, inConnectionSet)
    local
      DAE.ComponentRef cr;
      DAE.ElementSource src;
      Connect.Sets cs;
    case (DAE.VAR(componentRef = cr, flowPrefix = DAE.FLOW(), source = src), cs)
      equation
        cs = ConnectUtil.addFlowVariable(cs, cr, Connect.INSIDE(), src);
      then
        cs;
    case (_, _) then inConnectionSet;
  end matchcontinue;
end addFlowVariable;

protected function handleStreamConnectors
  "This function traverses the DAE and replaces calls to inStream and
  actualStream with their evaluated expressions. This can't be done during
  instantiation, since we need to have a complete connection graph until we can
  do that."
  input Boolean isTopScope;
  input Connect.Sets inSets;
  input DAE.DAElist inDAE;
  output DAE.DAElist outDAE;
algorithm
  outDAE := matchcontinue(isTopScope, inSets, inDAE)
    
    case (false, _, _) 
      then 
        inDAE;
    
    // do not do this phase when getHasStreamConnectors() = false
    case (true, _, _) 
      equation
        false = System.getHasStreamConnectors();
      then
        inDAE;
    
    // only do this phase when getHasStreamConnectors() = true
    case (true, _, _)
      equation
        (inDAE, _, _) = DAEUtil.traverseDAE(inDAE, DAEUtil.emptyFuncTree, handleStreamOperators, inSets);
      then
        inDAE;
  end matchcontinue;
end handleStreamConnectors;

protected function handleStreamOperators
  input tuple<DAE.Exp, Connect.Sets> inTuple;
  output tuple<DAE.Exp, Connect.Sets> outTuple;
algorithm
  outTuple := match(inTuple)
    local
      DAE.Exp e;
      Connect.Sets cs;
    case ((e, cs))
      equation
        ((e, cs)) = Expression.traverseExp(e, handleStreamOperatorsExp, cs);
      then
        ((e, cs));
  end match;
end handleStreamOperators;

protected function handleStreamOperatorsExp
  "Helper function to handleStreamConnectors. Checks if the given expression is
  a call to inStream or actualStream, and if so calls the appropriate function
  in ConnectUtil to evaluate the call."
  input tuple<DAE.Exp, Connect.Sets> inTuple;
  output tuple<DAE.Exp, Connect.Sets> outTuple;
algorithm
  outTuple := match(inTuple)
    local
      DAE.ComponentRef cr;
      Connect.Sets sets;
    case ((DAE.CALL(path = Absyn.IDENT("inStream"),
                    expLst = {DAE.CREF(componentRef = cr)}), sets))
      then ((ConnectUtil.evaluateInStream(cr, sets), sets));
    case ((DAE.CALL(path = Absyn.IDENT("actualStream"),
                    expLst = {DAE.CREF(componentRef = cr)}), sets))
      then ((ConnectUtil.evaluateActualStream(cr, sets), sets));
    else then inTuple;
  end match;
end handleStreamOperatorsExp;

protected function makeNonExpSubscript
  input DAE.Subscript inSubscript;
  output DAE.Subscript outSubscript;
algorithm
  outSubscript := match (inSubscript)
  local 
    DAE.Exp e;
    DAE.Subscript subscript;
    case DAE.INDEX(e)
      then DAE.WHOLE_NONEXP(e);
    case (subscript as DAE.WHOLE_NONEXP(_))
      then subscript;
  end match;
end makeNonExpSubscript;

protected function getFunctionAttributes
"Looks at the annotations of an SCode.Element to create the function attributes,
i.e. Inline and Purity"
  input SCode.Element cl;
  input list<DAE.Var> vl;
  output DAE.FunctionAttributes attr;
algorithm
  attr := matchcontinue (cl,vl)
    local
      SCode.Restriction restriction;
      Boolean purity;
      DAE.FunctionBuiltin isBuiltin;
      DAE.InlineType inlineType;
      String name;
      list<DAE.Var> inVars,outVars;
    case (SCode.CLASS(restriction=SCode.R_EXT_FUNCTION()),vl)
      equation
        inVars = Util.listFilter(vl,Types.isInputVar);
        outVars = Util.listFilter(vl,Types.isOutputVar);
        name = SCode.isBuiltinFunction(cl,Util.listMap(inVars,Types.varName),Util.listMap(outVars,Types.varName));
        inlineType = isInlineFunc2(cl);
        purity = not DAEUtil.hasBooleanNamedAnnotation(cl,"__OpenModelica_Impure");
      then (DAE.FUNCTION_ATTRIBUTES(inlineType,purity,DAE.FUNCTION_BUILTIN(SOME(name))));
    case (SCode.CLASS(restriction=restriction),_)
      equation
        inlineType = isInlineFunc2(cl);
        isBuiltin = Util.if_(DAEUtil.hasBooleanNamedAnnotation(cl,"__OpenModelica_BuiltinPtr"), DAE.FUNCTION_BUILTIN_PTR(), DAE.FUNCTION_NOT_BUILTIN());
        purity = not DAEUtil.hasBooleanNamedAnnotation(cl,"__OpenModelica_Impure");
      then DAE.FUNCTION_ATTRIBUTES(inlineType,purity,isBuiltin);
  end matchcontinue;
end getFunctionAttributes;

protected function checkFunctionElement
"Verifies that an element of a function is correct, i.e.
public input/output, protected variable/parameter/constant or algorithm section"
  input DAE.Element elt;
  input Absyn.Info info;
algorithm
  _ := match (elt,info)
    local
      DAE.ComponentRef cr;
      String name,str;
      DAE.ElementSource source;
      // Until we fix warnings, we need to pass these through... Also, it's used in MSL
    case (DAE.VAR(protection=DAE.PUBLIC()),_) then ();
        /*
    case (DAE.VAR(protection=DAE.PUBLIC(),direction=DAE.INPUT()),_) then ();
    case (DAE.VAR(protection=DAE.PUBLIC(),direction=DAE.OUTPUT()),_) then ();
    case (DAE.VAR(protection=DAE.PUBLIC(),direction=DAE.BIDIR(),kind=DAE.VARIABLE()),_)
      equation
        // TODO: Implement warnings for this case...
      then ();
    case (DAE.VAR(source=source,componentRef=cr,protection=DAE.PUBLIC()),_)
      equation
        name = ComponentReference.printComponentRefStr(cr);
        Error.addSourceMessage(Error.FUNCTION_ELEMENT_WRONG_PROTECTION,{name,"public","protected"},DAEUtil.getElementSourceFileInfo(source));
      then fail();
      */
    case (DAE.VAR(protection=DAE.PROTECTED(),direction=DAE.BIDIR()),_) then ();
    case (DAE.VAR(source=source,componentRef=cr,protection=DAE.PROTECTED()),_)
      equation
        name = ComponentReference.printComponentRefStr(cr);
        Error.addSourceMessage(Error.FUNCTION_ELEMENT_WRONG_PROTECTION,{name,"protected","public"},DAEUtil.getElementSourceFileInfo(source));
      then fail();
        
    case (DAE.ALGORITHM(algorithm_=DAE.ALGORITHM_STMTS({DAE.STMT_ASSIGN(exp=DAE.METARECORDCALL(path=_))})),info)
      equation
        // We need to know the inlineType to make a good notification
        // Error.addSourceMessage(true,Error.COMPILER_NOTIFICATION, {"metarecordcall"}, info);
      then ();
    case (DAE.ALGORITHM(algorithm_=_),_) then ();
    else
      equation
        str = DAEDump.dumpElementsStr({elt});
        Error.addSourceMessage(Error.FUNCTION_ELEMENT_WRONG_KIND,{str},info);
      then fail();
  end match;
end checkFunctionElement;

end Inst;
