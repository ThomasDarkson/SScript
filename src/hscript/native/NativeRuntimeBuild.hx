package hscript.native;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

@:access(hscript.native.NativeMacro)
class NativeRuntimeBuild {
	static var started = false;
	static var seen:Map<String, Bool> = [];
	static var serial = 0;

	static function runtimeName(c:ClassType):String
		return c.pack.concat([c.name]).join(".");

	static function abi(t:Type):String {
		return switch (Context.follow(t)) {
			case TAbstract(a, _): switch (a.get().name) {
					case "Int": "int";
					case "Float": "Float";
					case "Bool": "bool";
					case "Void": "void";
					default: "Dynamic";
				};
			case TInst(c, _): c.get().name == "String" ? "String" : "Dynamic";
			default: "Dynamic";
		};
	}

	static function text(t:Type):String {
		return switch (Context.follow(t)) {
			case TInst(c, params): switch (c.get().kind) {
					case KTypeParameter(_): "Dynamic";
					default: runtimeName(c.get()) + (params.length == 0 ? "" : "<" + [for (p in params) text(p)].join(",") + ">");
				};
			case TEnum(e, params): e.get().pack.concat([e.get().name]).join(".")
				+ (params.length == 0 ? "" : "<" + [for (p in params) text(p)].join(",") + ">");
			case TAbstract(a, params): a.get().pack.concat([a.get().name]).join(".")
				+ (params.length == 0 ? "" : "<" + [for (p in params) text(p)].join(",") + ">");
			case TFun(args, ret): "(" + [for (a in args) text(a.t)].join(",") + ")->" + text(ret);
			default: "Dynamic";
		};
	}

	static function method(name:String, t:Type, base:Bool, sealed:Bool = false, dyn:Bool = false):Dynamic {
		return switch (Context.follow(t)) {
			case TFun(args, ret): {
					name: name,
					base: base,
					sealed: sealed,
					dynamicMethod: dyn,
					ret: abi(ret),
					args: [for (a in args) {name: a.name, opt: a.opt, type: a.opt ? "Dynamic" : abi(a.t)}]
				};
			default: null;
		};
	}

	static function signature(name:String, t:Type):String
		return switch (Context.follow(t)) {
			case TFun(args, ret): "function "
				+ name
				+ "("
				+ [for (a in args) (a.opt ? "?" : "") + a.name + ":" + text(a.t)].join(",")
					+ ")"
					+ (name == "new" ? "" : ":" + text(ret))
					+ ";";
			default: "";
		};

	static function spec(c:ClassType):Dynamic {
		var name = runtimeName(c),
			flat = NativeMacro.flat(c),
			needed:Map<String, Bool> = [];
		var methods:Array<Dynamic> = [],
			fields:Dynamic = {},
			properties:Array<Dynamic> = [];
		var parents = NativeMacro.nativeParents(c), members = "", reason = "";
		if (c.isFinal || c.isAbstract)
			reason = "Native base is final or abstract: " + name;
		for (f in flat)
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
		for (f in flat)
			switch (f.kind) {
				case FMethod(kind):
					if (NativeRuntimeCompat.unsafe(f.type))
						continue;
					if (!f.isPublic && !needed.exists(f.name))
						continue;
					var sealed = f.isFinal || kind == MethInline || kind == MethDynamic;
					members += (sealed ? "sealed " : "") + signature(f.name, f.type);
					methods.push(method(f.name, f.type, !c.isInterface, sealed, kind == MethDynamic));
				case FVar(g, s):
					if (NativeRuntimeCompat.unsafe(f.type))
						continue;
					if (!f.isPublic)
						continue;
					var get = NativeMacro.mode(g, true),
						set = f.isFinal ? "never" : NativeMacro.mode(s, false);
					Reflect.setField(fields, f.name, {get: get, set: set});
					properties.push({
						name: f.name,
						get: get,
						set: set,
						type: abi(f.type)
					});
					members += "var " + f.name + "(" + get + "," + set + "):" + text(f.type) + ";";
					if (c.isInterface) {
						for (access in [get == "get" ? "get_" : null, set == "set" ? "set_" : null])
							if (access != null && !flat.exists(access + f.name)) {
								var ft = TFun(access == "get_" ? [] : [{name: "value", opt: false, t: f.type}], f.type);
								members += signature(access + f.name, ft);
								methods.push(method(access + f.name, ft, false));
							}
					}
			}
		var ctor:Dynamic = {
			name: "new",
			base: true,
			sealed: false,
			dynamicMethod: false,
			ret: "void",
			args: []
		};
		if (!c.isInterface) {
			var cursor = c, cf = c.constructor;
			while (cf == null && cursor.superClass != null) {
				cursor = cursor.superClass.t.get();
				cf = cursor.constructor;
			}
			members = (cf == null ? "function new();" : signature("new", cf.get().type)) + members;
			if (cf != null)
				ctor = method("new", cf.get().type, true);
			if (cf != null && NativeRuntimeCompat.unsafe(cf.get().type))
				reason = "Native constructor requires raw pointers: " + name;
			for (f in NativeMacro.staticFields(c))
				if (f.isPublic && !NativeRuntimeCompat.unsafe(f.type))
					switch (f.kind) {
						case FMethod(_):
							members += "static " + signature(f.name, f.type);
						case FVar(g, s):
							members += "static var " + f.name + "(" + NativeMacro.mode(g, true) + "," + NativeMacro.mode(s, false) + "):" + text(f.type) + ";";
					}
		}
		if (c.isInterface)
			for (f in flat)
				if (NativeRuntimeCompat.unsafe(f.type))
					reason = "Native interface requires raw pointers: " + name;
		var stub = (c.isInterface ? "nativeinterface " : "nativeclass ")
			+ c.name
			+ '("'
			+ name
			+ '"'
			+ (c.isInterface ? [for (n in parents) ',"' + n + '"'].join("") : "")
			+ '){'
			+ members
			+ '}';
		var sourceName = c.module.split(".").pop() == c.name ? c.module : c.module + "." + c.name;
		return {
			name: name,
			sourceName: sourceName,
			alias: c.name,
			iface: c.isInterface,
			parents: parents,
			stub: stub,
			methods: methods,
			fields: fields,
			properties: properties,
			ctor: ctor,
			reason: reason
		};
	}

