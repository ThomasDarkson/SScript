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
import haxe.Exception;
import hscript.SScript;
import hscriptBase.Expr;
using StringTools;

enum Token {
	TEof;
	TConst( c : Const );
	TId( s : String );
	TOp( s : String );
	TEReg( r : String , opt : String );
	TPOpen;
	TPClose;
	TBrOpen;
	TBrClose;
	TDot;
	TComma;
	TStatement;
	TEol;
	TBkOpen;
	TBkClose;
	TQDot;
	TQDouble;
	TQDoubleAssign;
	TQuestion;
	TDoubleDot;
	TMeta( hasDot : Bool , s : String );
}

@:keep
@:access(hscriptBase.Tools)
@:access(hscript.SScript)
class Parser {

	// config / variables
	public var line : Int = 0;
	public var opChars : String;
	public var identChars : String;
	#if haxe3
	public var opPriority : Map<String,Int>;
	public var opRightAssoc : Map<String,Bool>;
	#else
	public var opPriority : Hash<Int>;
	public var opRightAssoc : Hash<Bool>;
	#end

	@:noPrivateAccess var packaged : Bool = false;

	/**
		allow types declarations
	**/
	public var allowTypes : Bool =  true;

	/**
		resume from parsing errors (when parsing incomplete code, during completion for example)
	**/
	public var resumeErrors : Bool = false;

	var inInterp : Bool = false;

	// implementation
	var input : String;
	var readPos : Int;

	var char : Int;
	var ops : Array<Bool>;
	var idents : Array<Bool>;
	var uid : Int = 0;

	var origin : String;
	var tokenMin : Int;
	var tokenMax : Int;
	var oldTokenMin : Int;
	var oldTokenMax : Int;
	var tokens : List<{ min : Int, max : Int, t : Token }>;

	var script : SScript;

	function setScr(scr) script = scr;

	public function new() {
		line = 1;
		opChars = "+*/-=!><&|^%";
		identChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";
		var priorities = [
			["is"], 
			["%"],
			["*", "/"],
			["+", "-"],
			["<<", ">>", ">>>"],
			["|", "&", "^"],
			["==", "!=", ">", "<", ">=", "<="],
			["..."],
			["&&"],
			["||"],
			["=","+=","-=","*=","/=","%=","<<=",">>=",">>>=","|=","&=","^=","=>"],
			["->"],
		];
		#if haxe3
		opPriority = new Map();
		opRightAssoc = new Map();
		#else
		opPriority = new Hash();
		opRightAssoc = new Hash();
		#end
		for( i in 0...priorities.length )
			for( x in priorities[i] ) {
				opPriority.set(x, i);
				if( i == 10 ) opRightAssoc.set(x, true);
			}
		for( x in ["!", "++", "--",] ) // unary "-" handled in parser directly!
			opPriority.set(x, x == "++" || x == "--" ? -1 : -2);
	}

	public inline function error( err, ?pmin, ?pmax ) {
		var e=new Error(err, pmin, pmax, origin, line);
		if( !resumeErrors )
		throw new Error(err, pmin, pmax, origin, line);
	}

	public function invalidChar(c) {
		error(EInvalidChar(c), readPos-1, readPos-1);
	}

	function initParser( origin ) {
		this.origin = origin;
		readPos = 0;
		tokenMin = oldTokenMin = 0;
		tokenMax = oldTokenMax = 0;
		tokens = new List();
		char = -1;
		ops = new Array();
		idents = new Array();
		uid = 0;
		for( i in 0...opChars.length )
			ops[opChars.charCodeAt(i)] = true;
		for( i in 0...identChars.length )
			idents[identChars.charCodeAt(i)] = true;
	}

	public function parseString( s : String, ?origin : String = "SScript" ) {
		initParser(origin);
		input = s;
		readPos = 0;
		var a = new Array();
		while( true ) {
			var tk = token();
			if( tk == TEof ) break;
			push(tk);
			parseFullExpr(a);
		}
		return if( a.length == 1 ) a[0] else mk(EBlock(a),0);
	}

	function unexpected( tk ) : Dynamic {
		error(EUnexpected(tokenString(tk)),tokenMin,tokenMax);
		return null;
	}

	inline function push(tk) {
		tokens.push( { t : tk, min : tokenMin, max : tokenMax } );
		tokenMin = oldTokenMin;
		tokenMax = oldTokenMax;
	}

	inline function ensure(tk) {
		var t = token();
		if( t != tk ) unexpected(t);
	}

	inline function ensureToken(tk) {
		var t = token();
		if( !Type.enumEq(t,tk) ) unexpected(t);
	}

	function maybe(tk) {
		var t = token();
		if( Type.enumEq(t, tk) )
			return true;
		push(t);
		return false;
	}

	function getIdent(?thr = true) {
		var tk = token();
		switch( tk ) {
		case TId(id): return id;
		default:
			if(thr)
			unexpected(tk);
			return null;
		}
	}

	inline function expr(e:Expr) {
		return e.e;
	}

	inline function pmin(e:Expr) {
		return e == null ? 0 : e.pmin;
	}

	inline function pmax(e:Expr) {
		return e == null ? 0 : e.pmax;
	}

	inline function mk(e,?pmin,?pmax) : Expr {
		if( e == null ) return null;
		if( pmin == null ) pmin = tokenMin;
		if( pmax == null ) pmax = tokenMax;
		return { e : e, pmin : pmin, pmax : pmax, origin : origin, line : line };
	}

