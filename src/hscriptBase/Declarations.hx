package hscriptBase;

import hscriptBase.Expr;

typedef ScriptMember = {
	var name : String;
	var owner : String;
	var stat : Bool;
	var over : Bool;
	var fin : Bool;
	var method : Bool;
	var value : Null<Expr>;
	var args : Array<Argument>;
	var type : Null<CType>;
	var get : Null<String>;
	var set : Null<String>;
}

typedef ScriptTypeInfo = {
	var name : String;
	var parent : Null<String>;
	var isInterface : Bool;
	var fields : Map<String, ScriptMember>;
	var args : Array<Argument>;
	var types : Array<String>;
	var nativeName : String;
	var nativeBase : String;
	var nativeInterfaces : Array<String>;
	var nativeKey : String;
}

@:access(hscriptBase.Parser)
class Declarations {
	var p : Parser;
	var info : ScriptTypeInfo;

	public function new( p : Parser ) this.p = p;

	function mk( e : ExprDef ) : Expr return p.mk(e);

	function id( s : String ) : Expr return mk(EIdent(s));

	function str( s : String ) : Expr return mk(EConst(CString(s)));

	function field( o : Expr, s : String ) : Expr return mk(EField(o, s, []));

	function put( o : String, s : String, v : Expr ) : Expr return mk(EBinop("=", field(id(o), s), v));

	function obj( names : Array<String>, values : Array<Expr> ) : Expr return mk(EObject([for( i in 0...names.length ) {name: names[i], e: values[i]}]));

	function call( fn : Expr, args : Array<Expr> ) : Expr return mk(ECall(fn, args));

	function ret( e : Expr ) : Expr return mk(EReturn(e));

	function func( args : Array<Argument>, body : Array<Expr> ) : Expr return mk(EFunction(args, mk(EBlock(body))));

	function fail( message : String ) : Dynamic {
		p.error(ECustom(message));
		return null;
	}

	function known( name : String, iface : Bool ) : ScriptTypeInfo {
		if( p.nativeNames.exists(name) ) name = p.nativeNames.get(name);
		var t = p.scriptTypes.get(name);
		if( t == null && name.indexOf(".") >= 0 ) {
			var shortName = name.split(".").pop();
			var candidate = p.scriptTypes.get(shortName);
			if( candidate != null && candidate.nativeName == name ) t = candidate;
		}
		if( t == null || t.isInterface != iface ) return fail("Expected previously declared script " + (iface ? "interface: " : "class: ") + name);
		return t;
	}

	function normalizeType( t : CType ) : CType return switch( t ) {
		case CTPath(path, args):
			var name = path.join(".");
			if( p.nativeNames.exists(name) ) name = p.nativeNames.get(name);
			for( info in p.scriptTypes ) if( info.nativeName != ""
				&& (name == info.nativeName || name == info.name) ) name = info.nativeName;
			CTPath(name.split("."), args == null ? null : [for( a in args ) normalizeType(a)]);
		case CTFun(args, ret): CTFun([for( a in args ) normalizeType(a)], normalizeType(ret));
		case CTOpt(t): CTOpt(normalizeType(t));
		case CTParent(t): CTParent(normalizeType(t));
		default: t;
	}

	function typeCompatible( a : Null<CType>,
			b : Null<CType> ) : Bool return a == null
			|| b == null
			|| haxe.Serializer.run(normalizeType(a)) == haxe.Serializer.run(normalizeType(b));