	public static function init():Void {
		if (!started
			&& Context.defined("cpp")
			&& Context.defined("scriptable")
			&& !Context.defined("cppia")
			&& !Context.defined("sscript_no_runtime_native")) {
			started = true;
			NativeRuntimeCompat.init();
			Context.onAfterGenerate(function() {
				started = false;
				seen = [];
				serial = 0;
			});
			Context.onAfterTyping(function(types) {
				var specs:Array<Dynamic> = [];
				for (t in types)
					switch (t) {
						case TClassDecl(ref):
							var c = ref.get(), name = runtimeName(c);
							if (seen.exists(name) || c.isExtern || StringTools.startsWith(name, "hscript.native.generated."))
								continue;
							seen.set(name, true);
							NativeRuntimeCompat.collect(c);
							if (c.meta.has(":nativeGen") || c.meta.has(":unreflective"))
								continue;

							c.meta.add(":keep", [], c.pos);
							try {
								specs.push(spec(c));
							} catch (_:Dynamic) {}
						default:
					}
				if (specs.length == 0)
					return;
				var pos = Context.currentPos(), init:Array<Expr> = [], batch:Array<Dynamic> = [], size = 0;
				function flush():Void {
					if (batch.length > 0) {
						var data = haxe.Json.stringify(batch);
						init.push(macro hscript.native.NativeRuntime.installMetadata($v{data}));
						batch = [];
						size = 0;
					}
				}
				for (s in specs) {
					var len = haxe.Json.stringify(s).length;
					if (size + len > 16000)
						flush();
					batch.push(s);
					size += len;
				}
				flush();
				Context.defineType({
					pack: ["hscript", "native", "generated"],
					name: "RuntimeMetadata" + (serial++),
					pos: pos,
					meta: [{name: ":keep", pos: pos, params: []}],
					kind: TDClass(),
					fields: [
						{
							name: "__init__",
							pos: pos,
							access: [AStatic],
							kind: FFun({args: [], expr: {expr: EBlock(init), pos: pos}})
						}
					]
				});
			});
		}
	}

	public static function build():Array<Field> {
		init();
		if (Context.defined("cpp")
			&& Context.defined("scriptable")
			&& !Context.defined("cppia")
			&& !Context.defined("sscript_no_runtime_native")) {
			var file = sys.FileSystem.fullPath(Context.resolvePath("hscript/native/NativeRuntimeBuild.hx")).split("\\").join("/");
			var parts = file.split("/");
			for (_ in 0...4)
				parts.pop();
			var dir = parts.join("/") + "/ssvm", hxcppDir = "$" + "{HXCPP}";
			var xml = '<files id="haxe"><compilerflag value="-I$dir/include"/><compilerflag value="-I$hxcppDir/src/hx/cppia"/><file name="$dir/src/native_runtime.cpp"/></files>';
			Context.getLocalClass().get().meta.add(":buildXml", [macro $v{xml}], Context.currentPos());
		}
		return Context.getBuildFields();
	}
}
#end