	function isBlock(e) {
		if( inInterp ) return true;
		if( e == null ) return false;
		return switch( expr(e) ) {
		case EBlock(_), EObject(_), ESwitch(_): true;
		case EFunction(_,e,_,_): isBlock(e);
		case EVar(_,_,_,e): e != null ? isBlock(e) : false;
		case EIf(_,e1,e2): if( e2 != null ) isBlock(e2) else isBlock(e1);
		case EBinop(_,_,e): isBlock(e);
		case EUnop(_,prefix,e): !prefix && isBlock(e);
		case EWhile(_,e): isBlock(e);
		case EDoWhile(_,e): isBlock(e);
		case EFor(_,_,_,e): isBlock(e);
		case EReturn(e): e != null && isBlock(e);
		case ETry(_, _, _, e): isBlock(e);
		case EMeta(_,_,_,e): if( e == null ) true else isBlock(e);
		default: false;
		}
	}

	function parseFullExpr( exprs : Array<Expr> ) {
		var e = parseExpr();
		exprs.push(e);

		var tk = token();
		// this is a hack to support var a,b,c; with a single EVar
		while( tk == TComma && e != null && expr(e).match(EVar(_)) ) {
			e = parseStructure(switch Tools.expr(e) {
				case EVar(_,f,_,_):
					if (f) "final" else "var";
				case _: throw "Something horribly went wrong";
			}); // next variable
			exprs.push(e);
			tk = token();
		}

		if( tk != TStatement && tk != TEof ) {
			if( tk != TBrClose ) { 
				switch e.e {
					case EFunction(_,_,_,_):
					case EVar(_,_,_,_): // allowed
					case _: 
						if( !isBlock(e) ) 
	                		unexpected(tk);
				}
			}
			push(tk);
		}
	}

	function parseObject(p1) {
		// parse object
		var fl = new Array();
		while( true ) {
			var tk = token();
			var id = null;
			switch( tk ) {
			case TId(i): id = i;
			case TBrClose:
				break;
			default:
				unexpected(tk);
				break;
			}
			ensure(TDoubleDot);
			fl.push({ name : id, e : parseExpr() });
			tk = token();
			switch( tk ) {
			case TBrClose:
				break;
			case TComma:
			default:
				unexpected(tk);
			}
		}
		return parseExprNext(mk(EObject(fl),p1));
	}

	function interpolateString(s:String) {
		if (s == null) error(ECustom("Null Object Reference"));
		
		var strings:Array<String> = [];
		var expressions:Array<{ str:String, index:Int }> = [];
		var len = s.length;
		var i = 0;
		var last = 0;

		while (i < len) {
			if (s.charCodeAt(i) == '$'.code) {
				strings.push(s.substring(last, i));
				i++;
				var start = i;

				if (i < len && s.charCodeAt(i) == '{'.code) {
					var depth = 1;
					i++;
					var exprStart = i;
					while (i < len && depth > 0) {
						var c = s.charCodeAt(i);
						if (c == '{'.code) depth++;
						else if (c == '}'.code) depth--;
						i++;
					}
					var exprStr = s.substring(exprStart, i - 1);
					if (exprStr == "") error(ECustom("Expression cannot be empty"));
					expressions.push({ str: exprStr, index: strings.length });
				} else {
					while (i < len) {
						var c = s.charCodeAt(i);
						var isIdent = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
						if (!isIdent) break;
						i++;
					}
					var varName = s.substring(start, i);
					if (varName != "") {
						expressions.push({ str: varName, index: strings.length });
					}
				}
				last = i;
			} else {
				i++;
			}
		}
		strings.push(s.substring(last, len));
		return EInterpString(strings, expressions);
	}

	function parseExpr() {
		var oldPos = readPos;
		var tk = token();
		var p1 = tokenMin;
		switch( tk ) {
		case TId(id):
			var e = parseStructure(id);
			if( e == null )
				e = mk(EIdent(id));
			
			return parseExprNext(e);
		case TEReg(char, op):
			return mk(EEReg(char, op));
		case TConst(c):
			switch c {
				case CString(s, true):
					var e = parseExprNext(mk(interpolateString(s)));
					return e;
				case _:
			}
			return parseExprNext(mk(EConst(c)));
		case TPOpen:
			tk = token();
			if( tk == TPClose ) {
				ensureToken(TOp("->"));
				var eret = parseExpr();
				return mk(EFunction([], mk(EReturn(eret),p1)), p1);
			}
			push(tk);
			var e = parseExpr();
			tk = token();
			switch( tk ) {
			case TPClose:
				return parseExprNext(mk(EParent(e),p1,tokenMax));
			case TDoubleDot:
				var t = parseType();
				tk = token();
				switch( tk ) {
				case TPClose:
					return parseExprNext(mk(ECheckType(e,t),p1,tokenMax));
				case TComma:
					switch( expr(e) ) {
					case EIdent(v): return parseLambda([{ name : v, t : t }], pmin(e));
					default:
					}
				default:
				}
			case TComma:
				switch( expr(e) ) {
				case EIdent(v): return parseLambda([{name:v}], pmin(e));
				default:
				}
			default:

			}
			return unexpected(tk);
		case TBrOpen:
			tk = token();
			switch( tk ) {
			case TBrClose:
				return parseExprNext(mk(EObject([]),p1));
			case TId(_):
				var tk2 = token();
				push(tk2);
				push(tk);
				switch( tk2 ) {
				case TDoubleDot:
					return parseExprNext(parseObject(p1));
				default:
				}
			default:
				push(tk);
			}
			var a = new Array();
			while( true ) {
				parseFullExpr(a);
				tk = token();
				if( tk == TBrClose || (resumeErrors && tk == TEof) )
					break;
				if( tk != TStatement )
					push(tk);
			}
			return mk(EBlock(a),p1);
		case TOp(op):
			if( op == "-" ) {
				var start = tokenMin;
				var e = parseExpr();
				if( e == null )
					return makeUnop(op,e);
				switch( expr(e) ) {
				case EConst(CInt(i)):
					return mk(EConst(CInt(-i)), start, pmax(e));
				case EConst(CFloat(f)):
					return mk(EConst(CFloat(-f)), start, pmax(e));
				default:
					return makeUnop(op,e);
				}
			}
			else if( op == '~' ) {
				return makeUnop(op,parseExpr());
			}
			if( opPriority.get(op) < 0 )
				return makeUnop(op,parseExpr());
			return unexpected(tk);
		case TBkOpen:
			var a = new Array();
			tk = token();
			while( tk != TBkClose && (!resumeErrors || tk != TEof) ) {
				push(tk);
				a.push(parseExpr());
				tk = token();
				if( tk == TComma )
					tk = token();
			}
			if( a.length == 1 && a[0] != null )
				switch( expr(a[0]) ) {
				case EFor(_), EWhile(_), EDoWhile(_):
					var tmp = "__a_" + (uid++);
					var e = mk(EBlock([
						mk(EVar(tmp, false, null, mk(EArrayDecl([]), p1)), p1),
						mapCompr(tmp, a[0]),
						mk(EIdent(tmp),p1),
					]),p1);
					return parseExprNext(e);
				default:
				}
			return parseExprNext(mk(EArrayDecl(a), p1));
		case TMeta(dot,id):
			var args = parseMetaArgs();
			var e = try parseExpr() catch(e) null;
			return mk(EMeta(dot,id,args,e),p1);
		default:
			return unexpected(tk);
		}
	}

