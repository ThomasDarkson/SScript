/*
 * Copyright (C)2008-2017 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package hscriptBase;

import hscript.backend.MultiMap;
import hscript.backend.FastBinop;
import haxe.ds.*;
import haxe.PosInfos;
import hscriptBase.Expr;
import haxe.Constraints;
import hscript.SScript;

using StringTools;

private enum Stop {
	SBreak;
	SContinue;
	SReturn;
}

private enum SScriptNull {
	Not_NULL;
}

class Interp {
    public var nativeLifetime:Int=0;
	static final defaultVariables:Array<String> = ["null", "true", "false", "trace", "Bool", "Int", "Float", "String", "Dynamic", "Array"];
	public var variables : Map<String,Dynamic>;
	public var finalVariables : Map<String,Dynamic>;
	var locals : Map<String,Dynamic>;
	var localsOuter : Array<Map<String,Dynamic>>;
	var binops : Map<String, Expr -> Expr -> Dynamic >;

	var depth : Int;
	var inTry : Bool;
	var declared : Array<{ n : String, old : Dynamic }>;
	var returnValue : Dynamic;

	var privateAccess : Bool = false;

	var script : SScript;

	var curExpr : Expr;

	var specialObject : {obj:Dynamic , ?includeFunctions:Bool , ?exclusions:Array<String>} = {obj : null , includeFunctions: null , exclusions: null };
	var specialObjectsFields : Array< String > = [];

	var usingMethods : MultiMap< Function > = new MultiMap< Function >();

	var hasPrivateAccess : Bool = false;
	var noPrivateAccess : Bool = false;

	var strictVar : Bool = false;
	var inBool : Bool = false;

	var inCall : Bool = false;
	var currentArg : String;

	var improvedField : Bool = true;

	var interpStringExprCache : Map<String, Expr> = new Map();

	var compiled = false;

	var compiledExprFuncCache : StringMap< Void -> Dynamic > = new StringMap();

	public inline function setScr(s)
	{
		return script = s;
	}

	var resumeError : Bool = false;

	var sandboxed : Bool = false;
	var sandboxBlockedLibs : Int = 0;
	var sandboxExtraBlockedClasses : Array<String> = null;
	var sandboxExtraAllowedClasses : Array<String> = null;
	var sandboxInstructionLimit : Int = 0;
	var sandboxTimeLimitMs : Int = 0;
	var sandboxInstructionCount : Int = 0;
	var sandboxStartTime : Float = 0;

	static inline var SANDBOX_CHECK_EVERY : Int = 200;

	public function resetSandboxLimiter() : Void
	{
		sandboxInstructionCount = 0;
		sandboxStartTime = haxe.Timer.stamp();
	}

	inline function checkSandboxAccess( path : String ) : Void
	{
		if( sandboxed && path != null && !hscript.backend.HScriptSandbox.isAllowed(path, sandboxBlockedLibs, sandboxExtraBlockedClasses, sandboxExtraAllowedClasses) )
			error(ECustom('Class "$path" is not accessible from a sandboxed script'));
	}

	inline function checkSandboxLimits() : Void
	{
		sandboxInstructionCount++;

		if( sandboxInstructionLimit > 0 && sandboxInstructionCount > sandboxInstructionLimit )
			error(ECustom("script exceeded its instruction limit (possible infinite loop)"));
		
		if( sandboxInstructionCount % SANDBOX_CHECK_EVERY != 0 )
			return;

		if( sandboxTimeLimitMs > 0 && (haxe.Timer.stamp() - sandboxStartTime) * 1000 > sandboxTimeLimitMs )
			error(ECustom("script exceeded its time limit"));
	}

	public function new() {
		locals = new Map();
		localsOuter = null;
		declared = new Array();
		resetVariables();
		initOps();
	}

	private function resetVariables(){
		variables = new Map();
		finalVariables = new Map();

		finalVariables.set("__ssNative",new hscript.native.NativeTypes.NativeAPI(function(){return locals==null?-1:nativeLifetime;},function(){return !sandboxed;},function(){return script;}));
        finalVariables.set("null",null);
		finalVariables.set("true",true);
		finalVariables.set("false",false);
		finalVariables.set("trace",Reflect.makeVarArgs(function(el) {
			var inf = posInfos();
			var v = el.shift();
			if( el.length > 0 ) inf.customParams = el;
			haxe.Log.trace(Std.string(v), inf);
		}));
		finalVariables.set("Bool",Bool);
		finalVariables.set("Int",Int);
		finalVariables.set("Float",Float);
		finalVariables.set("String",String);
		finalVariables.set("Dynamic",Dynamic);
		finalVariables.set("Array",Array);
	}

	public function posInfos(): PosInfos {
		if(curExpr != null)
			return cast { fileName : curExpr.origin, lineNumber : curExpr.line };
		return cast { fileName : "SScript", lineNumber : 0 };
	}

	var inFunc : Bool = false;
	var abortFunc : Bool = false;
	var returnedNothing : Bool = true;

	var newFunc = { func : null , arguments : null };

	function initOps() {
		var me = this;
		binops = new Map();
		binops.set("+",function(e1,e2) return FastBinop.add(me.expr(e1), me.expr(e2)));
		binops.set("-",function(e1,e2) return me.expr(e1) - me.expr(e2));
		binops.set("*",function(e1,e2) return me.expr(e1) * me.expr(e2));
		binops.set("/",function(e1,e2) return me.expr(e1) / me.expr(e2));
		binops.set("%",function(e1,e2) return FastBinop.mod(me.expr(e1), me.expr(e2)));
		binops.set("&",function(e1,e2) return FastBinop.band(me.expr(e1), me.expr(e2)));
		binops.set("|",function(e1,e2) return FastBinop.bor(me.expr(e1), me.expr(e2)));
		binops.set("^",function(e1,e2) return FastBinop.bxor(me.expr(e1), me.expr(e2)));
		binops.set("<<",function(e1,e2) return FastBinop.shl(me.expr(e1), me.expr(e2)));
		binops.set(">>",function(e1,e2) return FastBinop.shr(me.expr(e1), me.expr(e2)));
		binops.set(">>>",function(e1,e2) return FastBinop.ushr(me.expr(e1), me.expr(e2)));
		binops.set("==",function(e1,e2) return hscript.native.NativeTypes.unwrap(me.expr(e1)) == hscript.native.NativeTypes.unwrap(me.expr(e2)));
		binops.set("!=",function(e1,e2) return hscript.native.NativeTypes.unwrap(me.expr(e1)) != hscript.native.NativeTypes.unwrap(me.expr(e2)));
		binops.set(">=",function(e1,e2) return me.expr(e1) >= me.expr(e2));
		binops.set("<=",function(e1,e2) return me.expr(e1) <= me.expr(e2));
		binops.set(">",function(e1,e2) return me.expr(e1) > me.expr(e2));
		binops.set("<",function(e1,e2) return me.expr(e1) < me.expr(e2));
		binops.set("||",function(e1,e2) return me.expr(e1) == true || me.expr(e2) == true);
		binops.set("&&",function(e1,e2) return me.expr(e1) == true && me.expr(e2) == true);
		binops.set("=",assign);
		binops.set("is",checkIs);
		binops.set("...",function(e1,e2) return new InterpIterator(me, e1, e2));
		assignOp("+=",function(v1:Dynamic,v2:Dynamic) return FastBinop.add(v1, v2));
		assignOp("-=",function(v1:Float,v2:Float) return v1 - v2);
		assignOp("*=",function(v1:Float,v2:Float) return v1 * v2);
		assignOp("/=",function(v1:Float,v2:Float) return v1 / v2);
		assignOp("%=",function(v1:Float,v2:Float) return v1 % v2);
		assignOp("&=",function(v1,v2) return FastBinop.band(v1, v2));
		assignOp("|=",function(v1,v2) return FastBinop.bor(v1, v2));
		assignOp("^=",function(v1,v2) return FastBinop.bxor(v1, v2));
		assignOp("<<=",function(v1,v2) return FastBinop.shl(v1, v2));
		assignOp(">>=",function(v1,v2) return FastBinop.shr(v1, v2));
		assignOp(">>>=",function(v1,v2) return FastBinop.ushr(v1, v2));
	}

	function checkIs(e1,e2) : Bool
	{
		var me = this;

		if( e1 == null )
			return false;
		if( e2 == null )
			return false;
		var expr1:Dynamic = me.expr(e1);
		var expr2:Dynamic = me.expr(e2);
		if( expr1 == null )
			return false;
		if( expr2 == null )
			return false;

		switch Tools.expr(e2)
		{
			case EIdent("Class"):
				return Tools.isClass(expr1);
			case EIdent("Enum"):
				return Tools.isEnum(expr2);
			case EIdent("Map"):
				return Std.isOfType(expr1, IMap);
			case _:
		}

        if(Std.isOfType(expr2,hscript.native.NativeDescriptor))return Std.isOfType(hscript.native.NativeTypes.unwrap(expr1),(cast expr2:hscript.native.NativeDescriptor).nativeType);
        var scriptType = hscript.native.NativeTypes.scriptName(expr2);
        if(scriptType != null) return scriptTypeMatches(expr1,scriptType);
        return Std.isOfType(hscript.native.NativeTypes.unwrap(expr1), expr2);
	}

	function coalesce(e1,e2) : Dynamic
	{
		var me = this;
		var e1=me.expr(e1);
		var e2=me.expr(e2);
		return e1 == null ? e2:e1;
	}

	function coalesce2(e1:Expr,e2:Expr) : Dynamic {
		switch(Tools.expr(e1)) {
		case EField(receiver,name,fields):
			var resolved = improvedField && fields != null && fields.length > 1 ? findField(fields,"op") : null;
			var object = resolved != null ? resolved : expr(receiver);
			var current = get(object,name);
			return current == null ? set(object,name,expr(e2)) : current;
		default:
			var current = expr(e1);
			return current == null ? assign(e1,e2) : current;
		}
	}

	function setVar( name : String, v : Dynamic ) {
		if( specialObject != null && specialObject.obj != null && specialObjectsFields.contains( name ) ) 
			Reflect.setProperty(specialObject.obj, name, v);
		else
			variables.set(name,v);
	}

	function assign( e1 : Expr, e2 : Expr ) : Dynamic {
		var v = expr(e2);
		switch( Tools.expr(e1) ) {
		case EIdent(id):
			if( !localExists(id) )
			{
				if( finalVariables.exists(id) )
					return error(EInvalidFinal(id));

				var i = 0;
				if( !variables.exists(id) )
					i++;
				if( specialObject != null ) {
					if ( specialObject.obj != null ) {
						if ( !specialObjectsFields.contains( id ) )
							i++;
					}
					else
						i++;
				}
				else
					i++;

				if ( i == 2 )
					error(EUnknownVariable(id));
				setVar(id,v);
			}
			else {
				localSet(id,v);
			}
		case EField(e,f,fields):
			if( improvedField && fields != null && fields.length > 1 )
			{
				var r = findField(fields,'set',f,v);
				if( r != null )
					return r;
			}
			v = set(expr(e),f,v);
		case EArray(e, index):
			var arr:Dynamic = expr(e);
			var index:Dynamic = expr(index);
			if(isMap(arr)) {
				setMapValue(arr, index, v);
			}
			else {
				arr[index] = v;
			}

		default:
			error(EInvalidOp("="));
		}
		return v;
	}

	function assignOp( op, fop : Dynamic -> Dynamic -> Dynamic ) {
		var me = this;
		binops.set(op,function(e1,e2) return me.evalAssignOp(op,fop,e1,e2));
	}

	function evalAssignOp(op,fop,e1,e2) : Dynamic {
		var v = null;
		switch( Tools.expr(e1) ) {
		case EIdent(id):
			var l = localExists(id);
			var current : Dynamic = l ? localGet(id) : expr(e1);
			v = fop(current,expr(e2));
			if( !l )
				setVar(id,v);
			else
				localSet(id,v);
		case EField(e,f,fields):
			var r = null;	
			if( improvedField && fields != null && fields.length > 1 )
				r = findField(fields,"op");
			var obj = r != null ? r : expr(e);
			v = fop(get(obj,f),expr(e2));
			v = set(obj,f,v);
		case EArray(e, index):
			var arr:Dynamic = expr(e);
			var index:Dynamic = expr(index);
			if(isMap(arr)) {
				v = fop(getMapValue(arr, index), expr(e2));
				setMapValue(arr, index, v);
			}
			else {
				v = fop(arr[index],expr(e2));
				arr[index] = v;
			}
		default:
			return error(EInvalidOp(op));
		}
		return v;
	}

	function increment( e : Expr, prefix : Bool, delta : Int ) : Dynamic {
		curExpr = e;
		var e = e.e;
		switch(e) {
		case EIdent(id):
			var l = localExists(id);
			var v : Null<Dynamic> = (l) ? localGet(id) : resolve(id);
			if( prefix ) {
				v = FastBinop.addInt(v, delta);
				if( !l ) setVar(id,v); else localSet(id,v);
			} else
				if( !l ) setVar(id,FastBinop.addInt(v, delta)) else localSet(id,FastBinop.addInt(v, delta));
			return v;
		case EField(e,f,fields):
			var r = null;	
			if( improvedField && fields != null && fields.length > 1 )
				r = findField(fields,"op");
			var obj = r != null ? r : expr(e);
			var v : Dynamic = get(obj,f);
			if( prefix ) {
				v = FastBinop.addInt(v, delta);
				set(obj,f,v);
			} else
				set(obj,f,FastBinop.addInt(v, delta));
			return v;
		case EArray(e, index):
			var arr:Dynamic = expr(e);
			var index:Dynamic = expr(index);
			if(isMap(arr)) {
				var v = getMapValue(arr, index);
				if(prefix) {
					v = FastBinop.addInt(v, delta);
					setMapValue(arr, index, v);
				}
				else {
					setMapValue(arr, index, FastBinop.addInt(v, delta));
				}
				return v;
			}
			else {
				var v = arr[index];
				if( prefix ) {
					v = FastBinop.addInt(v, delta);
					arr[index] = v;
				} else
					arr[index] = FastBinop.addInt(v, delta);
				return v;
			}
		case EConst(c): 
			return error(EInvalidAssign);
		default:
			return error(EInvalidOp((delta > 0)?"++":"--"));
		}
	}

	public function execute( expr : Expr ) : Dynamic {
		depth = 0;
		locals = new Map();
		localsOuter = null;
		declared = new Array();
		if( sandboxed )
			resetSandboxLimiter();
		switch Tools.expr(expr){
			case EBlock(e):
				var imports:Int = 0;
				var pack:Int = 0;
				for(i in e){
					switch Tools.expr(i)
					{
						case EPackage(_):
							if(e.indexOf(i)>0)
								error(EUnexpected("package"));
							else if(pack > 1)
								error(ECustom('Multiple packages has been declared'));
							pack++;
						case EImport(_,_,_) | EImportStar(_) | EUsing(_):
							if(e.indexOf(i)>imports + pack)
								error(EUnexpected("import"));
							imports++;
						case _:
					}
				}
				if(pack > 1)
					error(ECustom('Multiple packages has been declared'));

				var r:Dynamic = null;
				try {
					for( i in e ) {
						if( shouldAbort ) {
							shouldAbort = false;
							break;
						}
						r = this.expr(i);
					}
				} catch( stopErr : Stop ) {
					switch( stopErr ) {
					case SReturn:
						returnedNothing = false;
						r = returnValue;
						returnValue = null;
					default:
					}
				}
				return r;
			case _:
		}
		var r = this.exprReturnOnly(expr);
		return r;
	}

	function exprReturnOnly(e) : Dynamic {
		try {
			return expr(e);
		} catch( e : Stop ) {
			switch( e ) {
			case SReturn:
				returnedNothing = false;
				var v = returnValue;
				returnValue = null;
				return v;
			default:
			}
		}
		return null;
	}

	function exprReturn(e) : Dynamic {
		try {
			return expr(e);
		} catch( e : Stop ) {
			switch( e ) {
			case SBreak: throw "Invalid break";
			case SContinue: throw "Invalid continue";
			case SReturn:
				returnedNothing = false;
				var v = returnValue;
				returnValue = null;
				return v;
			}
		}
		return null;
	}

	var shouldAbort = false;
	function duplicate<T>( h : Map < String, T > ) {
		var h2 = new Map();
		for( k => v in h )
			h2.set(k,v);
		return h2;
	}

	function localExists( id : String ) : Bool {
		if( locals.exists(id) ) return true;
		if( localsOuter != null )
			for( m in localsOuter )
				if( m.exists(id) ) return true;
		return false;
	}

	function localGet( id : String ) : Dynamic {
		if( locals.exists(id) ) return locals.get(id);
		if( localsOuter != null )
			for( m in localsOuter )
				if( m.exists(id) ) return m.get(id);
		return null;
	}

	function localSet( id : String, v : Dynamic ) : Void {
		if( locals.exists(id) ) { locals.set(id, v); return; }
		if( localsOuter != null )
			for( m in localsOuter )
				if( m.exists(id) ) { m.set(id, v); return; }
		locals.set(id, v);
	}

	/*function restore( old : Int ) {
		while( declared.length > old ) {
			var d = declared.pop();
			setLocal(d.n,d.old);
		}
	}*/

	function restore( old : Int ) {
		while( declared.length > old ) {
			var d = declared.pop();
			if( d.old == null )
				locals.remove(d.n);
			else
				locals.set(d.n, d.old);
		}
	}

	inline function error(e : ErrorDef , rethrow=false ) : Dynamic {
		if(resumeError)return null;
		if( curExpr == null )
			curExpr = { origin: {
				if(script.customOrigin != null && script.customOrigin.length > 0)
					script.customOrigin;
				else if(script.scriptFile != null && script.scriptFile.length > 0)
					script.scriptFile;
				else 
					"SScript";
			} , pmin : 0 , pmax : 0 , line : 0 , e : null };
		var e = new Error(e, curExpr.pmin, curExpr.pmax, curExpr.origin, curExpr.line);
		if( rethrow ) this.rethrow(e) else throw e;
		return null;
	}

	inline function rethrow( e : Dynamic ) {
		#if hl
		hl.Api.rethrow(e);
		#else
		throw e;
		#end
	}

	function resolve( id : String ) : Dynamic { 
		if( localExists(id) )
			return localGet(id);
		if( specialObject != null && specialObject.obj != null && specialObjectsFields.contains(id) )
		{
			var field = Reflect.getProperty(specialObject.obj,id);
			return field;
		}
        if(finalVariables.exists(id)) return finalVariables.get(id);
        if(variables.exists(id)) return variables.get(id);
        return error(EUnknownVariable(id));
	}

    function scriptTypeMatches(value:Dynamic,name:String):Bool return hscript.native.NativeTypes.scriptMatches(value,name);

	function catchTypeMatches( err : Dynamic, t : Null<CType> ) : Bool {
		if( t == null )
			return true;

		var typeName = Tools.ctToType(t);
        if(scriptTypeMatches(err,typeName)) return true;
		if( typeName == null || typeName == "Dynamic" )
			return true;

		switch( typeName ) {
			case "String": return Std.isOfType(err, String);
			case "Int": return Std.isOfType(err, Int);
			case "Float": return Std.isOfType(err, Float);
			case "Bool": return Std.isOfType(err, Bool);
			case "Array": return Std.isOfType(err, Array);
			case _:
				var cl : Dynamic = try resolve(typeName) catch( e : Dynamic ) null;
				if( cl == null ) cl = Tools.resolve(typeName);
                if(Std.isOfType(cl,hscript.native.NativeDescriptor))return Std.isOfType(hscript.native.NativeTypes.unwrap(err),(cast cl:hscript.native.NativeDescriptor).nativeType);
                if(cl!=null && Reflect.isObject(cl) && hscript.native.NativeTypes.scriptName(cl)!=null) return false;
				if( cl == null )
					return Tools.getType(err) == typeName;
				else if( Tools.isEnum(cl) )
					return Type.getEnum(err) == cl;
				else
					return Std.isOfType(err, cl);
		}
	}

	function doCast( v : Dynamic, t : CType ) : Dynamic {
		if( v == null )
			return null; 

		var typeName = Tools.ctToType(t);
        if(scriptTypeMatches(v,typeName)) return v;
		if( typeName == null || typeName == "Dynamic" )
			return v;

		inline function fail() : Dynamic {
			return error(ECustom('Cannot cast ${Tools.getType(v)} to $typeName'));
		}

		switch( typeName ) {
			case "String": if( Std.isOfType(v, String) ) return v; else return fail();
			case "Bool": if( Std.isOfType(v, Bool) ) return v; else return fail();
			case "Int":
				if( Std.isOfType(v, Int) ) return v;
				else if( Std.isOfType(v, Float) ) return Std.int(v);
				else return fail();
			case "Float":
				if( Std.isOfType(v, Float) ) {
					var vf:Float = v;
					return vf;
				}
				else if( Std.isOfType(v, Int) ) {
					var vi:Float = cast v;
					return vi;
				}
				else return fail();
			case "Array": if( Std.isOfType(v, Array) ) return v; else return fail();
			case _:
				var cl : Dynamic = try resolve(typeName) catch( e : Dynamic ) null;
				if( cl == null ) cl = Tools.resolve(typeName);
                if(Std.isOfType(cl,hscript.native.NativeDescriptor))return Std.isOfType(hscript.native.NativeTypes.unwrap(v),(cast cl:hscript.native.NativeDescriptor).nativeType)?hscript.native.NativeTypes.unwrap(v):fail();
                if(cl!=null && Reflect.isObject(cl) && hscript.native.NativeTypes.scriptName(cl)!=null) return fail();
				if( cl == null ) return v;
				else if( Reflect.isEnumValue(v) ) {
					if( Type.getEnum(v) == cl ) return v;
					else return fail();
				}
				else {
					var downcast = Std.downcast(v, cl);
					if( downcast == null && v != null ) return fail() else return downcast;
				}
		}
	}

	function matchEnumPattern( pattern : Expr, val : Dynamic, bindings : Array<{ n : String, v : Dynamic }> ) : Bool {
		return switch( Tools.expr(pattern) ) {
			case EIdent("_"):
				true;
			case EIdent("true"), EIdent("false"), EIdent("null"):
                expr(pattern) == val;
            case EIdent(name):
				bindings.push({ n : name, v : val });
				true;
			case ECall(ce, args):
				switch( Tools.expr(ce) ) {
					case EIdent(ctorName), EField(_, ctorName, _):
						var scriptEnum = val != null && Reflect.isObject(val) && Reflect.hasField(val,"__ss_enum");
                        var tag = scriptEnum ? Reflect.field(val,"tag") : (Reflect.isEnumValue(val) ? Type.enumConstructor(val) : null);
                        var ownerType:Dynamic = switch(Tools.expr(ce)) {
                            case EField(owner,_,_): try expr(owner) catch(_:Dynamic) null;
                            default:null;
                        };
                        var expectedType = scriptEnum && ownerType != null ? Reflect.field(ownerType,"__ss_name") : null;
                        if( tag != ctorName || (scriptEnum && expectedType != null && Reflect.field(val,"__ss_enum") != expectedType)
                            || (!scriptEnum && ownerType != null && Type.getEnum(val) != ownerType) )
							false;
						else {
							var params:Array<Dynamic> = scriptEnum ? Reflect.field(val,"params") : Type.enumParameters(val);
							if( params.length != args.length )
								false;
							else {
								var ok = true;
								for( i in 0...args.length ) {
									if( !matchEnumPattern(args[i], params[i], bindings) ) {
										ok = false;
										break;
									}
								}
								ok;
							}
						}
					case _: false;
				}
			case _:
				try expr(pattern) == val catch( e : Dynamic ) false;
		}
	}

	public function expr( e : Expr ) : Dynamic {
		curExpr = e;
		var og = e;
		var e = e.e;
		if( sandboxed )
			checkSandboxLimits();
		switch( e ) {
		case EConst(c):
			switch( c ) {
			case CInt(v): return v;
			case CFloat(f): return f;
			case CString(s): return s;
			}
		case EInterpString(strings, expressions):
			var result = "";
			for (i in 0...strings.length) {
				result += strings[i];
				for (exprData in expressions) {
					if (exprData.index == i + 1) {
						var ex = interpStringExprCache.get(exprData.str);
						if (ex == null) {
							ex = SScript.stringParser.parseString(exprData.str, og.origin, og.line);
							interpStringExprCache.set(exprData.str, ex);
						}
						else {
							ex.line = og.line;
						}
						result += Std.string(expr(ex));
					}
				}
			}
			return result;
		case EEReg(chars, ops):
			#if !(cpp || neko) // not supported on other targets
			ops = ops.split('u').join('');
			#end

			#if (cs || js) // not supported on C# and JavaScript
			ops = ops.split('s').join('');
			#end

			return new EReg(chars,ops);
		case EIdent(id):
			strictVar = true;
			var e = resolve(id);
			strictVar = false;
			return e;
		case EVar(n,f,_,e):
			strictVar = true;
			var expr1 : Dynamic = e == null ? null : expr(e);
			strictVar = false;
			var name = null;

			declared.push({ n : n, old : locals.get(n) });
			locals.set(n,expr1);
			return if( strictVar ) error(EUnexpected(f ? "final" : "var")) else null;
		case EParent(e):
			return expr(e);
		case EBlock(exprs):
			var old = declared.length;
			var v = null;
			for( e in exprs ) {
				if( !shouldAbort )
				{
					v = expr(e);
				}
				else 
				{
					shouldAbort = false;
					restore(old);
					break;
				}
			}
			restore(old);
			return v;
		case EField(e,f,fields):
			if( improvedField && fields != null && fields.length > 1 )
			{
				var r = findField(fields);
				if( r != null )
					return r;
			}
			var r = get(expr(e),f);
			return r;
		case ESwitchBinop(p, e1, e2):
			var parent = expr(p);
			var e1 = expr(e1), e2 = expr(e2);
			if( parent == e1 )
				return e1;
			else if( parent == e2 )
				return e2;
			return null;
		case EBinop(op,e1,e2):
			var c0 = StringTools.fastCodeAt(op, 0);
			switch( op.length ) {
				case 1:
					switch( c0 ) {
						case "+".code: return FastBinop.add(expr(e1), expr(e2));
						case "-".code: return expr(e1) - expr(e2);
						case "*".code: return expr(e1) * expr(e2);
						case "/".code: return expr(e1) / expr(e2);
						case "%".code: return FastBinop.mod(expr(e1), expr(e2));
						case "&".code: return FastBinop.band(expr(e1), expr(e2));
						case "|".code: return FastBinop.bor(expr(e1), expr(e2));
						case "^".code: return FastBinop.bxor(expr(e1), expr(e2));
						case ">".code: return expr(e1) > expr(e2);
						case "<".code: return expr(e1) < expr(e2);
						default:
					}
				case 2:
					var c1 = StringTools.fastCodeAt(op, 1);
					switch( c0 ) {
						case "<".code:
						if( c1 == "<".code ) return FastBinop.shl(expr(e1), expr(e2));
							if( c1 == "=".code ) return expr(e1) <= expr(e2);
						case ">".code:
							if( c1 == ">".code ) return FastBinop.shr(expr(e1), expr(e2));
							if( c1 == "=".code ) return expr(e1) >= expr(e2);
						case "=".code:
							if( c1 == "=".code ) return hscript.native.NativeTypes.unwrap(expr(e1)) == hscript.native.NativeTypes.unwrap(expr(e2));
						case "!".code:
							if( c1 == "=".code ) return hscript.native.NativeTypes.unwrap(expr(e1)) != hscript.native.NativeTypes.unwrap(expr(e2));
						case "|".code:
							if( c1 == "|".code ) return expr(e1) == true || expr(e2) == true;
						case "&".code:
							if( c1 == "&".code ) return expr(e1) == true && expr(e2) == true;
						default:
					}
				case 3:
					if( op == ">>>" ) return FastBinop.ushr(expr(e1), expr(e2));
				default:
			}
			var fop = binops.get(op);
			if( fop == null ) error(EInvalidOp(op));
			return fop(e1,e2);
		case EUnop(op,prefix,e):
			switch(op) {
			case "!":
				var e:Null<Dynamic> = expr(e);
				return !e;
			case "-":
				var e:Null<Dynamic> = expr(e);
				return -e;
			case "++":
				return increment(e,prefix,1);
			case "--":
				return increment(e,prefix,-1);
			case "~":
				var e:Null<Dynamic> = expr(e);
				return FastBinop.bnot(e);
			default:
				error(EInvalidOp(op));
			}
		case ECall(e,params):
			var args = new Array();
			for( p in params )
			{
				args.push(expr(p));
			}
			
			switch( Tools.expr(e) ) {
			case EField(e,f,fields):
				strictVar = true;
				var r = null;
				if( improvedField && fields != null && fields.length > 1 )
					r = findField(fields,"op");

				var obj = r != null ? r : expr(e);
				strictVar = false;
				if( obj == null ) error(EInvalidAccess(f));
				return fcall(obj,f,args);
			case ESafeNavigator(e,f):
				strictVar = true;
				var obj = expr(e);
				strictVar = false;
				if( obj == null ) return null;
				return fcall(obj,f,args);
			default:
				strictVar = true;
				var e = expr(e);
				strictVar = false;
				return call(null,e,args);
			}
		case EIf(econd,e1,e2):
			strictVar = true;
			inBool = true;
			var econd = expr(econd);
			inBool = false;
			strictVar = false;
			return if( econd ) expr(e1) else if( e2 == null ) null else expr(e2);
		case EWhile(econd,e):
			if( strictVar ) return error(EUnexpected("while"));
			whileLoop(econd,e);
			return null;
		case EDoWhile(econd,e):
			if( strictVar ) return error(EUnexpected("do"));
			doWhileLoop(econd,e);
			return null;
		case EFor(v,v2,it,e):
			forLoop(v,v2,it,e);
			return null;
		case EBreak:
			throw SBreak;
		case EContinue:
			throw SContinue;
		case EReturnEmpty:
			if(inFunc) {
				shouldAbort = true;
				return null;
			} else 
			return error(EUnexpected("return"));
		case EReturn(e):
			returnValue = e == null ? null : expr(e);
			throw SReturn;
		case EImportStar(pkg):
			pkg = pkg.trim();
			checkSandboxAccess(pkg);
			var c = Type.resolveClass(pkg);
			var en = Type.resolveEnum(pkg);
			if( c != null )
			{
				var fields = Type.getClassFields(c);
				for( field in fields )
				{
					var f = Reflect.getProperty(c,field);
					if( f != null )
						finalVariables.set(field, f);
				}
			}
			else if( en != null ) 
			{
				var f = Type.getEnumConstructs(en);
				for( field in f )
				{
					var f = Reflect.field(en, field);
					if( f != null ) 
						finalVariables.set(field, f);
				}
			}
			else 
			{
				#if(!macro && !DISABLED_MACRO_SUPERLATIVE && !python)
				var map = @:privateAccess Tools.allClassesAvailable;
				var cl = new Map<String, Class<Dynamic>>();
				for( i => k in map )
				{
					var length = pkg.split('.');
					var length2 = i.split('.');
					
					if( length.length == length2.length )
						continue;
					if( length.length + 1 != length2.length )
						continue;

					var hasSamePkg = true;
					for( i in 0...length.length )
					{
						if(length[i] != length2[i])
						{
							hasSamePkg = false;
							break;
						}
					}
					if( hasSamePkg )
					{
						if( sandboxed && !hscript.backend.HScriptSandbox.isAllowed(i, sandboxBlockedLibs, sandboxExtraBlockedClasses, sandboxExtraAllowedClasses) )
							continue;
						cl[length2[length2.length - 1]] = k;
					}
				}

				for( i => k in cl )
					finalVariables.set(i, k);
				#end
			}

			return if( strictVar ) error(EUnexpected("import")) else null;
		case EImport( e , c , asIdent , f ):
			var og = c;
			if( asIdent != null )
				c = asIdent;
			checkSandboxAccess(f);
			if( c != null && e != null )
				finalVariables.set(c,e);
				
			return if( strictVar ) error(EUnexpected("import")) else null;
		case EUsing( c ):
			checkSandboxAccess(c);
			var cl = Type.resolveClass(c);
			if( cl == null )
				cl = finalVariables.get(c);
			if( cl == null )
				cl = variables.get(c);
			if( cl == null )
				error(ETypeNotFound(c));

			var fields = Reflect.fields(cl);
			if( fields.length == 0 )
				fields = Type.getClassFields(cl);
			for( i in fields ) {
				var f = Reflect.field(cl,i);
				if( f != null && Reflect.isFunction(f) )
					usingMethods.push(i,f);
			}

			return if( strictVar ) error(EUnexpected("using")) else null;
		case EPackage(p):
			if( p == null )
				error(EUnexpected("package"));

			@:privateAccess script.setPackagePath(p);
			return if( strictVar ) error(EUnexpected("package")) else null;
		case EFunction(params,fexpr,name,_,line):
			var closureOuter : Array<Map<String,Dynamic>> = [locals];
			if( localsOuter != null )
				for( m in localsOuter )
					closureOuter.push(m);
			var me = this;
			var hasOpt = false, minParams = 0;
			for( p in params )
				if( p.opt )
					hasOpt = true;
				else if( p.value == null )
					minParams++;
			
			if (compiled && name != null && !compiledExprFuncCache.exists(name) && depth == 0) {
				compiledExprFuncCache.set(name, compileReturn(fexpr));
			}
			var f = function(args:Array<Dynamic>) 
			{
				if(me.locals == null)
					throw "Script function belongs to a destroyed script";
                var oldInFunc = inFunc;			
				var compiledBody = null;
				if( compiled && name != null && depth == 0 ) {
					compiledBody = compiledExprFuncCache.get(name);
				}
				function error(expr)
				{
					curExpr = og;
					if( line != null )
						curExpr.line = line;

					var me = this;
					me.error(expr);
				}

				if( args == null ) error(ENullObjectReference);
 				var copyArgs:Array<Dynamic> = [];
				inFunc = true;
				var i = 0;
				while( true ) {
					if( i < args.length ) {
						var v = args[i];
						if( v == null ) copyArgs.push(Not_NULL);
						else copyArgs.push(v);
						i++;
						if( i >= args.length ) break;
 					}
					else break;
				}
				if( copyArgs.length > params.length ) 
					error(ECustom("Too many arguments"));
					
				for( i in 0...params.length ) {
					var param = params[i];
					
					var arg : Dynamic = ( i < copyArgs.length ) ? copyArgs[i] : null;
					if( param == null ) continue;
					if( param.opt ) {
						if( ( arg == Not_NULL || arg == null ) && param.value != null )
							args[i] = expr(param.value);
						else if( arg == null && param.value == null )
							args[i] = null; 
					}
					else {
						if( arg == null && param.value == null ) {
							var str = "Not enough arguments, expected ";
							str += param.name;
							if( param.t != null )
								str += ":" + Tools.ctToType(param.t);
							error(ECustom(str));
						}
						else if( (arg == null || arg == Not_NULL) && param.value != null )
							args[i] = expr(param.value);
					}
				}
			
				var old = me.locals, oldOuter = me.localsOuter, depth = me.depth;
				me.depth++;
				me.locals = new Map();
				me.localsOuter = closureOuter;
				for( i in 0...params.length )
				{
					currentArg = params[i].name;
					me.locals.set(params[i].name,args[i]);
				}
				var r = null;
				var oldDecl = declared.length;
                try {
                    r = compiledBody != null ? compiledBody() : me.exprReturn(fexpr);
                } catch(e:Dynamic) {
                    restore(oldDecl);
                    me.locals=old;me.localsOuter=oldOuter;me.depth=depth;inFunc=oldInFunc;
                    throw e;
                }
				restore(oldDecl);
				me.locals = old;
				me.localsOuter = oldOuter;
				me.depth = depth;
				inFunc = oldInFunc;
				if( returnedNothing )
				{
					if( strictVar )
						error(ECustom('Void should be Dynamic'));
				}
				else 
					returnedNothing = true;
				return r;
			};
			var body = f;
			var errorOwner = me.script;
			var f = Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic {
				if (errorOwner == null || errorOwner.errorBoundaryDepth > 0) return body(args);
				return errorOwner.withErrorBoundary(function() return body(args));
			});
			if( name != null ) {
				if( depth == 0 ) {
					// global function
					finalVariables.set(name, f);
				} else {
					declared.push( { n : name, old : locals.get(name) } );
					locals.set(name, f);
				}
			}
			return f;
		case EArrayDecl(arr):
			if( arr.length > 0 && Tools.expr(arr[0]).match(EBinop("=>", _)) ) {
				var keys:Array<Dynamic> = [];
				var values:Array<Dynamic> = [];
				var fastKind = 0;
				var first = true;
				var map:Dynamic = null;
				for( e in arr ) {
					switch(Tools.expr(e)) {
						case EBinop("=>", eKey, eValue): {
							var key:Dynamic = expr(eKey);
							var value:Dynamic = expr(eValue);
							if( first ) {
								first = false;
								if( key is String ) fastKind = 1;
								else if( key is Int ) fastKind = 2;
							} else if( fastKind == 1 && !(key is String) ) fastKind = 0
							else if( fastKind == 2 && !(key is Int) ) fastKind = 0;
							keys.push(key);
							values.push(value);
						}
						default: throw("=> expected");
					}
				}
				if( fastKind == 1 ) map = new haxe.ds.StringMap<Dynamic>();
				else if( fastKind == 2 ) map = new haxe.ds.IntMap<Dynamic>();
				else {
					var isAllString:Bool = true;
					var isAllInt:Bool = true;
					var isAllObject:Bool = true;
					var isAllEnum:Bool = true;
					for( key in keys ) {
						isAllString = isAllString && (key is String);
						isAllInt = isAllInt && (key is Int);
						isAllObject = isAllObject && Reflect.isObject(key);
						isAllEnum = isAllEnum && Reflect.isEnumValue(key);
					}
					map = {
						if(isAllInt) new haxe.ds.IntMap<Dynamic>();
						else if(isAllString) new haxe.ds.StringMap<Dynamic>();
						else if(isAllEnum) new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
						else if(isAllObject) new haxe.ds.ObjectMap<Dynamic, Dynamic>();
						else new Map<Dynamic, Dynamic>();
					}
				}
				for( n in 0...keys.length ) {
					setMapValue(map, keys[n], values[n]);
				}
				return map;
			}
			else {
				var a = new Array();
				for( e in arr ) {
					a.push(expr(e));
				}
				return a;
			}
		case EArray(e, index):
			var arr:Dynamic = expr(e);
			var index:Dynamic = expr(index);
			if(isMap(arr)) {
				return getMapValue(arr, index);
			}
			else {
				return arr[index];
			}
		case ENew(cl,params):
			var a = new Array();
			for( e in params )
				a.push(expr(e));

			return cnew(cl,a);
		case EThrow(e):
			throw expr(e);
		case ETry(e,catches):
			var old = declared.length;
			var oldTry = inTry;
			try {
				inTry = true;
				var v : Dynamic = expr(e);
				restore(old);
				inTry = oldTry;
				return v;
			} catch( err : Stop ) {
				inTry = oldTry;
				throw err;
			} catch( err : Dynamic ) {
				restore(old);
				inTry = oldTry;
				for( c in catches ) {
					if( !catchTypeMatches(err, c.t) )
						continue;
					declared.push({ n : c.v, old : locals.get(c.v) });
					locals.set(c.v, err);
					var v : Dynamic = expr(c.e);
					restore(old);
					return v;
				}
				rethrow(err);
				return null;
			}
		case EObject(fl):
			var o = {};
			for( f in fl )
				set(o,f.name,expr(f.e));
			return o;
		case ECoalesce(e1,e2,assign):
			return if( assign ) coalesce2(e1,e2) else coalesce(e1,e2);
		case ESafeNavigator(e1, f):
			var e = expr(e1);
			if( e == null )
			 	return null;

			return get(e,f);
		case ETernary(econd,e1,e2):
			return if( expr(econd) == true ) expr(e1) else expr(e2);
		case ESwitch(e, cases, def):
			var val : Dynamic = expr(e);
			var match = false;
			for( c in cases ) {
				var declOld = declared.length;
				var matchedThisCase = false;
				for( v in c.values )
				{
					if( Type.enumEq(Tools.expr(v),EIdent("_")) )
						continue;
					
					var isCallPattern = switch( Tools.expr(v) ) {
						case ECall(ce,_): switch( Tools.expr(ce) ) { case EIdent(_), EField(_,_,_): true; case _: false; }
						case _: false;
					}

					var bindings : Array<{ n : String, v : Dynamic }> = [];
					var valueMatches = if( isCallPattern && (Reflect.isEnumValue(val) || (val != null && Reflect.isObject(val) && Reflect.hasField(val,"__ss_enum"))) )
						matchEnumPattern(v, val, bindings)
					else
						expr(v) == val;

					if( !valueMatches )
						continue;

					for( b in bindings ) {
						declared.push({ n : b.n, old : locals.get(b.n) });
						locals.set(b.n, b.v);
					}

					if( c.ifExpr != null && expr(c.ifExpr) != true ) {
						restore(declOld);
						continue;
					}

					matchedThisCase = true;
					break;
				}

				if( matchedThisCase ) {
					match = true;
					val = expr(c.expr);
					restore(declOld);
					break;
				}
			}
			if( !match )
				val = def == null ? null : expr(def);
			return val;
		case EMeta(dot,n,args,e):
			var emptyExpr = false;
			if( e == null ) emptyExpr = true;
			if(n == "privateAccess")
				hasPrivateAccess = true;
			else if(n == "noPrivateAccess")
				noPrivateAccess = false;
			var e = if( emptyExpr ) null else expr(e);
			if( n == "privateAccess" )
				hasPrivateAccess = false;
			else if( n == "noPrivateAccess" )
				noPrivateAccess = false;
			return if( emptyExpr && strictVar ) error(ECustom("Excepted expression")) else e;
		case ECast(e,t):
			var v : Dynamic = expr(e);
			return if( t == null ) v else doCast(v, t);
		case EUntyped(e):
			return expr(e);
		case ECheckType(e,_):
			return expr(e);
		}
		return null;
	}

	function compileExpr( e : Expr ) : Void->Dynamic {
		var og = e;
		var inner = compileNode(e);
		if( sandboxed )
			return function() {
				curExpr = og;
				checkSandboxLimits();
				return inner();
			}
		else
			return function() {
				curExpr = og;
				return inner();
			};
	}

	function compileReturn( e : Expr ) : Void->Dynamic {
		var c = compileExpr(e);
		return function() : Dynamic {
			try {
				return c();
			} catch( err : Stop ) {
				switch( err ) {
				case SBreak: throw "Invalid break";
				case SContinue: throw "Invalid continue";
				case SReturn:
					returnedNothing = false;
					var v = returnValue;
					returnValue = null;
					return v;
				}
			}
			return null;
		};
	}

	function compileNode( e : Expr ) : Void->Dynamic {
		var og = e;
		switch( e.e ) {

		case EConst(c):
			switch( c ) {
			case CInt(v): return function() return v;
			case CFloat(f): return function() return f;
			case CString(s): return function() return s;
			}

		case EIdent(id):
			return function() {
				strictVar = true;
				var v = resolve(id);
				strictVar = false;
				return v;
			};
		case EVar(n,f,_,ve):
			var cInit = ve == null ? null : compileExpr(ve);
			return function() {
				strictVar = true;
				var v : Dynamic = cInit == null ? null : cInit();
				strictVar = false;
				declared.push({ n : n, old : locals.get(n) });
				locals.set(n, v);
				return if( strictVar ) error(EUnexpected(f ? "final" : "var")) else null;
			};

		case EParent(pe):
			var c = compileExpr(pe);
			return function() return c();

		case EBlock(exprs):
			var compiled = [for( ex in exprs ) compileExpr(ex)];
			return function() {
				var old = declared.length;
				var v : Dynamic = null;
				for( c in compiled ) {
					if( !shouldAbort )
						v = c();
					else {
						shouldAbort = false;
						restore(old);
						return v;
					}
				}
				restore(old);
				return v;
			};

		case EField(fe,f,fields):
			var cE = compileExpr(fe);
			return function() {
				if( improvedField && fields != null && fields.length > 1 ) {
					var r = findField(fields);
					if( r != null ) return r;
				}
				return get(cE(),f);
			};

		case ESwitchBinop(p, e1, e2):
			var cP = compileExpr(p), c1 = compileExpr(e1), c2 = compileExpr(e2);
			return function() {
				var parent = cP();
				var v1 = c1(), v2 = c2();
				if( parent == v1 ) return v1;
				else if( parent == v2 ) return v2;
				return null;
			};

		case EBinop(op,e1,e2):
			switch( op ) {
			case "+": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.add(c1(), c2());
			case "-": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() - c2();
			case "*": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() * c2();
			case "/": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() / c2();
			case "%": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.mod(c1(), c2());
			case "&": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.band(c1(), c2());
			case "|": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.bor(c1(), c2());
			case "^": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.bxor(c1(), c2());
			case "<<": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.shl(c1(), c2());
			case ">>": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.shr(c1(), c2());
			case ">>>": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return FastBinop.ushr(c1(), c2());
			case "==": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return hscript.native.NativeTypes.unwrap(c1()) == hscript.native.NativeTypes.unwrap(c2());
			case "!=": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return hscript.native.NativeTypes.unwrap(c1()) != hscript.native.NativeTypes.unwrap(c2());
			case ">=": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() >= c2();
			case "<=": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() <= c2();
			case ">": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() > c2();
			case "<": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() < c2();
			case "||": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() == true || c2() == true;
			case "&&": var c1 = compileExpr(e1), c2 = compileExpr(e2); return function() return c1() == true && c2() == true;
			case "=": return compileAssign(e1,e2);
			case "+=": return compileCompoundAssign(op, function(v1:Dynamic,v2:Dynamic) return FastBinop.add(v1, v2), e1, e2);
			case "-=": return compileCompoundAssign(op, function(v1:Float,v2:Float) return v1 - v2, e1, e2);
			case "*=": return compileCompoundAssign(op, function(v1:Float,v2:Float) return v1 * v2, e1, e2);
			case "/=": return compileCompoundAssign(op, function(v1:Float,v2:Float) return v1 / v2, e1, e2);
			case "%=": return compileCompoundAssign(op, function(v1:Float,v2:Float) return v1 % v2, e1, e2);
			case "&=": return compileCompoundAssign(op, function(v1,v2) return FastBinop.band(v1, v2), e1, e2);
			case "|=": return compileCompoundAssign(op, function(v1,v2) return FastBinop.bor(v1, v2), e1, e2);
			case "^=": return compileCompoundAssign(op, function(v1,v2) return FastBinop.bxor(v1, v2), e1, e2);
			case "<<=": return compileCompoundAssign(op, function(v1,v2) return FastBinop.shl(v1, v2), e1, e2);
			case ">>=": return compileCompoundAssign(op, function(v1,v2) return FastBinop.shr(v1, v2), e1, e2);
			case ">>>=": return compileCompoundAssign(op, function(v1,v2) return FastBinop.ushr(v1, v2), e1, e2);
			default:
				var fop = binops.get(op);
				if( fop == null ) error(EInvalidOp(op));
				return function() return fop(e1,e2);
			}

		case EUnop(op,prefix,ue):
			switch(op) {
			case "!":
				var c = compileExpr(ue);
				return function() { var v : Null<Dynamic> = c(); return !v; };
			case "-":
				var c = compileExpr(ue);
				return function() { var v : Null<Dynamic> = c(); return -v; };
			case "++":
				return compileIncrement(ue,prefix,1);
			case "--":
				return compileIncrement(ue,prefix,-1);
			case "~":
				var c = compileExpr(ue);
				return function() { var v : Null<Dynamic> = c(); return FastBinop.bnot(v); };
			default:
				return function() return error(EInvalidOp(op));
			}

		case ECall(ce,params):
			var compiledArgs = [for( p in params ) compileExpr(p)];
			switch( Tools.expr(ce) ) {
			case EField(fe,f,fields):
				var cObj = compileExpr(fe);
				return function() {
					var args = [for( a in compiledArgs ) a()];
					strictVar = true;
					var r : Dynamic = null;
					if( improvedField && fields != null && fields.length > 1 )
						r = findField(fields,"op");
					var obj = r != null ? r : cObj();
					strictVar = false;
					if( obj == null ) error(EInvalidAccess(f));
					return fcall(obj,f,args);
				};
			case ESafeNavigator(fe,f):
				var cObj = compileExpr(fe);
				return function() {
					var args = [for( a in compiledArgs ) a()];
					strictVar = true;
					var obj = cObj();
					strictVar = false;
					if( obj == null ) return null;
					return fcall(obj,f,args);
				};
			default:
				var cFn = compileExpr(ce);
				return function() {
					var args = [for( a in compiledArgs ) a()];
					strictVar = true;
					var fn = cFn();
					strictVar = false;
					return call(null,fn,args);
				};
			}

		case EIf(econd,e1,e2):
			var cCond = compileExpr(econd);
			var cThen = compileExpr(e1);
			var cElse = e2 == null ? null : compileExpr(e2);
			return function() {
				strictVar = true; inBool = true;
				var cond = cCond();
				inBool = false; strictVar = false;
				return if( cond ) cThen() else (cElse == null ? null : cElse());
			};

		case EWhile(econd,e):
			if( strictVar ) return function() return error(EUnexpected("while"));
			var cCond = compileExpr(econd);
			var cBody = compileExpr(e);
			return function() {
				var old = declared.length;
				strictVar = true; inBool = true;
				var ec : Dynamic = cCond();
				inBool = false;
				while( ec ) {
					try {
						cBody();
					} catch( err : Stop ) {
						switch(err) {
						case SContinue:
						case SBreak: break;
						case SReturn: throw err;
						}
					}
					ec = cCond();
				}
				strictVar = false;
				restore(old);
				return null;
			};

		case EDoWhile(econd,e):
			if( strictVar ) return function() return error(EUnexpected("do"));
			var cCond = compileExpr(econd);
			var cBody = compileExpr(e);
			return function() {
				var old = declared.length;
				strictVar = true; inBool = true;
				var ec : Dynamic = cCond();
				inBool = false;
				do {
					try {
						cBody();
					} catch( err : Stop ) {
						switch(err) {
						case SContinue:
						case SBreak: break;
						case SReturn: throw err;
						}
					}
					inBool = true;
					ec = cCond();
					inBool = false;
				} while( ec );
				strictVar = false;
				restore(old);
				return null;
			};

		case EFor(v,v2,it,e):
			var cIt = compileExpr(it);
			var cBody = compileExpr(e);
			return function() {
				var old = declared.length;
				declared.push({ n : v, old : locals.get(v) });
				if( v2 != null )
					declared.push({ n : v2, old : locals.get(v2) });
				strictVar = true;
				var iter = makeIterator(cIt());
				while( iter.hasNext() ) {
					var next = iter.next();
					var key = next;
					if( Reflect.hasField(next,"key") )
					{
						if( v2 == null )
							key = Reflect.getProperty(next,"value");
						else
							key = Reflect.getProperty(next,"key");
					}

					locals.set(v, key);
					if( Reflect.hasField(next,"value") && v2 != null )
						locals.set(v2, Reflect.getProperty(next,"value"));
					try {
						cBody();
					} catch( err : Stop ) {
						switch( err ) {
						case SContinue:
						case SBreak: break;
						case SReturn: throw err;
						}
					}
				}
				strictVar = false;
				restore(old);
				return null;
			};

		case EArray(ae,ie):
			var cA = compileExpr(ae), cI = compileExpr(ie);
			return function() {
				var arr : Dynamic = cA();
				var idx : Dynamic = cI();
				return isMap(arr) ? getMapValue(arr,idx) : arr[idx];
			};

		case ECoalesce(e1,e2,assign):
			return assign ? function() return coalesce2(e1,e2) : function() return coalesce(e1,e2);

		case ESafeNavigator(e1,f):
			var cE = compileExpr(e1);
			return function() {
				var v = cE();
				if( v == null ) return null;
				return get(v,f);
			};

		case ETernary(econd,e1,e2):
			var cCond = compileExpr(econd), c1 = compileExpr(e1), c2 = compileExpr(e2);
			return function() return cCond() == true ? c1() : c2();

		case EBreak:
			return function() : Dynamic { throw SBreak; }

		case EContinue:
			return function() : Dynamic { throw SContinue; }

		case EReturnEmpty:
			return function() {
				if(inFunc) {
					shouldAbort = true;
					return null;
				} else
					return error(EUnexpected("return"));
			};

		case EReturn(re):
			var c = re == null ? null : compileExpr(re);
			return function() : Dynamic {
				returnValue = c == null ? null : c();
				throw SReturn;
			};

		case EArrayDecl(arr):
			if( arr.length > 0 && Tools.expr(arr[0]).match(EBinop("=>", _)) ) {
				var cKeys = new Array<Void->Dynamic>();
				var cValues = new Array<Void->Dynamic>();
				for( e in arr ) {
					switch( Tools.expr(e) ) {
					case EBinop("=>", eKey, eValue):
						cKeys.push(compileExpr(eKey));
						cValues.push(compileExpr(eValue));
					default: throw("=> expected");
					}
				}
				return function() {
					var keys:Array<Dynamic> = [];
					var values:Array<Dynamic> = [];
					var fastKind = 0;
					var first = true;
					var map:Dynamic = null;
					for( n in 0...cKeys.length ) {
						var key:Dynamic = cKeys[n]();
						var value:Dynamic = cValues[n]();
						if( first ) {
							first = false;
							if( key is String ) fastKind = 1;
							else if( key is Int ) fastKind = 2;
						} else if( fastKind == 1 && !(key is String) ) fastKind = 0
						else if( fastKind == 2 && !(key is Int) ) fastKind = 0;
						keys.push(key);
						values.push(value);
					}
					if( fastKind == 1 ) map = new haxe.ds.StringMap<Dynamic>();
					else if( fastKind == 2 ) map = new haxe.ds.IntMap<Dynamic>();
					else {
						var isAllString:Bool = true;
						var isAllInt:Bool = true;
						var isAllObject:Bool = true;
						var isAllEnum:Bool = true;
						for( key in keys ) {
							isAllString = isAllString && (key is String);
							isAllInt = isAllInt && (key is Int);
							isAllObject = isAllObject && Reflect.isObject(key);
							isAllEnum = isAllEnum && Reflect.isEnumValue(key);
						}
						map = {
							if(isAllInt) new haxe.ds.IntMap<Dynamic>();
							else if(isAllString) new haxe.ds.StringMap<Dynamic>();
							else if(isAllEnum) new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
							else if(isAllObject) new haxe.ds.ObjectMap<Dynamic, Dynamic>();
							else new Map<Dynamic, Dynamic>();
						}
					}
					for( n in 0...keys.length ) {
						setMapValue(map, keys[n], values[n]);
					}
					return map;
				};
			}
			else {
				var cElems = [for( e in arr ) compileExpr(e)];
				return function() {
					var a = new Array();
					for( c in cElems )
						a.push(c());
					return a;
				};
			}

		case EObject(fl):
			var cFields = [for( f in fl ) { name: f.name, c: compileExpr(f.e) }];
			return function() {
				var o = {};
				for( f in cFields )
					set(o,f.name,f.c());
				return o;
			};

		case EThrow(e):
			var c = compileExpr(e);
			return function() : Dynamic { throw c(); }

		case ECast(e,t):
			var c = compileExpr(e);
			return if( t == null ) function() : Dynamic return c() else function() : Dynamic return doCast(c(), t);

		case EUntyped(e):
			var c = compileExpr(e);
			return function() return c();

		case ECheckType(e,_):
			var c = compileExpr(e);
			return function() return c();

		default:
			return function() return expr(og);
		}
	}

	function compileIncrement( e : Expr, prefix : Bool, delta : Int ) : Void->Dynamic {
		var og = e;
		switch( Tools.expr(e) ) {
		case EIdent(id):
			return function() {
				curExpr = og;
				var l = localExists(id);
				var v : Null<Dynamic> = (l) ? localGet(id) : resolve(id);
				if( prefix ) {
					v = FastBinop.addInt(v, delta);
					if( !l ) setVar(id,v); else localSet(id,v);
				}
				else {
					var old = v;
					v = FastBinop.addInt(v, delta);
					if( !l ) setVar(id,v); else localSet(id,v);
					return old;
				}
				return v;
			};
		case _: 
			return function() return increment(og,prefix,delta);
		}
	}

	function compileAssign( e1 : Expr, e2 : Expr ) : Void->Dynamic {
		var c2 = compileExpr(e2);
		switch( Tools.expr(e1) ) {
		case EIdent(id):
			return function() {
				var v = c2();
				if( localExists(id) ) {
					localSet(id,v);
				}
				else {
					if( finalVariables.exists(id) )
						return error(EInvalidFinal(id));

					var i = 0;
					if( !variables.exists(id) )
						i++;
					if( specialObject != null ) {
						if ( specialObject.obj != null ) {
							if ( !specialObjectsFields.contains( id ) )
								i++;
						}
						else
							i++;
					}
					else
						i++;

					if( i == 2 )
						error(EUnknownVariable(id));
					setVar(id,v);
				}
				return v;
			};

		case EField(fe,f,fields):
			var cE = compileExpr(fe);
			return function() {
				var v = c2();
				if( improvedField && fields != null && fields.length > 1 )
				{
					var r = findField(fields,"set",f,v);
					if( r != null )
						return r;
				}
				return set(cE(),f,v);
			};

		case EArray(ae, indexE):
			var cA = compileExpr(ae), cI = compileExpr(indexE);
			return function() {
				var v = c2();
				var arr : Dynamic = cA();
				var index : Dynamic = cI();
				if( isMap(arr) )
					setMapValue(arr, index, v);
				else
					arr[index] = v;
				return v;
			};

		default:
			return function() return error(EInvalidOp("="));
		}
	}

	function compileCompoundAssign( op : String, fop : Dynamic -> Dynamic -> Dynamic, e1 : Expr, e2 : Expr ) : Void->Dynamic {
		var c2 = compileExpr(e2);
		switch( Tools.expr(e1) ) {
		case EIdent(id):
			return function() {
				var l = localExists(id);
				var current : Dynamic = l ? localGet(id) : resolve(id);
				var v = fop(current, c2());
				if( !l )
					setVar(id,v);
				else
					localSet(id,v);
				return v;
			};

		case EField(fe,f,fields):
			var cE = compileExpr(fe);
			return function() {
				var r = null;
				if( improvedField && fields != null && fields.length > 1 )
					r = findField(fields,"op");
				var obj = r != null ? r : cE();
				var v = fop(get(obj,f), c2());
				return set(obj,f,v);
			};

		case EArray(ae, indexE):
			var cA = compileExpr(ae), cI = compileExpr(indexE);
			return function() {
				var arr : Dynamic = cA();
				var index : Dynamic = cI();
				if( isMap(arr) ) {
					var v = fop(getMapValue(arr, index), c2());
					setMapValue(arr, index, v);
					return v;
				}
				else {
					var v = fop(arr[index], c2());
					arr[index] = v;
					return v;
				}
			};

		default:
			return function() return error(EInvalidOp(op));
		}
	}

	function doWhileLoop(econd,e) {
		var old = declared.length;
		strictVar = true;
		inBool = true;
		var ec : Dynamic = expr(econd);
		inBool = false;
		#if !cs
		do {
			try {
				expr(e);
			} catch( err : Stop ) {
				switch(err) {
				case SContinue:
				case SBreak: break;
				case SReturn: throw err;
				}
			}
			inBool = true;
			ec = expr(econd);
			inBool = false;
		}
		while( ec );
		#else
		// the compiler forgets to add a semicolon when we do a do while loop for some reason in cs
		// so here is a shitty workaround
		var eccs:Int = 0;
		while( eccs < 1 ) {
			try {
				expr(e);
			} catch( err : Stop ) {
				switch(err) {
				case SContinue:
				case SBreak: break;
				case SReturn: throw err;
				}
			}
			inBool = true;
			ec = expr(econd);
			if( ec ) eccs = 0;
			else eccs = 1;
			inBool = false;
		}
		#end
		strictVar = false;
		restore(old);
	}

	function whileLoop(econd,e) {
		var old = declared.length;
		strictVar = true;
		inBool = true;
		var ec : Dynamic = expr(econd);
		inBool = false;
		while( ec ) {
			try {
				expr(e);
			} catch( err : Stop ) {
				switch(err) {
				case SContinue:
				case SBreak: break;
				case SReturn: throw err;
				}
			}
			ec = expr(econd);
		}
		strictVar = false;
		restore(old);
	}

	function findField(fields : Array<String> , ?mode : String , ?setProp : String , ?val:Dynamic ) : Dynamic 
	{
		var f = fields[0];
		if( f != null && (try resolve(f) catch(e) null) == null )
		{
			var fieldCl:Dynamic = null;
			var cls = [f];
			for( e in 1...fields.length )
			{
				cls.push(fields[e]);

				var cl = cls.join('.');
				var c = Tools.resolve(cl);
				if( c != null )
				{
					checkSandboxAccess(cl);
					fieldCl = c;
					break;
				}
			}

			
			if( fieldCl != null )
			{
				if( cls.length != fields.length )
					for( i in cls.length + (setProp == null && mode != 'op' ? 0 : 1)...fields.length ) {
						var field = fields[i];
						fieldCl = Reflect.getProperty(fieldCl,field);
					}
			}

			if( fieldCl == null )
				return null;

			if( mode == null )
				return fieldCl;
			else if( mode == "set" )
			{
				Reflect.setProperty(fieldCl,setProp,val);
				return val;
			}
			else if( mode == 'op' ) 
				return fieldCl;
			else	
				return null;
		}
		else 
			return null;
	}

	function makeIterator( v : Dynamic ) : Iterator<Dynamic> {
		if( v is IMap )
			return new haxe.iterators.MapKeyValueIterator(v);

		#if((flash && !flash9))
		if( v.iterator != null ) v = v.iterator();
		#else
		if( v.iterator != null ) try v = v.iterator() catch( e : Dynamic ) {};
		#end
		if( v.hasNext == null || v.next == null ) error(EInvalidIterator(v));
		return cast v;
	}

	function forLoop(n,n2,it,e) {
		var old = declared.length;
		declared.push({ n : n, old : locals.get(n) });
		if( n2 != null )
			declared.push({ n : n2, old : locals.get(n2) });
		strictVar = true;
		var it = makeIterator(expr(it));
		while( it.hasNext() ) {
			var next = it.next();
			var key = next;
			if( Reflect.hasField(next,"key") )
			{
				if( n2 == null )
					key = Reflect.getProperty(next,"value");
				else
					key = Reflect.getProperty(next,"key");
			}

			locals.set(n, key);
			if( Reflect.hasField(next,"value") && n2 != null )
				locals.set(n2, Reflect.getProperty(next,"value"));
			try {
				expr(e);
			} catch( err : Stop ) {
				switch( err ) {
				case SContinue:
				case SBreak: break;
				case SReturn: throw err;
				}
			}
		}
		strictVar = false;
		restore(old);
	}

	static inline function isMap(o:Dynamic):Bool {
		return o != null && (o is IMap);
	}

	inline function getMapValue(map:Dynamic, key:Dynamic):Dynamic {
		return cast(map, haxe.Constraints.IMap<Dynamic, Dynamic>).get(key);
	}

	inline function setMapValue(map:Dynamic, key:Dynamic, value:Dynamic):Void {
		cast(map, haxe.Constraints.IMap<Dynamic, Dynamic>).set(key, value);
	}

	 function get( o : Dynamic, f : String ) : Dynamic {
		if( o == null ) error(EInvalidAccess(f));
        if(StringTools.startsWith(f,"__ss_read_"))f="__ss_raw_"+f.substr(10);
        else if(StringTools.startsWith(f,"__ss_write_"))f=f.substr(11);
        if(hscript.native.NativeTypes.special(o))return hscript.native.NativeTypes.read(o,f);
        var receiver=Reflect.field(o,"__ss_receiver"),superFields=Reflect.field(o,"__ss_superfields");
        var superProperty=superFields==null?null:Reflect.field(superFields,f);
        if(receiver!=null && superProperty!=null) {
            var mode:String=Reflect.field(superProperty,"get");
            if(mode=="get")return call(receiver,Reflect.field(o,"get_"+f),[]);
            if(mode=="never")return error(ECustom("Cannot read property '"+f+"'"));
            var binding:hscript.native.NativeBinding=Reflect.field(receiver,"__ss_binding");
            if(!Reflect.hasField(receiver,f) && binding!=null && binding.hasField(f))return binding.readBase(f);
            return Reflect.field(receiver,f);
        }
        var parent=Reflect.field(o,"__ss_parent");
        if(parent!=null && !Reflect.hasField(o,f) && !StringTools.startsWith(f,"__ss_")) return get(parent,f);
		var access = Reflect.field(o,"__ss_access");
        if(access != null) {
            if(StringTools.startsWith(f,"__ss_raw_")) {
                var name=f.substr(9),binding:hscript.native.NativeBinding=Reflect.field(o,"__ss_binding");
                if(!Reflect.hasField(o,name) && binding!=null && binding.hasField(name))return binding.readBase(name);
                return Reflect.field(o,name);
            }
            var prop = Reflect.field(access,f);
            if(prop != null) {
                var mode:String = Reflect.field(prop,"get");
                if(mode == "get") return call(o,Reflect.field(o,"get_"+f),[]);
                if(mode == "null" || mode == "never") error(ECustom("Cannot read property '"+f+"'"));
            }
        }
        var binding:hscript.native.NativeBinding=Reflect.field(o,"__ss_binding");
        if(!Reflect.hasField(o,f) && binding!=null && binding.hasField(f))return Reflect.getProperty(binding.host,f);
        return access!=null?Reflect.field(o,f):Reflect.getProperty(o,f);
	}

	 function set( o : Dynamic, f : String, v : Dynamic ) : Dynamic {
		if( o == null ) error(EInvalidAccess(f));
        if(StringTools.startsWith(f,"__ss_write_"))f="__ss_raw_"+f.substr(11);
        else if(StringTools.startsWith(f,"__ss_read_"))f=f.substr(10);
        if(hscript.native.NativeTypes.special(o)){hscript.native.NativeTypes.write(o,f,v);return v;}
        var receiver=Reflect.field(o,"__ss_receiver"),superFields=Reflect.field(o,"__ss_superfields");
        var superProperty=superFields==null?null:Reflect.field(superFields,f);
        if(receiver!=null && superProperty!=null) {
            var mode:String=Reflect.field(superProperty,"set");
            if(mode=="set"){call(receiver,Reflect.field(o,"set_"+f),[v]);return v;}
            if(mode=="never")return error(ECustom("Cannot write property '"+f+"'"));
            var binding:hscript.native.NativeBinding=Reflect.field(receiver,"__ss_binding");
            if(!Reflect.hasField(receiver,f) && binding!=null && binding.hasField(f)){binding.writeBase(f,v);return v;}
            Reflect.setField(receiver,f,v);return v;
        }
        var parent=Reflect.field(o,"__ss_parent");
        if(parent!=null && !Reflect.hasField(o,f) && !StringTools.startsWith(f,"__ss_")) return set(parent,f,v);
		var access = Reflect.field(o,"__ss_access");
        if(access != null) {
            if(StringTools.startsWith(f,"__ss_raw_")) {
                var name=f.substr(9),binding:hscript.native.NativeBinding=Reflect.field(o,"__ss_binding");
                if(!Reflect.hasField(o,name) && binding!=null && binding.hasField(name)){binding.writeBase(name,v);return v;}
                Reflect.setField(o,name,v);return v;
            }
            var prop = Reflect.field(access,f);
            if(prop != null) {
                var mode:String = Reflect.field(prop,"set");
                if(mode == "set") {call(o,Reflect.field(o,"set_"+f),[v]);return v;}
                if(mode == "null" || mode == "never") error(ECustom("Cannot write property '"+f+"'"));
            }
        }
        var binding:hscript.native.NativeBinding=Reflect.field(o,"__ss_binding");
        if(!Reflect.hasField(o,f) && binding!=null && binding.hasField(f)){Reflect.setProperty(binding.host,f,v);return v;}
        if(access!=null)Reflect.setField(o,f,v);else Reflect.setProperty(o,f,v);
		return v;
	}

	function fcall(o:Dynamic, f:String, args:Array<Dynamic>):Dynamic {
        var method = get(o,f);
        if(method != null) return call(o,method,args);
        var lastError:Dynamic=null;
        for(extension in usingMethods.get(f)) {
            var extended=args.copy();extended.unshift(o);
            try {return call(null,extension,extended);} catch(e:Dynamic) {lastError=e;}
        }
        if(lastError!=null) throw lastError;
        return error(EInvalidAccess(f));
    }

	function call( o : Dynamic, f : Dynamic, args : Array<Dynamic>) : Dynamic {
		return Reflect.callMethod(o,f,[for(a in args)hscript.native.NativeTypes.unwrap(a)]);
	}

	function cnew( cl : String, args : Array<Dynamic> ) : Dynamic {
		if (cl == "Map")
	        return new Map<Dynamic, Dynamic>();

		var c : Dynamic = try resolve(cl) catch(e) null;
		if( c == null ) {
			checkSandboxAccess(cl);
			c = Type.resolveClass(cl);
		}
		if( c == null ) error(EInvalidAccess(cl));

		if(hscript.native.NativeTypes.read(c,"__ss_interface")==true) return error(ECustom("Cannot instantiate interface: "+cl));
        if(Std.isOfType(c,hscript.native.NativeDescriptor)) {
            var descriptor:hscript.native.NativeDescriptor=cast c;
            if(descriptor.isInterface)return error(ECustom("Cannot instantiate interface: "+cl));
            return Reflect.callMethod(null,descriptor.read("__ss_create"),args);
        }
        var factory = hscript.native.NativeTypes.read(c,"__ss_create");
        if(factory != null) return call(c,factory,args);
        return Type.createInstance(c,[for(a in args)hscript.native.NativeTypes.unwrap(a)]);
	}

	function generateSpecialObjectFields() {
		specialObjectsFields = [];
		if( specialObject != null && specialObject.obj != null ) {
			var type = "instance";
			if( Tools.isClass( specialObject.obj ) )
				type = "class";
			else if( Tools.isEnum( specialObject.obj ) )
				type = "enum";
			else if( Type.typeof( specialObject.obj ) == TObject && !Tools.isClassOrEnum( specialObject.obj ) )
				type = "anon";

			var fields : Array< String > = [];

			if( type == "instance")
				fields = try Type.getInstanceFields(Type.getClass(specialObject.obj)) catch(e) [];
			else if( type == "class")
				fields = try Type.getClassFields(specialObject.obj) catch(e) [];
			else if( type == "enum")
				fields = try Type.getEnumConstructs(specialObject.obj) catch(e) [];
			else if( type == "anon")
				fields = try Reflect.fields(specialObject.obj) catch(e) [];

			if( fields == null )
				fields = []; 

			if( fields.length > 0 ) {
				for( i in 0...specialObject.exclusions.length ) {
					var exclusion = specialObject.exclusions[i];
					if( exclusion != null && fields.contains(exclusion) ) fields.remove(exclusion);
				}
				if ( !specialObject.includeFunctions ) {
					for( i in 0...fields.length ) {
						var field = fields[i];
						if (field != null) {
							var f = Reflect.getProperty(specialObject.obj, field);
							if( f != null && Type.typeof(f) == TFunction ) {
								fields.splice(i, 1);
							}
						}
					}
				}
			}

			specialObjectsFields = fields.copy();
		}
	}
}
