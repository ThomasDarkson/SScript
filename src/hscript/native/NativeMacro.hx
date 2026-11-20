package hscript.native;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

private typedef MethodInfo = {name:String, type:Type, base:Bool, sealed:Bool, publicMethod:Bool, dynamicMethod:Bool, source:Null<ClassField>};

class NativeMacro {
	static var emitted:Map<String, Bool> = [];
	static var serial = 0;

	static function path(name:String):TypePath {
		var parts = name.split("."), last = parts.pop();
		return {pack: parts, name: last};
	}

	static function classType(name:String):ClassType {
		return switch (Context.follow(Context.getType(name))) {
			case TInst(c, _): c.get();
			default:
				Context.error("Expected a native Haxe class/interface: " + name, Context.currentPos());
				null;
		};
	}

	static function full(c:ClassType):String
		return c.pack.concat([c.name]).join(".");

	static function flat(c:ClassType):Map<String, ClassField> {
		var result = c.superClass == null ? new Map<String, ClassField>() : flat(c.superClass.t.get());
		if (c.isInterface)
			for (i in c.interfaces)
				for (name => f in flat(i.t.get()))
					result.set(name, f);
		for (f in c.fields.get())
			result.set(f.name, f);
		return result;
	}

	static function nativeParents(c:ClassType):Array<String> {
		var names:Array<String> = [];
		for (i in c.interfaces) {
			var name = full(i.t.get());
			if (names.indexOf(name) < 0)
				names.push(name);
			for (parent in nativeParents(i.t.get()))
				if (names.indexOf(parent) < 0)
					names.push(parent);
		}
		names.sort(Reflect.compare);
		return names;
	}

	static function staticFields(c:ClassType):Map<String, ClassField> {
		var result = c.superClass == null ? new Map<String, ClassField>() : staticFields(c.superClass.t.get());
		for (f in c.statics.get())
			result.set(f.name, f);
		return result;
	}

	static function mode(a:VarAccess, read:Bool):String
		return switch (a) {
			case AccCall: read ? "get" : "set";
			case AccNo: "null";
			case AccNever: "never";
			default: "default";
		};

	static function typeText(t:Type, opt:Bool = false):String {
		if (opt)
			switch (t) {
				case TAbstract(a, p) if (a.get().name == "Null" && p.length == 1):
					t = p[0];
				default:
			}
		return TypeTools.toString(t);
	}

	static function params(t:Type):Array<{name:String, opt:Bool, t:Type}>
		return switch (Context.follow(t)) {
			case TFun(a, _): a;
			default:
				Context.error("Expected method signature", Context.currentPos());
				[];
		};

	static function defaults(field:Null<ClassField>):Array<Null<Expr>> {
		if (field == null)
			return [];
		var typed = field.expr();
		return typed == null ? [] : switch (typed.expr) {
			case TFunction(f): [for (a in f.args) a.value == null ? null : Context.getTypedExpr(a.value)];
			default: [];
		};
	}

	static function boxedArgument(index:Int, arg:{name:String, opt:Bool, t:Type}, defaultValue:Null<Expr>):Expr {
		var pos = Context.currentPos();
		var castValue:Expr = {expr: ECast(macro args[$v{index}], argumentType(arg.t, arg.opt)), pos: pos};
		if (defaultValue != null)
			switch (defaultValue.expr) {
				case EConst(CIdent("null")):
				default:
					castValue = macro args[$v{index}] == null ? $e{defaultValue} : cast args[$v{index}];
			}
		return castValue;
	}

	static function argumentType(t:Type, opt:Bool):ComplexType {
		var result = TypeTools.toComplexType(t);
		return opt ? TPath({pack: [], name: "Null", params: [TPType(result)]}) : result;
	}

	static function signature(name:String, t:Type):String {
		return switch (Context.follow(t)) {
			case TFun(a, r): 'function '
				+ name
				+ '('
				+ [for (p in a) (p.opt ? "?" : "") + p.name + ":" + typeText(p.t, p.opt)].join(",")
					+ ')'
					+ (name == "new" ? "" : ":" + typeText(r))
					+ ";";
			default: "";
		};
	}