	function parseLambda( args : Array<Argument>, pmin ) {
		while( true ) {
			var id = getIdent();
			var t = maybe(TDoubleDot) ? parseType() : null;
			args.push({ name : id, t : t });
			var tk = token();
			switch( tk ) {
			case TComma:
			case TPClose:
				break;
			default:
				unexpected(tk);
				break;
			}
		}
		ensureToken(TOp("->"));
		var eret = parseExpr();
		return mk(EFunction(args, mk(EReturn(eret),pmin)), pmin);
	}

	function parseMetaArgs() {
		var tk = token();
		if( tk != TPOpen ) {
			push(tk);
			return null;
		}
		var args = [];
		tk = token();
		if( tk != TPClose ) {
			push(tk);
			while( true ) {
				args.push(parseExpr());
				switch( token() ) {
				case TComma:
				case TPClose:
					break;
				case tk:
					unexpected(tk);
				}
			}
		}
		return args;
	}

	function mapCompr( tmp : String, e : Expr ) {
		if( e == null ) return null;
		var edef = switch( expr(e) ) {
		case EFor(v, v2,it, e2):
			EFor(v, v2,it, mapCompr(tmp, e2));
		case EWhile(cond, e2):
			EWhile(cond, mapCompr(tmp, e2));
		case EDoWhile(cond, e2):
			EDoWhile(cond, mapCompr(tmp, e2));
		case EIf(cond, e1, e2) if( e2 == null ):
			EIf(cond, mapCompr(tmp, e1), null);
		case EBlock([e]):
			EBlock([mapCompr(tmp, e)]);
		case EParent(e2):
			EParent(mapCompr(tmp, e2));
		default:
			ECall(mk(EField(mk(EIdent(tmp), pmin(e), pmax(e)), "push", []), pmin(e), pmax(e)), [e]);
		}
		return mk(edef, pmin(e), pmax(e));
	}

	function makeUnop( op, e ) {
		if( e == null && resumeErrors )
			return null;
		return switch( expr(e) ) {
		case EBinop(bop, e1, e2): mk(EBinop(bop, makeUnop(op, e1), e2), pmin(e1), pmax(e2));
		case ETernary(e1, e2, e3): mk(ETernary(makeUnop(op, e1), e2, e3), pmin(e1), pmax(e3));
		default: mk(EUnop(op,true,e),pmin(e),pmax(e));
		}
	}

	function makeBinop( op, e1, e ) {
		if( e == null && resumeErrors )
			return mk(EBinop(op,e1,e),pmin(e1),pmax(e1));
		return switch( expr(e) ) {
		case EBinop(op2,e2,e3):
			if( opPriority.get(op) <= opPriority.get(op2) && !opRightAssoc.exists(op) )
				mk(EBinop(op2,makeBinop(op,e1,e2),e3),pmin(e1),pmax(e3));
			else
				mk(EBinop(op, e1, e), pmin(e1), pmax(e));
		case ETernary(e2,e3,e4):
			if( opRightAssoc.exists(op) )
				mk(EBinop(op,e1,e),pmin(e1),pmax(e));
			else
				mk(ETernary(makeBinop(op, e1, e2), e3, e4), pmin(e1), pmax(e));
		default:
			mk(EBinop(op,e1,e),pmin(e1),pmax(e));
		}
	}