	function compatible( actual : ScriptMember, required : ScriptMember ) : Bool {
		if( actual.stat || actual.method != required.method || !typeCompatible(actual.type, required.type) ) return false;
		if( actual.method ) {
			if( actual.args.length != required.args.length ) return false;
			for( i in 0...actual.args.length ) {
				var a = actual.args[i], b = required.args[i];
				if( !typeCompatible(a.t, b.t) || ((b.opt == true || b.value != null) && a.opt != true && a.value == null) ) return false;
			}
		} else {
			var rg = required.get == null ? "default" : required.get,
				rs = required.set == null ? "default" : required.set;
			var ag = actual.get == null ? "default" : actual.get,
				as = actual.set == null ? "default" : actual.set;
			if( (rg == "get" || rg == "default") && ag != "get" && ag != "default" ) return false;
			if( (rs == "set" || rs == "default") && as != "set" && as != "default" ) return false;
		}
		return true;
	}

	function flags( f : ScriptMember ) : Int return (f.stat ? 1 : 0) | (f.get == "null" ? 2 : 0) | (f.set == "null" ? 4 : 0);

	function shared( cls : String ) : Expr return mk(EVar(cls, false, null, call(field(id("__ssShared"), "type"), [str(cls)])));

	public function parse( isEnum : Bool, isInterface : Bool = false, isNative : Bool = false, isShared : Bool = false ) : Expr {
		var cls = p.getIdent(),
			nativeName = "",
			nativeParents : Array<String> = [];
		if( isNative ) {
			p.ensure(TPOpen);
			nativeName = switch( p.token() ) {
				case TConst(CString(v, _)): v;
				default: fail("Expected native type name");
			};
			while( p.maybe(TComma) ) nativeParents.push( switch( p.token() ) {
				case TConst(CString(v, _)): v;
				default: fail("Expected native interface name");
			});
			p.ensure(TPClose);
		}
		if( p.declaredTypeNames.exists(cls) ) fail("Duplicate type: " + cls);
		p.declaredTypeNames.set(cls, true);
		var parent : Null<String> = null, interfaces : Array<String> = [];
		while( true ) {
			if( p.maybe(TId("extends")) ) {
				if( isEnum ) fail("Enums cannot extend types");
				if( isInterface ) {
					do {
						interfaces.push(p.parsePath().join("."));
					} while( p.maybe(TComma) );
				} else {
					if( parent != null ) fail("A class can extend only one class");
					parent = p.parsePath().join(".");
				}
			} else if( p.maybe(TId("implements")) ) {
				if( isEnum || isInterface ) fail("Only classes can implement interfaces");
				do {
					interfaces.push(p.parsePath().join("."));
				} while( p.maybe(TComma) );
			} else break;
		}
		p.ensure(TBrOpen);
		if( isEnum ) {
			var result = parseEnum(cls);
			return isShared ? shared(cls) : result;
		}
		var base = parent == null ? null : known(parent, false);
		if( base != null ) parent = base.name;
		interfaces = [for( n in interfaces ) known(n, true).name];
		info = {
			name: cls,
			parent: parent,
			isInterface: isInterface,
			fields: [],
			args: [],
			types: [cls],
			nativeName: nativeName,
			nativeBase: "",
			nativeInterfaces: [],
			nativeKey: ""
		};
		if( isNative ) {
			if( isInterface ) info.nativeInterfaces = [nativeName].concat(nativeParents);
			else info.nativeBase = nativeName;
		}
		if( base != null ) {
			info.nativeBase = base.nativeBase;
			info.nativeInterfaces = base.nativeInterfaces.copy();
			for( n => f in base.fields ) if( n != "new" ) info.fields.set(n, f);
			for( t in base.types ) if( info.types.indexOf(t) < 0 ) info.types.push(t);
		}
		for( n in interfaces ) {
			var i = known(n, true);
			for( t in i.nativeInterfaces ) if( info.nativeInterfaces.indexOf(t) < 0 ) info.nativeInterfaces.push(t);
			for( t in i.types ) if( info.types.indexOf(t) < 0 ) info.types.push(t);
			if( isInterface ) for( name => f in i.fields ) {
				var prev = info.fields.get(name);
				if( prev != null && (!compatible(prev, f) || !compatible(f, prev)) ) fail("Conflicting interface member: " + name);
				info.fields.set(name, f);
			}
		}
		var own : Array<ScriptMember> = [], seen : Map<String, Bool> = [];
		while( !p.maybe(TBrClose) ) {
			if( p.maybe(TStatement) ) continue;
			var stat = false, over = false, sealed = false, word = p.getIdent();
			while( ["public", "private", "static", "inline", "override", "sealed"].indexOf(word) >= 0 ) {
				if( word == "sealed" ) sealed = true;
				if( word == "static" ) stat = true;
				if( word == "override" ) over = true;
				word = p.getIdent();
			}
			var f : ScriptMember = {
				name: p.getIdent(),
				owner: cls,
				stat: stat,
				over: over,
				fin: word == "final" || sealed,
				method: word == "function",
				value: null,
				args: [],
				type: null,
				get: null,
				set: null
			};
			if( isInterface && (stat || over || f.fin || f.name == "new") ) fail("Invalid interface member: " + f.name);
			if( f.method ) {
				p.ensure(TPOpen);
				f.args = p.parseFunctionArgs();
				if( p.maybe(TDoubleDot) ) f.type = p.parseType();
				if( isInterface || isNative ) p.ensure(TStatement);
				else f.value = mk(EFunction(f.args, p.parseExpr(), null, f.type, p.line));
			} else if( word == "var" || word == "final" ) {
				if( p.maybe(TPOpen) ) {
					f.get = p.getIdent();
					p.ensure(TComma);
					f.set = p.getIdent();
					p.ensure(TPClose);
				} else if( f.fin ) {
					f.get = "default";
					f.set = "never";
				}
				if( f.get != null
					&& (["default", "get", "null", "never"].indexOf(f.get) < 0
						|| ["default", "set", "null", "never"].indexOf(f.set) < 0) ) fail("Unsupported property accessor");
				if( f.fin && f.set != "never" ) fail("Final property requires a never setter: " + f.name);
				if( p.maybe(TDoubleDot) ) f.type = p.parseType();
				var init = p.maybe(TOp("="));
				if( isInterface && init ) fail("Interface fields cannot have initializers");
				if( init ) f.value = p.parseExpr();
				p.ensure(TStatement);
			} else fail("Expected class or interface member");
			if( StringTools.startsWith(f.name, "__ss_") || seen.exists(f.name) ) fail("Invalid or duplicate member: " + f.name);
			if( f.name == "new" && (stat || !f.method) ) fail("Invalid constructor");
			var inherited = info.fields.get(f.name);
			if( f.over
				&& (inherited == null || !inherited.method || !f.method || stat || inherited.stat) ) fail("Nothing to override: " + f.name);
			if( inherited != null ) {
				var declaring = p.scriptTypes.get(inherited.owner);
				if( !f.method && declaring != null && declaring.nativeName != "" ) fail("Cannot redeclare native field: " + f.name);
				if( f.stat != inherited.stat || f.method != inherited.method ) fail("Incompatible inherited member: " + f.name);
				if( f.method
					&& (inherited.fin || !compatible(f, inherited) || !compatible(inherited, f)) ) fail("Incompatible override: " + f.name);
				if( !f.method
					&& (inherited.fin
						|| !typeCompatible(f.type, inherited.type)
						|| (!f.stat && !compatible(f, inherited))) ) fail("Incompatible inherited field: " + f.name);
			}
			seen.set(f.name, true);
			own.push(f);
			info.fields.set(f.name, f);
		}
		if( isNative ) {
			var ctor = info.fields.get("new");
			info.args = ctor == null ? [] : ctor.args;
			p.scriptTypes.set(cls, info);
			return mk(EVar(cls, false, null, call(field(id("__ssNative"), "type"), [str(nativeName)])));
		}
		if( isInterface ) {
			p.scriptTypes.set(cls, info);
			if( isShared ) return shared(cls);
			return mk(EVar(cls, false, null, obj(["__ss_name", "__ss_interface"], [str(cls), id("true")])));
		}
		for( f in info.fields ) {
			if( f.get == "get" ) validateAccessor(f, "get_" + f.name, 0);
			if( f.set == "set" ) validateAccessor(f, "set_" + f.name, 1);
		}
		for( i in interfaces ) for( name => required in known(i, true).fields ) {
			var actual = info.fields.get(name);
			if( actual == null || !compatible(actual, required) ) fail("Class " + cls + " does not implement " + i + "." + name);
		}
		var ctor = info.fields.get("new");
		info.args = ctor == null ? (base == null ? [] : base.args) : ctor.args;
		if( ctor != null && base != null ) {
			var calls = superCalls(ctor.value);
			if( calls == 0 ) {
				for( a in base.args ) if( a.opt != true && a.value == null ) fail("Constructor must call super(...) in " + cls);
				switch( ctor.value.e ) {
					case EFunction(a, b, n, t, l):
						ctor.value = mk(EFunction(a, mk(EBlock([call(id("super"), []), b])), n, t, l));
					default:
				}
			} else {
				if( calls > 1 ) fail("Constructor can call super(...) only once");
				var first : Expr = switch( ctor.value.e ) {
					case EFunction(_, body, _, _, _): switch( body.e ) {
							case EBlock(list): list.length == 0 ? null : list[0];
							default: body;
						}
					default: null;
				};
				var direct = first != null && switch( first.e ) {
					case ECall(fn, _): switch( fn.e ) {
							case EIdent("super"): true;
							default: false;
						}
					default: false;
				};
				if( !direct ) fail("super(...) must be the first constructor statement");
			}
		}
		if( info.nativeBase != "" || info.nativeInterfaces.length > 0 ) {
			info.nativeInterfaces.sort(Reflect.compare);
			info.nativeKey = info.nativeBase + "|" + info.nativeInterfaces.join(",");
			if( !p.nativeAdapters.exists(info.nativeKey)
				&& !p.nativeAdapters.exists("*") ) fail("Register this native adapter at application build time: " + info.nativeKey);
		}
		p.scriptTypes.set(cls, info);
		if( isShared ) return shared(cls);
		return lower(cls, own, ctor);
	}