	static function descriptor(c:ClassType):Expr {
		if (c.params.length > 0)
			Context.error("Native adapters currently require non-generic types: " + full(c), c.pos);
		var fields = flat(c),
			needed:Map<String, Bool> = [],
			methods:Array<String> = [],
			propertyData:Dynamic = {};
		for (f in fields)
			switch (f.kind) {
				case FVar(g, s):
					if (f.isPublic) {
						if (g == AccCall)
							needed.set("get_" + f.name, true);
						if (s == AccCall)
							needed.set("set_" + f.name, true);
					}
				default:
			}
		var stub = (c.isInterface ? "nativeinterface " : "nativeclass ")
			+ c.name
			+ '("'
			+ full(c)
			+ '"'
			+ (c.isInterface ? [for (n in nativeParents(c)) ',"' + n + '"'].join("") : "")
			+ '){';
		if (!c.isInterface) {
			var ctor = c.constructor;
			var cursor = c;
			while (ctor == null && cursor.superClass != null) {
				cursor = cursor.superClass.t.get();
				ctor = cursor.constructor;
			}
			stub += ctor == null ? "function new();" : signature("new", ctor.get().type);
		}
		var synthetic:Map<String, Type> = [];
		for (f in fields) {
			switch (f.kind) {
				case FMethod(kind):
					if (!f.isPublic && !needed.exists(f.name))
						continue;
					if (f.params.length > 0)
						Context.error("Native adapter generic methods are not supported: " + full(c) + "." + f.name, f.pos);
					var sealed = f.isFinal || kind == MethInline || kind == MethDynamic;
					stub += (sealed ? "sealed " : "") + signature(f.name, f.type);
					methods.push(f.name);
				case FVar(g, s):
					if (!f.isPublic)
						continue;
					var getter = mode(g, true),
						setter = f.isFinal ? "never" : mode(s, false);
					if (c.isInterface && getter != "get")
						Context.error("Native interface data fields require an accessor property (get,...): " + full(c) + "." + f.name, f.pos);
					if (c.isInterface && setter == "default")
						Context.error("Native interface writable properties require (get,set): " + full(c) + "." + f.name, f.pos);
					Reflect.setField(propertyData, f.name, {get: getter, set: setter});
					stub += 'var ' + f.name + '(' + getter + ',' + setter + '):' + typeText(f.type) + ';';
					if (c.isInterface) {
						if (getter == "get" && !fields.exists("get_" + f.name))
							synthetic.set("get_" + f.name, TFun([], f.type));
						if (setter == "set" && !fields.exists("set_" + f.name))
							synthetic.set("set_" + f.name, TFun([{name: "value", opt: false, t: f.type}], f.type));
					}
			}
		}
		for (name => t in synthetic) {
			stub += signature(name, t);
			methods.push(name);
		}
		if (!c.isInterface)
			for (f in staticFields(c))
				if (f.isPublic)
					switch (f.kind) {
						case FMethod(_):
							stub += "static " + signature(f.name, f.type);
						case FVar(g, s):
							stub += 'static var ' + f.name + '(' + mode(g, true) + ',' + mode(s, false) + '):' + typeText(f.type) + ';';
					}
		stub += "}";
		return macro new hscript.native.NativeDescriptor($v{full(c)}, $v{c.name}, $p{c.pack.concat([c.name])}, $v{c.isInterface}, $v{stub}, $v{methods},
			$v{propertyData});
	}