	var structures : Array< String > = [];
	function parseStructure(id) {
		structures.push(id);
		var p1 = tokenMin;
		return switch( id ) {
		case "if":
			ensure(TPOpen);
			var cond = parseExpr();
			ensure(TPClose);
			var e1 = parseExpr();
			var e2 = null;
			var semic = false;
			var tk = token();
			if( tk == TStatement ) {
				semic = true;
				tk = token();
			}
			if( Type.enumEq(tk,TId("else")) )
				e2 = parseExpr();
			else {
				push(tk);
				if( semic ) push(TStatement);
			}
			mk(EIf(cond,e1,e2),p1,(e2 == null) ? tokenMax : pmax(e2));
		case "var" | "final":
			var tk = token();
			var ident = switch tk {
				case TId(s): s;
				case TConst(c):
					switch c {
						case CInt(_) | CFloat(_):
							error(ECustom('Missing variable identifier'),tokenMin,tokenMax);
							null;
						case _: null;
					}
				case _:
					error(ECustom('Missing variable identifier'),tokenMin,tokenMax);
					null;
			}
			var tk = token();
			var tp = null;
			if( tk == TDoubleDot && allowTypes ) {
				tp = parseType();
				tk = token();
			}
			var e = null;
			switch (tk)
			{
				case TOp("="): e = parseExpr();
				case TComma | TStatement: push(tk);
				#if static
				if (tp != null) switch(tp){
					case CTPath(p,pr):
					switch(p[0]){
						case "Int":
							e = mk(EConst(CInt(0)));
						case "Bool":
							e = mk(EIdent("false"));
						case "Float":
							e = mk(EConst(CFloat(0.0)));
					}
					default:
				}
				#end
				default: unexpected(tk);
			}
			mk(EVar(ident,id=="final",tp,e),p1,(e == null) ? tokenMax : pmax(e));
		case "while":
			var econd = parseExpr();
			var e = parseExpr();
			mk(EWhile(econd,e),p1,pmax(e));
		case "do":
			var e = parseExpr();
			var tk = token();
			switch(tk)
			{
				case TId("while"): // Valid
				default: unexpected(tk);
			}
			var econd = parseExpr();
			mk(EDoWhile(econd,e),p1,pmax(econd));
		case "for":
			ensure(TPOpen);
			var vname = getIdent();
			var vname2 = null;
			var tk = token();
			switch tk {
				case TOp("=>"): 
					vname2 = getIdent();
				case _: push(tk);
			}
			ensureToken(TId("in"));
			var eiter = parseExpr();
			ensure(TPClose);
			var e = parseExpr();
			mk(EFor(vname,vname2,eiter,e),p1,pmax(e));
		case "break": mk(EBreak);
		case "continue": mk(EContinue);
		case "else": unexpected(TId(id));
		case "function":
			var tk = token();
			var name = null;
			switch( tk ) {
			case TId(id): name = id;
			default: push(tk);
			}
			var inf = parseFunctionDecl();
			mk(EFunction(inf.args,inf.body,name,inf.ret,inf.line),p1,pmax(inf.body));
		case "return":
			var tk = token();
			push(tk);
			var e = if( tk == TStatement ) null else parseExpr();
			if( tk == TStatement )
				mk(EReturnEmpty,p1,tokenMax );
			else 
				mk(EReturn(e),p1,if( e == null ) tokenMax else pmax(e));
		case "new":
			var a = new Array();
			var subIds = new Array();

			a.push(getIdent());
			while( true ) {
				var tk = token();
				switch( tk ) {
				case TDot:
					a.push(getIdent());
				case TPOpen:
					break;
				case TOp("<"):
					while( true ) {
						var t = token();
						switch t {
							case TId(s): subIds.push(s);
							case TComma: t = token();
								switch t {
									case TId(s): subIds.push(s);
									case TOp(">"): break;
									case _: unexpected(t);
								}
							case TOp(">"): break;
							case _: unexpected(t);
						}
					}
				default:
					unexpected(tk);
					break;
				}
			}
			var args = parseExprList(TPClose);
			mk(ENew(a.join("."),args,subIds),p1);
		case "throw":
			var e = parseExpr();
			mk(EThrow(e),p1,pmax(e));
		case "try":
			var e = parseExpr();
			ensureToken(TId("catch"));
			ensure(TPOpen);
			var cname = getIdent();
			var t = null;
			var canensure=true;
			var tk=token();
			if(tk==TDoubleDot &&allowTypes)
			{
				t=parseType();
			}
			else{
				canensure = false;
			}
			if(canensure)ensure(TPClose);
			var ce = parseExpr();
			mk(ETry(e, cname, t, ce), p1, pmax(ce));
		case "switch":
			var parentExpr = parseExpr();
			var def = null, cases = [];
			ensure(TBrOpen);
			while( true ) {
				var tk = token();
				switch( tk ) {
				case TId("case"):
					var c = { values : [], expr : null , ifExpr : null };
					cases.push(c);
					while( true ) {
						var e = parseExpr();
						switch Tools.expr(e) {
							case EBinop("|", e1, e2):
								e = mk(ESwitchBinop(parentExpr, e1, e2));
							case _:
						}
						c.values.push(e);
						tk = token();
						switch( tk ) {
						case TComma:
							// next expr
						case TDoubleDot:
							break;
						case TId("if"):
							var e = parseExpr();
							c.ifExpr = e;
							switch tk = token() {
								case TComma:
								case TDoubleDot: break;
								case _: 
									unexpected(tk);
									break;
							}
						default:
							unexpected(tk);
							break;
						}
					}
					var exprs = [];
					while( true ) {
						tk = token();
						push(tk);
						switch( tk ) {
						case TId("case"), TId("default"), TBrClose:
							break;
						case TEof if( resumeErrors ):
							break;
						default:
							parseFullExpr(exprs);
						}
					}
					c.expr = if( exprs.length == 1)
						exprs[0];
					else if( exprs.length == 0 )
						mk(EBlock([]), tokenMin, tokenMin);
					else
						mk(EBlock(exprs), pmin(exprs[0]), pmax(exprs[exprs.length - 1]));

					for( i in c.values )
					{
						switch Tools.expr(i) {
							case EIdent("_"):
								def = c.expr;
							case _:
						}
					}
				case TId("default"):
					if( def != null ) unexpected(tk);
					ensure(TDoubleDot);
					var exprs = [];
					while( true ) {
						tk = token();
						push(tk);
						switch( tk ) {
						case TId("case"), TId("default"), TBrClose:
							break;
						case TEof if( resumeErrors ):
							break;
						default:
							parseFullExpr(exprs);
						}
					}
					def = if( exprs.length == 1)
						exprs[0];
					else if( exprs.length == 0 )
						mk(EBlock([]), tokenMin, tokenMin);
					else
						mk(EBlock(exprs), pmin(exprs[0]), pmax(exprs[exprs.length - 1]));
				case TBrClose:
					break;
				default:
					unexpected(tk);
					break;
				}
			}
			mk(ESwitch(parentExpr, cases, def), p1, tokenMax);
		
		case "using":
			var path = getIdent();
			if( path == null || path.length < 1 )
				error(EInvalidAccess(path));

			var c = Type.resolveClass(path);
			if( c == null )
				error(ECustom('Invalid class $path'));

			return mk(EUsing(c,path));
		case "import":
			var path = [getIdent()];
			var isStar = false;
			var asIdent = null;
			while( true ) {
				var t = token();
				if( t != TDot ) {
					push(t);
					break;
				}
				t = token();
				switch( t ) {
				case TId(id):
					path.push(id);
				case TOp('*'):
					isStar = true;
					var tk = token();
					if( tk == TStatement ) push(tk);
					else if( tk != TEof ) unexpected(tk);
					break;
				default:
					unexpected(t);
				}
			}
			
			if( isStar )
			{
				return mk(EImportStar(path.join('.')));
			}

			var tk = token();
			if( tk == TStatement ) push(tk);
			else if( Type.enumEq(tk,TId('as')) ) {
				var tk = token();
				switch tk {
					case TId(s): asIdent = s;
					case _: unexpected(tk);
				}
			}

			var fullName = path.join('.');
			var cl = Tools.resolve(fullName);
			if( cl == null ) {
				var fields = [];
				var fieldCl = null;
				for( i in path ) {
					fields.push(i);
					var cl = Tools.resolve(fields.join('.'));
					if( cl != null ) {
						fieldCl = cl;
						break;
					}
				}
				for( i in fields.length...path.length ) {
					var field = path[i];
					fieldCl = Reflect.getProperty(fieldCl,field);
				}

				cl = fieldCl;
			}
			return mk(EImport(cl,path[path.length-1],asIdent,fullName)); 
		case "package":
			var path = [getIdent(false)];
			if (!path.contains(null))
				while( true ) {
					var t = token();
					if( t != TDot ) {
						push(t);
						break;
					}
					t = token();
					switch( t ) {
					case TId(id):
						path.push(id);
					default:
						unexpected(t);
					}
				}
			else readPos--;

			var ppath:String="";
			if (path.length > 1) for (i in path)
			{
				ppath+=i+".";
			} else ppath = try path[0] catch(e) "";
			var spath = ppath.split('');
			spath[spath.length-1] = StringTools.replace(spath[spath.length-1],'.','');
			return mk(EPackage(spath.join('')));
		default:
			null;
		}
	}