	public function parseAdapter() : Expr {
		p.ensure(TPOpen);
		var key = switch( p.token() ) {
			case TConst(CString(v, _)): v;
			default: fail("Expected native adapter key");
		};
		p.ensure(TPClose);
		p.nativeAdapters.set(key, true);
		return mk(EVar("__ss_adapter" + (p.uid++), false, null, id("null")));
	}

	public function parseNativeAlias() : Expr {
		p.ensure(TPOpen);
		var source = switch( p.token() ) {
			case TConst(CString(v, _)): v;
			default: fail("Expected native source name");
		};
		p.ensure(TComma);
		var target = switch( p.token() ) {
			case TConst(CString(v, _)): v;
			default: fail("Expected native runtime name");
		};
		p.ensure(TPClose);
		p.nativeNames.set(source, target);
		return mk(EVar("__ss_alias" + (p.uid++), false, null, id("null")));
	}

	function parseEnum( cls : String ) : Expr {
		var names = [], values : Array<Expr> = [], index = 0;
		while( !p.maybe(TBrClose) ) {
			var name = p.getIdent();
			if( names.indexOf(name) >= 0 || StringTools.startsWith(name, "__ss_") ) fail("Invalid or duplicate enum constructor: " + name);
			var callable = p.maybe(TPOpen),
				args : Array<Argument> = callable ? p.parseFunctionArgs() : [];
			p.ensure(TStatement);
			var val = obj(["__ss_enum", "tag", "index", "params"], [
				str(cls),
				str(name),
				mk(EConst(CInt(index++))),
				mk(EArrayDecl([for( a in args ) id(a.name)]))
			]);
			names.push(name);
			values.push(callable ? mk(EFunction(args, ret(val))) : val);
		}
		names.push("__ss_name");
		values.push(str(cls));
		return mk(EVar(cls, false, null, obj(names, values)));
	}