	public static function register(base:String, interfaces:Array<String>):Void {
		var pos = Context.currentPos(),
			bc = base == "" ? null : classType(base);
		if (bc != null && (bc.isInterface || bc.isFinal || bc.isExtern || bc.isAbstract))
			Context.error("Native base must be a concrete extendable Haxe class: " + base, pos);
		var allInterfaces:Map<String, ClassType> = [];
		function add(c:ClassType):Void {
			if (!c.isInterface)
				Context.error("Expected a native interface: " + full(c), pos);
			if (allInterfaces.exists(full(c)))
				return;
			allInterfaces.set(full(c), c);
			for (i in c.interfaces)
				add(i.t.get());
		}
		for (name in interfaces)
			add(classType(name));
		var names = [for (n in allInterfaces.keys()) n];
		names.sort(Reflect.compare);
		var key = (bc == null ? "" : full(bc)) + "|" + names.join(",");
		if (emitted.exists(key))
			return;
		emitted.set(key, true);
		var adapterName = "Adapter" + (serial++),
			adapterPack = ["hscript", "native", "generated"];
		var nativeFields = bc == null ? new Map<String, ClassField>() : flat(bc);
		var methods:Map<String, MethodInfo> = [], properties:Array<Field> = [];
		var needed:Map<String, Bool> = [];
		for (f in nativeFields)
			switch (f.kind) {
				case FVar(g, s):
					if (f.isPublic) {
						if (g == AccCall)
							needed.set("get_" + f.name, true);
						if (s == AccCall)
							needed.set("set_" + f.name, true);
					}
				default:
			}
		for (f in nativeFields)
			switch (f.kind) {
				case FMethod(kind):
					if (f.isPublic || needed.exists(f.name))
						methods.set(f.name, {
							name: f.name,
							type: f.type,
							base: true,
							sealed: f.isFinal || kind == MethInline || kind == MethDynamic,
							publicMethod: f.isPublic,
							dynamicMethod: kind == MethDynamic,
							source: f
						});
				default:
			}
		for (i in allInterfaces)
			for (f in i.fields.get())
				switch (f.kind) {
					case FMethod(_):
						if (!methods.exists(f.name))
							methods.set(f.name, {
								name: f.name,
								type: f.type,
								base: false,
								sealed: false,
								publicMethod: true,
								dynamicMethod: false,
								source: null
							});
					case FVar(g, s):
						if (nativeFields.exists(f.name))
							continue;
						if (!properties.filter(function(p) return p.name == f.name).iterator().hasNext())
							properties.push({
								name: f.name,
								pos: pos,
								access: [APublic],
								kind: FProp(mode(g, true), mode(s, false), TypeTools.toComplexType(f.type))
							});
						if (g == AccCall && !methods.exists("get_" + f.name))
							methods.set("get_" + f.name, {
								name: "get_" + f.name,
								type: TFun([], f.type),
								base: false,
								sealed: false,
								publicMethod: true,
								dynamicMethod: false,
								source: null
							});
						if (s == AccCall && !methods.exists("set_" + f.name))
							methods.set("set_" + f.name, {
								name: "set_" + f.name,
								type: TFun([{name: "value", t: f.type, opt: false}], f.type),
								base: false,
								sealed: false,
								publicMethod: true,
								dynamicMethod: false,
								source: null
							});
				}
		var fields:Array<Field> = [
			{
				name: "__ss_binding",
				pos: pos,
				access: [APublic],
				kind: haxe.macro.Expr.FieldType.FVar(macro :hscript.native.NativeBinding)
			}
		].concat(properties);
		var ctorArgs:Array<Expr> = [];
		if (bc != null) {
			var ctor = bc.constructor, cursor = bc;
			while (ctor == null && cursor.superClass != null) {
				cursor = cursor.superClass.t.get();
				ctor = cursor.constructor;
			}
			if (ctor != null) {
				var defaultValues = defaults(ctor.get());
				for (index => a in params(ctor.get().type))
					ctorArgs.push(boxedArgument(index, a, defaultValues[index]));
			}
		}
		var construct:Array<Expr> = [macro this.__ss_binding = binding, macro binding.attach(this)];
		if (bc != null)
			construct.push({expr: ECall(macro super, ctorArgs), pos: pos});
		fields.push({
			name: "new",
			pos: pos,
			access: [APublic],
			kind: FFun({
				args: [
					{name: "binding", type: macro :hscript.native.NativeBinding},
					{name: "args", type: macro :Array<Dynamic>}
				],
				expr: {expr: EBlock(construct), pos: pos}
			})
		});
		var superCases:Array<Case> = [];
		for (m in methods) {
			var args = params(m.type),
				defaultValues = defaults(m.source),
				retType = switch (Context.follow(m.type)) {
					case TFun(_, r): r;
					default: null;
				};
			var isVoid = TypeTools.toString(retType) == "Void";
			var argExpr = [for (a in args) {expr: EConst(CIdent(a.name)), pos: pos}];
			var invoke = macro this.__ss_binding.invoke($v{m.name}, [$a{argExpr}]);
			var fallback:Expr = macro throw $v{"Missing native interface implementation: " + m.name};
			if (m.base) {
				var superFn = {expr: EField(m.dynamicMethod ? macro this : macro super, m.name), pos: pos};
				var direct = {expr: ECall(superFn, argExpr), pos: pos};
				fallback = isVoid ? macro {$e{direct}; return;} : macro return $e{direct};
				var boxedArgs = [for (index => a in args) boxedArgument(index, a, defaultValues[index])];
				var boxed = {expr: ECall(superFn, boxedArgs), pos: pos};
				superCases.push({values: [macro $v{m.name}], expr: isVoid ? macro {$e{boxed}; return null;} : macro return $e{boxed}});
			}
			if (m.sealed)
				continue;
			var dispatched = isVoid ? macro {$e{invoke}; return;} : macro return cast $e{invoke};
			var body = macro {
				if (this.__ss_binding != null && this.__ss_binding.has($v{m.name}))
					$e{dispatched};
				$e{fallback};
			};
			fields.push({
				name: m.name,
				pos: pos,
				access: m.base ? [APublic, AOverride] : [APublic],
				kind: FFun({
					args: [
						for (index => a in args)
							{
								name: a.name,
								opt: a.opt && defaultValues[index] == null,
								type: TypeTools.toComplexType(a.t),
								value: defaultValues[index]
							}
					],
					ret: TypeTools.toComplexType(retType),
					expr: body
				})
			});
		}
		fields.push({
			name: "sscriptSuperCall",
			pos: pos,
			access: [APublic],
			kind: FFun({
				args: [{name: "name", type: macro :String}, {name: "args", type: macro :Array<Dynamic>}],
				ret: macro :Dynamic,
				expr: {
					expr: ESwitch(macro name, superCases, macro throw "No native super method: " + name),
					pos: pos
				}
			})
		});
		var init:Array<Expr> = [];
		var types = [for (i in allInterfaces) i];
		if (bc != null) {
			var cursor:Null<ClassType> = bc;
			while (cursor != null) {
				types.unshift(cursor);
				cursor = cursor.superClass == null ? null : cursor.superClass.t.get();
			}
		}
		for (t in types) {
			var d = descriptor(t);
			init.push(macro hscript.native.NativeTypes.installType($e{d}));
		}
		var adapterExpr = {expr: EConst(CIdent(adapterName)), pos: pos};
		init.push(macro hscript.native.NativeTypes.installAdapter($v{key}, $v{bc == null ? "" : full(bc)}, $e{adapterExpr}));
		fields.push({
			name: "__init__",
			pos: pos,
			access: [AStatic],
			kind: FFun({args: [], expr: {expr: EBlock(init), pos: pos}})
		});
		var nativeInterfaces = [path("hscript.native.NativeInstance")];
		for (n in names)
			nativeInterfaces.push(path(n));
		Context.defineType({
			pack: adapterPack,
			name: adapterName,
			pos: pos,
			meta: [{name: ":keep", pos: pos, params: []}],
			kind: TDClass(bc == null ? null : path(full(bc)), nativeInterfaces),
			fields: fields
		});
		Context.getType(adapterPack.concat([adapterName]).join("."));
	}
}
#end