	function parseExprNext( e1 : Expr ) {
		var tk = token();
		switch( tk ) {
		case TOp(op):
			if( op == "->" ) {
				// single arg reinterpretation of `f -> e` , `(f) -> e` and `(f:T) -> e`
				switch( expr(e1) ) {
				case EIdent(i), EParent(expr(_) => EIdent(i)):
					var eret = parseExpr();
					return mk(EFunction([{ name : i }], mk(EReturn(eret),pmin(eret))), pmin(e1));
				case ECheckType(expr(_) => EIdent(i), t):
					var eret = parseExpr();
					return mk(EFunction([{ name : i, t : t }], mk(EReturn(eret),pmin(eret))), pmin(e1));
				default:
				}
				unexpected(tk);
			}

			if( opPriority.get(op) == -1 ) {
				if( isBlock(e1) || switch(expr(e1)) { case EParent(_): true; default: false; } ) {
					push(tk);
					return e1;
				}
				return parseExprNext(mk(EUnop(op,false,e1),pmin(e1)));
			}
			return makeBinop(op,e1,parseExpr());
		case TDot:
			var field = getIdent();
			var pushed = false;
			var fields = switch Tools.expr(e1) {
				case EField(_,_,fAll):
					var f = fAll.copy();
					f.push(field);
					pushed = true;
					f;
				case _: [];
			}

			switch Tools.expr(e1) {
				case EIdent(v): fields.push(v);
				case _:
			}
			if (!pushed)
				fields.push(field);
			return parseExprNext(mk(EField(e1,field,fields),pmin(e1)));
		case TPOpen:
			return parseExprNext(mk(ECall(e1,parseExprList(TPClose)),pmin(e1)));
		case TBkOpen:
			var e2 = parseExpr();
			ensure(TBkClose);
			return parseExprNext(mk(EArray(e1,e2),pmin(e1)));
		case TQuestion:
			var e2 = parseExpr();
			ensure(TDoubleDot);
			var e3 = parseExpr();
			return mk(ETernary(e1,e2,e3),pmin(e1),pmax(e3));
		case TQDouble:
			var e2 = parseExpr();
			return mk(ECoalesce(e1,e2,false), pmin(e1));
		case TQDoubleAssign:
			var e2 = parseExpr();
			return mk(ECoalesce(e1,e2,true), pmin(e1));
		case TQDot:
			var oldPos_ = readPos;
			var tk = token();
			switch tk {
				case TId(s):
					//push(tk);
					return mk(ESafeNavigator(e1, s), pmin(e1));
				case _:
			}

			unexpected(tk);
			return null; 
		default:
			push(tk);
			return e1;
		}
	}