	function superCalls( e : Expr ) : Int {
		if( e == null ) return 0;
		var count = 0;
		function walk( v : Dynamic ) : Void {
			if( v == null ) return;
			if( Std.isOfType(v, Array) ) {
				for( x in (cast v : Array<Dynamic>) ) walk(x);
				return;
			}
			if( Reflect.isObject(v) && Reflect.hasField(v, "pmin") ) {
				var ex : Expr = cast v;
				switch( ex.e ) {
					case ECall(fn, _) if( switch( fn.e ) {
							case EIdent("super"): true;
							default: false;
						} ):
						count++;
					default:
				}
				for( a in Type.enumParameters(ex.e) ) walk(a);
				return;
			}
			if( Type.typeof(v) == TObject ) for( f in Reflect.fields(v) ) walk(Reflect.field(v, f));
		}
		walk(e);
		return count;
	}

	function validateAccessor( property : ScriptMember, name : String, arity : Int ) : Void {
		var method = info.fields.get(name);
		if( method == null || !method.method || method.stat != property.stat ) fail("Missing accessor: " + name);
		if( method.args.length != arity ) fail("Invalid accessor arity: " + name + " (expected " + arity + ")");
	}

	function defaultFieldValue( type : Null<CType> ) : Expr return switch( type ) {
		case CTPath(["Int"], _): mk(EConst(CInt(0)));
		case CTPath(["Float"], _): mk(EConst(CFloat(0.0)));
		case CTPath(["Bool"], _): id("false");
		default: id("null");
	}