	function parseFunctionArgs() {
		var args = new Array();
		var tk = token();
		if( tk != TPClose ) {
			var done = false;
			while( !done ) {
				var name = null, opt = false;
				switch( tk ) {
				case TQuestion:
					opt = true;
					tk = token();
				default:
				}
				switch( tk ) {
				case TId(id): name = id;
				default:
					unexpected(tk);
					break;
				}
				var arg : Argument = { name : name };
				args.push(arg);
				if( opt ) arg.opt = true;
				if( allowTypes ) {
					if( maybe(TDoubleDot) )
						arg.t = parseType();
					if( maybe(TOp("=")) )
					{
						arg.value = parseExpr();
						switch arg.value.e {
							case EConst(_):
							case EIdent("null"):
							case _: error(ECustom('Default argument value should be constant'));
						}
						//arg.opt = true;
					}
				}
				tk = token();
				switch( tk ) {
				case TComma:
					tk = token();
				case TPClose:
					done = true;
				default:
					unexpected(tk);
				}
			}
		}
		return args;
	}

	function parseFunctionDecl() {
		ensure(TPOpen);
		var args = parseFunctionArgs();
		var ret = null;
		var line:Null<Int> = this.line;
		if( allowTypes ) {
			var tk = token();
			if( tk != TDoubleDot )
				push(tk);
			else
				ret = parseType();
		}
		return { args : args, ret : ret, body : parseExpr() , line : line };
	}

	function parsePath() {
		var path = [getIdent()];
		while( true ) {
			var t = token();
			if( t != TDot ) {
				push(t);
				break;
			}
			path.push(getIdent());
		}
		return path;
	}

	function parseType() : CType {
		var t = token();
		switch( t ) {
		case TId(v):
			push(t);
			var path = parsePath();
			var params = null;
			t = token();
			switch( t ) {
			case TOp(op):
				if( op == "<" ) {
					params = [];
					while( true ) {
						params.push(parseType());
						t = token();
						switch( t ) {
						case TComma: continue;
						case TOp(op):
							if( op == ">" ) break;
							if( op.charCodeAt(0) == ">".code ) {
								tokens.add({ t : TOp(op.substr(1)), min : tokenMax - op.length - 1, max : tokenMax });
								break;
							}
						default:
						}
						unexpected(t);
						break;
					}
				} else {
					//if(v==v.toLowerCase())throw "Type " + op + " cannot be lowercase.";
					push(t);
				}
			default:
				push(t);
			}
			return parseTypeNext(CTPath(path, params));
		case TPOpen:
			var a = token(),
					b = token();

			push(b);
			push(a);

			function withReturn(args) {
				switch token() { // I think it wouldn't hurt if ensure used enumEq
					case TOp('->'):
					case t: unexpected(t);
				}

				return CTFun(args, parseType());
			}

			switch [a, b] {
				case [TPClose, _] | [TId(_), TDoubleDot]:

					var args = [for (arg in parseFunctionArgs()) {
						switch arg.value {
							case null:
							case v:
								error(ECustom('Default values not allowed in function types'), v.pmin, v.pmax);
						}

						CTNamed(arg.name, if (arg.opt) CTOpt(arg.t) else arg.t);
					}];

					return withReturn(args);
				default:

					var t = parseType();
					return switch token() {
						case TComma:
							var args = [t];

							while (true) {
								args.push(parseType());
								if (!maybe(TComma)) break;
							}
							ensure(TPClose);
							withReturn(args);
						case TPClose:
							parseTypeNext(CTParent(t));
						case t: unexpected(t);
					}
			}
		case TBrOpen:
			var fields = [];
			var meta = null;
			while( true ) {
				t = token();
				switch( t ) {
				case TBrClose: break;
				case TId("var"):
					var name = getIdent();
					ensure(TDoubleDot);
					fields.push( { name : name, t : parseType(), meta : meta } );
					meta = null;
					ensure(TStatement);
				case TId(name):
					ensure(TDoubleDot);
					fields.push( { name : name, t : parseType(), meta : meta } );
					t = token();
					switch( t ) {
					case TComma:
					case TBrClose: break;
					default: unexpected(t);
					}
				case TMeta(_,name):
					if( meta == null ) meta = [];
					meta.push({ name : name, params : parseMetaArgs() });
				default:
					unexpected(t);
					break;
				}
			}
			return parseTypeNext(CTAnon(fields));
		default:
			return unexpected(t);
		}
	}

	function parseTypeNext( t : CType ) {
		var tk = token();
		switch( tk ) {
		case TOp(op):
			if( op != "->" ) {
				push(tk);
				return t;
			}
		default:
			push(tk);
			return t;
		}
		var t2 = parseType();
		switch( t2 ) {
		case CTFun(args, _):
			args.unshift(t);
			return t2;
		default:
			return CTFun([t], t2);
		}
	}

	function parseExprList( etk ) {
		var args = new Array();
		var tk = token();
		if( tk == etk )
			return args;
		push(tk);
		while( true ) {
			args.push(parseExpr());
			tk = token();
			switch( tk ) {
			case TComma:
			default:
				if( tk == etk ) break;
				unexpected(tk);
				break;
			}
		}
		return args;
	}

	// ------------------------ lexing -------------------------------

	inline function readChar() {
		return StringTools.fastCodeAt(input, readPos++);
	}

	function readString( until ) {
		var c = 0;
		var b = new StringBuf();
		var esc = false;
		var old = line;
		var s = input;
		var p1 = readPos - 1;
		while( true ) {
			var c = readChar();
			if( StringTools.isEof(c) ) {
				line = old;
				error(EUnterminatedString, p1, p1);
				break;
			}
			if( esc ) {
				esc = false;
				switch( c ) {
					case 'n'.code: b.addChar('\n'.code);
					case 'r'.code: b.addChar('\r'.code);
					case 't'.code: b.addChar('\t'.code);
					case "'".code, '"'.code, '\\'.code: b.addChar(c);
					default: invalidChar(c);
				}
			} else if( c == 92 )
				esc = true;
			else if( c == until )
				break;
			else {
				if( c == 10 )
					line++;

				b.addChar(c);
			}
		}
		return new String(b.toString());
	}

	function token() {
		var t = tokens.pop();
		if( t != null ) {
			tokenMin = t.min;
			tokenMax = t.max;
			return t.t;
		}
		oldTokenMin = tokenMin;
		oldTokenMax = tokenMax;
		tokenMin = (this.char < 0) ? readPos : readPos - 1;
		var t = _token();
		switch t {
			case TId("is"):
				t = TOp("is");
			case _:
		}
		tokenMax = (this.char < 0) ? readPos - 1 : readPos - 2;
		return t;
	}

	function _token() {
		var char;
		if( this.char < 0 )
			char = readChar();
		else {
			char = this.char;
			this.char = -1;
		}
		while( true ) {
			if( StringTools.isEof(char) ) {
				this.char = char;
				return TEof;
			}
			switch( char ) {
			case 0:
				return TEof;
			case 32,9,13: // space, tab, CR
				tokenMin++;
			case 10: line++; // LF
				tokenMin++;
			case 48,49,50,51,52,53,54,55,56,57: // 0...9
				var n = (char - 48) * 1.0;
				var exp = 0.;
				while( true ) {
					char = readChar();
					exp *= 10;
					switch( char ) {
					case 48,49,50,51,52,53,54,55,56,57:
						n = n * 10 + (char - 48);
					case "e".code, "E".code:
						var tk = token();
						var pow : Null<Int> = null;
						switch( tk ) {
						case TConst(CInt(e)): pow = e;
						case TOp("-"):
							tk = token();
							switch( tk ) {
							case TConst(CInt(e)): pow = -e;
							default: push(tk);
							}
						default:
							push(tk);
						}
						if( pow == null )
							invalidChar(char);
						return TConst(CFloat((Math.pow(10, pow) / exp) * n * 10));
					case ".".code:
						if( exp > 0 ) {
							// in case of '0...'
							if( exp == 10 && readChar() == ".".code ) {
								push(TOp("..."));
								var i = Std.int(n) & 0xFFFFFFFF;
								return TConst( (i == n) ? CInt(i) : CFloat(n) );
							}
							invalidChar(char);
						}
						exp = 1.;
					case "x".code:
						if( n > 0 || exp > 0 )
							invalidChar(char);
						// read hexa
						#if haxe3
						var n = 0;
						while( true ) {
							char = readChar();
							switch( char ) {
							case 48,49,50,51,52,53,54,55,56,57: // 0-9
								n = (n << 4) + char - 48;
							case 65,66,67,68,69,70: // A-F
								n = (n << 4) + (char - 55);
							case 97,98,99,100,101,102: // a-f
								n = (n << 4) + (char - 87);
							default:
								this.char = char;
								return TConst(CInt(n & 0xFFFFFFFF));
							}
						}
						#else
						var n = haxe.Int32.ofInt(0);
						while( true ) {
							char = readChar();
							switch( char ) {
							case 48,49,50,51,52,53,54,55,56,57: // 0-9
								n = haxe.Int32.add(haxe.Int32.shl(n,4), cast (char - 48));
							case 65,66,67,68,69,70: // A-F
								n = haxe.Int32.add(haxe.Int32.shl(n,4), cast (char - 55));
							case 97,98,99,100,101,102: // a-f
								n = haxe.Int32.add(haxe.Int32.shl(n,4), cast (char - 87));
							default:
								this.char = char;
								// we allow to parse hexadecimal Int32 in Neko, but when the value will be
								// evaluated by Interpreter, a failure will occur if no Int32 operation is
								// performed
								var v = try CInt(haxe.Int32.toInt(n)) catch( e : Dynamic ) CInt32(n);
								return TConst(v);
							}
						}
						#end
					default:
						this.char = char;
						var i = Std.int(n);
						return TConst( (exp > 0) ? CFloat(n * 10 / exp) : ((i == n) ? CInt(i) : CFloat(n)) );
					}
				}

			case ";".code: return TStatement;
			case "(".code: return TPOpen;
			case ")".code: return TPClose;
			case ",".code: return TComma;
			case ".".code:
				char = readChar();
				switch( char ) {
				case 48,49,50,51,52,53,54,55,56,57:
					var n = char - 48;
					var exp = 1;
					while( true ) {
						char = readChar();
						exp *= 10;
						switch( char ) {
						case 48,49,50,51,52,53,54,55,56,57:
							n = n * 10 + (char - 48);
						default:
							this.char = char;
							return TConst( CFloat(n/exp) );
						}
					}
				case ".".code:
					char = readChar();
					if( char != ".".code )
						invalidChar(char);
					return TOp("...");
				default:
					this.char = char;
					return TDot;
				}
			case "~".code: 
				char = readChar();
				if( char == '/'.code ) {
					var chars = [];
					var optChars = [""];
					while( true ) {
						var char = readChar();
						var buf = new StringBuf();

						function escapeSequences(c,?buf)
						{
							if( c == ".".code )
							{
								chars.push(".");
							}
							else if( c == "n".code )
							{
								chars.push("\n");
							}
							else if( c == "t".code )
							{
								chars.push("\t");
							}
							else if( c == "r".code )
							{
								chars.push("\r");
							}
							else 
							{
								chars.push("\\" + String.fromCharCode(c));
							}
							if( buf != null )
								buf.add(chars.pop());
						}

						if( char == "[".code || char == "(".code || char == "{".code )
						{
							buf.add(String.fromCharCode(char));
							var oldChar = String.fromCharCode(char);
							while( true )
							{
								var char = readChar();
								if( char == "\\".code )
								{
									var c = readChar();
									escapeSequences(c,buf);
								}
								else
									buf.add(String.fromCharCode(char));

								if( (oldChar == "[" && char == "]".code)
									|| (oldChar == "(" && char == ")".code)
									|| (oldChar == "{" && char == "}".code) )
								{
									chars.push(buf.toString());
									buf = null;
									break;
								}
							}
						}
						else if( char == "\\".code )
						{
							var c = readChar();
							escapeSequences(c);
						}
						else if( char == "/".code )
						{
							while( true ) {
								var flags = ["g".code, "i".code, "s".code, "u".code, "m".code];
								var c = readChar();

								if( !flags.contains(c) )
								{
									readPos--;
									break;
								}
								else 
									optChars.push(String.fromCharCode(c));
							}
							break;
						}	
						else 
							chars.push(String.fromCharCode(char));
					}
					return TEReg(chars.join(""), optChars.join(""));
				}
				else 
				{
					readPos--;
					return TOp("~");
				}
			case "{".code: return TBrOpen;
			case "}".code: return TBrClose;
			case "[".code: return TBkOpen;
			case "]".code: return TBkClose;
			case "'".code, '"'.code: return TConst( CString(readString(char), char==39) );
			case "?".code: 
				char = readChar();
				if( char == '.'.code )
					return TQDot;
				else if ( char == '?'.code )
				{
					char = readChar();

					if( char == '='.code )
						return TQDoubleAssign;
					else
						readPos--;

					return TQDouble;
				}

				this.char = char;
				return TQuestion;
			case ":".code: return TDoubleDot;
			case '='.code:
				char = readChar();
				if( char == '='.code )
					return TOp("==");
				else if ( char == '>'.code )
					return TOp("=>");
				
				this.char = char;
				return TOp("=");
			case '@'.code:
				char = readChar();
				var dot = char == ':'.code;
				if( idents[char] || char == ':'.code ) {
					var id = char == ':'.code ? "" : String.fromCharCode(char);
					while( true ) {
						char = readChar();
						if( !idents[char] ) {
							this.char = char;
							return TMeta(dot,id);
						}
						id += String.fromCharCode(char);
					}
				}
				invalidChar(char);
			default:
				if( ops[char] ) {
					var op = String.fromCharCode(char);
					while( true ) {
						char = readChar();
						if( StringTools.isEof(char) ) char = 0;
						if( !ops[char] ) {
							this.char = char;
							return TOp(op);
						}
						var pop = op;
						op += String.fromCharCode(char);
						if( !opPriority.exists(op) && opPriority.exists(pop) ) {
							if( op == "//" || op == "/*" )
								return tokenComment(op,char);
							this.char = char;
							return TOp(pop);
						}
					}
				}
				if( idents[char] ) {
					var id = String.fromCharCode(char);
					while( true ) {
						char = readChar();
						if( StringTools.isEof(char) ) char = 0;
						if( !idents[char] ) {
							this.char = char;
							return TId(id);
						}
						id += String.fromCharCode(char);
					}
				}
				invalidChar(char);
			}
			char = readChar();
		}
		return null;
	}