	function lower( cls : String, own : Array<ScriptMember>, ctor : Null<ScriptMember> ) : Expr {
		var members : Map<String, Int> = [];
		for( name => f in info.fields ) members.set(name, flags(f));
		var build : Array<Expr> = [], setup : Array<Expr> = [];
		for( f in own ) if( f.method && f.name != "new" )
			(f.stat ? setup : build).push(put(f.stat ? cls : "__ss_self", f.name, refs(f.value, members, [], cls, f.name)));
		var props : Array<Array<String>> = [[], []],
			modes : Array<Array<Expr>> = [[], []];
		for( f in info.fields ) if( f.get != null && !f.stat ) {
			props[0].push(f.name);
			modes[0].push(obj(["get", "set"], [str(f.get), str(f.set)]));
		}
		for( f in own ) if( f.get != null && f.stat ) {
			props[1].push(f.name);
			modes[1].push(obj(["get", "set"], [str(f.get), str(f.set)]));
		}
		build.push(put("__ss_self", "__ss_access", obj(props[0], modes[0])));
		setup.push(put(cls, "__ss_access", obj(props[1], modes[1])));
		for( f in own ) if( !f.method && !f.stat ) build.push(put("__ss_self", "__ss_raw_" + f.name, defaultFieldValue(f.type)));
		for( f in own ) if( !f.method && !f.stat && f.value != null ) build.push(put("__ss_self", "__ss_raw_" + f.name,
			refs(f.value, members, [], cls, f.name)));
		var constructor = ctor != null ? refs(ctor.value, members, ["__ss_ctor_root"], cls,
			"new") : info.parent != null ? field(id("__ss_super"), "__ss_ctor") : func([], []);
		var superNames : Array<String> = [], superValues : Array<Expr> = [];
		for( name => f in info.fields ) if( !f.method && !f.stat ) {
			superNames.push(name);
			superValues.push(obj(["get", "set"], [str(f.get == null ? "default" : f.get), str(f.set == null ? "default" : f.set)]));
		}
		var names = ["__ss_ctor", "__ss_receiver", "__ss_superfields"],
			values = [constructor, id("__ss_self"), obj(superNames, superValues)];
		for( name => f in info.fields ) if( f.method && !f.stat && name != "new" ) {
			names.push(name);
			values.push(field(id("__ss_self"), name));
		}
		build.push(ret(obj(names, values)));
		var base = info.parent == null ? id("null") : call(field(id(info.parent), "__ss_build"), [id("__ss_self")]);
		var builder = func([{name: "__ss_self"}], [ret(call(func([{name: "__ss_super"}], build), [base]))]);
		setup.push(put(cls, "__ss_build", builder));
		var createBody = [put("__ss_self", "__ss_access", obj([], []))];
		if( info.nativeKey != "" ) createBody.push(put("__ss_self", "__ss_binding",
			call(field(id("__ssNative"), "prepare"), [id("__ss_self"), str(info.nativeKey)])));
		createBody.push(mk(EVar("__ss_prepared", false, null, call(field(id("__ss_class_scope"), "__ss_build"), [id("__ss_self")]))));
		if( info.nativeKey != "" && info.nativeBase == "" ) createBody.push(call(field(id("__ssNative"), "construct"),
			[field(id("__ss_self"), "__ss_binding")]));
		createBody.push(call(field(id("__ss_prepared"), "__ss_ctor"), [for( a in info.args ) id(a.name)]));
		createBody.push(ret(info.nativeKey == "" ? id("__ss_self") : call(field(id("__ssNative"), "finish"), [id("__ss_self")])));
		if( info.nativeKey != "" ) {
			var before = createBody.splice(0, 2),
				guarded = mk(EBlock(createBody));
			var cleanup = mk(EBlock([
				call(field(id("__ssNative"), "cancel"), [field(id("__ss_self"), "__ss_binding")]),
				mk(EThrow(id("__ss_nativeError")))
			]));
			createBody = before.concat([mk(ETry(guarded, [{v: "__ss_nativeError", t: null, e: cleanup}]))]);
		}
		var self = obj(["__ss_class", "__ss_types", "__ss_nativeKey"], [str(cls), mk(EArrayDecl([for( t in info.types ) str(t)])), str(info.nativeKey)]);

		var factoryArgs = [
			for( a in info.args ) {name: a.name, t: a.t, opt: a.opt == true || a.value != null}
		];
		setup.push(put(cls, "__ss_create", func(factoryArgs, [ret(call(func([{name: "__ss_self"}], createBody), [self]))])));
		setup.push(put(cls, "__ss_name", str(cls)));
		if( info.parent != null ) setup.push(put(cls, "__ss_parent", id(info.parent)));
		for( f in own ) if( !f.method && f.stat ) setup.push(put(cls, "__ss_raw_" + f.name, defaultFieldValue(f.type)));
		for( f in own ) if( !f.method && f.stat && f.value != null ) setup.push(put(cls, "__ss_raw_" + f.name, refs(f.value, members, [], cls, f.name)));
		setup.push(ret(id(cls)));
		var bindClass = call(func([{name: cls}], setup), [id("__ss_class_scope")]);
		return mk(EVar(cls, false, null, call(func([{name: "__ss_class_scope"}], [ret(bindClass)]), [obj([], [])])));
	}