	function tokenComment( op : String, char : Int ) {
		var c = op.charCodeAt(1);
		var s = input;
		if( c == '/'.code ) { // comment
			while( char != '\r'.code && char != '\n'.code ) {
				char = readChar();
				if( StringTools.isEof(char) ) break;
			}
			this.char = char;
			return token();
		}
		if( c == '*'.code ) { /* comment */
			var old = line;
			if( op == "/**/" ) {
				this.char = char;
				return token();
			}
			while( true ) {
				while( char != '*'.code ) {
					if( char == '\n'.code ) line++;
					char = readChar();
					if( StringTools.isEof(char) ) {
						line = old;
						error(EUnterminatedComment, tokenMin, tokenMin);
						break;
					}
				}
				char = readChar();
				if( StringTools.isEof(char) ) {
					line = old;
					error(EUnterminatedComment, tokenMin, tokenMin);
					break;
				}
				if( char == '/'.code )
					break;
			}
			return token();
		}
		this.char = char;
		return TOp(op);
	}

	static function constString( c ) {
		return switch(c) {
		case CInt(v): Std.string(v);
		case CFloat(f): Std.string(f);
		case CString(s): s; // TODO : escape + quote
		#if !haxe3
		case CInt32(v): Std.string(v);
		#end
		}
	}

	public static function tokenString( t ) {
		return switch( t ) {
		case TEReg(r,op): return "~/" + r + "/" + op;
		case TEof: "<eof>";
		case TConst(c): constString(c);
		case TId(s): s;
		case TOp(s): s;
		case TPOpen: "(";
		case TPClose: ")";
		case TBrOpen: "{";
		case TBrClose: "}";
		case TDot: ".";
		case TComma: ",";
		case TStatement: ";";
		case TBkOpen: "[";
		case TBkClose: "]";
		case TQDot: "?.";
		case TQDouble: "??";
		case TQDoubleAssign: "??=";
		case TQuestion: "?";
		case TDoubleDot: ":";
		case TMeta(dot,id): "@" + (if( dot ) ":" else "") + id;
		case TEol: null;
		}
	}
}