	function patternBindings( e : Expr, scope : Array<String>, nested : Bool = false ) : Void {
		switch( e.e ) {
			case ECall(_, args):
				for( a in args ) patternBindings(a, scope, true);
			case EIdent(n) if( nested && ["_", "null", "true", "false"].indexOf(n) < 0 ):
				scope.push(n);
			default:
		}
	}

	function staticReceiver( owner : String ) : Expr {
		var receiver = id("__ss_class_scope"), current = info;
		while( current.name != owner ) {
			receiver = field(receiver, "__ss_parent");
			current = p.scriptTypes.get(current.parent);
		}
		return receiver;
	}

	function memberName( name : String, flags : Int, scope : Array<String>, method : String, writing : Bool, updating : Bool ) : String {
		var property = info.fields.get(name);
		var inAccessor = property.get == "get" && method == "get_" + name || property.set == "set" && method == "set_" + name;
		if( inAccessor && !property.fin ) return "__ss_raw_" + name;
		var rawRead = (flags & 2) != 0 || inAccessor;
		var constructorWrite = property.fin && !property.stat && property.owner == info.name && scope.indexOf("__ss_ctor_write") >= 0;
		var rawWrite = (flags & 4) != 0 || constructorWrite;
		if( updating ) {
			if( rawRead && rawWrite ) return "__ss_raw_" + name;
			if( rawRead ) return "__ss_read_" + name;
			if( rawWrite ) return "__ss_write_" + name;
			return name;
		}
		return (writing ? rawWrite : rawRead) ? "__ss_raw_" + name : name;
	}

	function refs( e : Expr, members : Map<String, Int>, scope : Array<String>, cls : String, method : String, writing : Bool = false,
			updating : Bool = false ) : Expr {
		if( e == null ) return null;
		switch( e.e ) {
			case EInterpString(strings, expressions):
				var result = str("");
				for( i in 0...strings.length ) {
					result = fieldRef(e, EBinop("+", result, str(strings[i])));
					for( part in expressions ) if( part.index == i + 1 ) {
						var expression = new Parser().parseString(part.str, e.origin, e.line);
						result = fieldRef(e, EBinop("+", result, refs(expression, members, scope, cls, method)));
					}
				}
				return result;
			case EIdent(n):
				if( n == "this" ) {
					if( info.fields.exists(method) && info.fields.get(method).stat ) return fail("this is not available in a static member");
					return fieldRef(e, id("__ss_self").e);
				}
				if( n == "super" ) return fail("super is only valid as a constructor or inherited method call");
				if( members.exists(n) && scope.indexOf(n) < 0 ) {
					var flags = members.get(n), isStatic = (flags & 1) != 0;
					if( !isStatic && info.fields.get(method).stat ) return fail("Instance member '" + n + "' is not available in a static member");
					var receiver = isStatic ? staticReceiver(info.fields.get(n).owner) : id("__ss_self");
					return fieldRef(e, field(receiver, memberName(n, flags, scope, method, writing, updating)).e);
				}
				return e;
			case ECall(fn, args) if( switch( fn.e ) {
					case EIdent("super"): true;
					default: false;
				} ):
				if( info.parent == null || method != "new" ) return fail("super(...) requires a derived constructor");
				return fieldRef(e, ECall(field(id("__ss_super"), "__ss_ctor"), [for( a in args ) refs(a, members, scope, cls, method)]));
			case EField(o, n, _) if( switch( o.e ) {
					case EIdent("super"): true;
					default: false;
				} ):
				if( info.fields.exists(method) && info.fields.get(method).stat ) return fail("super is not available in a static member");
				var base = info.parent == null ? null : p.scriptTypes.get(info.parent);
				var inherited = base == null ? null : base.fields.get(n);
				if( inherited == null || inherited.stat || (writing && inherited.method) ) return fail("Invalid super member: " + n);
				return fieldRef(e, field(id("__ss_super"), n).e);
			case EField(o, n, all) if( switch( o.e ) {
					case EIdent("this"): true;
					default: false;
				} ):
				if( info.fields.exists(method) && info.fields.get(method).stat ) return fail("this is not available in a static member");
				if( !members.exists(n) ) return fieldRef(e, EField(id("__ss_self"), n, all));
				var flags = members.get(n);
				if( (flags & 1) != 0 ) return fail("Static member '" + n + "' requires a class receiver");
				return fieldRef(e, EField(id("__ss_self"), memberName(n, flags, scope, method, writing, updating), all));
			case EParent(inner):
				if( writing ) return refs(inner, members, scope, cls, method, writing, updating);
				return fieldRef(e, EParent(refs(inner, members, scope, cls, method, writing, updating)));
			case EBinop(op, a, b) if( op == "="
				|| ["+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>="].indexOf(op) >= 0 ):
				return fieldRef(e, EBinop(op, refs(a, members, scope, cls, method, true, op != "="), refs(b, members, scope, cls, method)));
			case EUnop(op, pre, a) if( op == "++" || op == "--" ):
				return fieldRef(e, EUnop(op, pre, refs(a, members, scope, cls, method, true, true)));
			case ECoalesce(a, b, true):
				return fieldRef(e, ECoalesce(refs(a, members, scope, cls, method, true, true), refs(b, members, scope, cls, method), true));
			case ESwitch(value, cases, def):
				var out = [];
				for( c in cases ) {
					var local = scope.copy();
					for( v in c.values ) patternBindings(v, local);
					out.push({values: c.values, expr: refs(c.expr, members, local, cls, method), ifExpr: refs(c.ifExpr, members, local, cls, method)});
				}
				return fieldRef(e, ESwitch(refs(value, members, scope, cls, method), out, refs(def, members, scope, cls, method)));
			case EBlock(list):
				var local = scope.copy(), out = [];
				for( x in list ) {
					switch( x.e ) {
						case EVar(n, f, t, v):
							out.push(fieldRef(x, EVar(n, f, t, refs(v, members, local, cls, method))));
							local.push(n);
						case EFunction(_, _, name, _, _) if( name != null ):
							local.push(name);
							out.push(refs(x, members, local, cls, method));
						default: out.push(refs(x, members, local, cls, method));
					}
				}
				return fieldRef(e, EBlock(out));
			case EFunction(args, body, name, ret, line):
				var local = scope.copy();
				if( name != null ) local.push(name);
				var isConstructor = local.remove("__ss_ctor_root");
				local.remove("__ss_ctor_write");
				var params : Array<Argument> = [];
				for( a in args ) {
					params.push({
						name: a.name,
						t: a.t,
						opt: a.opt,
						value: refs(a.value, members, local, cls, method)
					});
					local.push(a.name);
				}
				if( isConstructor ) local.push("__ss_ctor_write");
				return fieldRef(e, EFunction(params, refs(body, members, local, cls, method), name, ret, line));
			case EFor(v, v2, it, body):
				var local = scope.copy();
				local.push(v);
				if( v2 != null ) local.push(v2);
				return fieldRef(e, EFor(v, v2, refs(it, members, scope, cls, method), refs(body, members, local, cls, method)));
			case ETry(body, catches):
				return fieldRef(e, ETry(refs(body, members, scope, cls, method), [
					for( c in catches ) {
						var local = scope.copy();
						local.push(c.v);
						{v: c.v, t: c.t, e: refs(c.e, members, local, cls, method)};
					}
				]));
			default:
		}
		function walk( v : Dynamic ) : Dynamic {
			if( v == null ) return null;
			if( Std.isOfType(v, Array) ) return [for( x in (cast v : Array<Dynamic>) ) walk(x)];
			if( Reflect.isObject(v) && Reflect.hasField(v, "e") && Reflect.hasField(v, "pmin") ) return refs(cast v, members, scope, cls, method);
			if( Type.typeof(v) == TObject ) {
				var out : Dynamic = {};
				for( f in Reflect.fields(v) ) Reflect.setField(out, f, walk(Reflect.field(v, f)));
				return out;
			}
			return v;
		}
		return fieldRef(e, Type.createEnum(ExprDef, Type.enumConstructor(e.e), [for( v in Type.enumParameters(e.e) ) walk(v)]));
	}

	function fieldRef( e : Expr, d : ExprDef ) : Expr return {
		e: d,
		pmin: e.pmin,
		pmax: e.pmax,
		origin: e.origin,
		line: e.line
	};
}
