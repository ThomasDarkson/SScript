package hscript.native;

@:keep
class NativeRuntime {
	static var specs:Map<String, Dynamic>;
	static var aliases:Map<String, Array<String>>;
	static var sourceNames:Map<String, String>;
	static var serial = 0;

	public static function installMetadata(json:String):Void {
		if (specs == null) {
			specs = [];
			aliases = [];
			sourceNames = [];
		}
		var entries:Array<Dynamic> = haxe.Json.parse(json);
		for (s in entries) {
			specs.set(s.name, s);
			sourceNames.set(s.sourceName, s.name);
			var names = aliases.get(s.alias);
			if (names == null) {
				names = [];
				aliases.set(s.alias, names);
			}
			if (names.indexOf(s.name) < 0)
				names.push(s.name);
		}
	}

	public static function available():Bool {
		#if (cpp && scriptable && !cppia && !sscript_no_runtime_native)
		return true;
		#else
		return false;
		#end
	}

	static function expose(name:String):Void {
		if (NativeTypes.descriptors.exists(name))
			return;
		var s = specs.get(name);
		if (s == null)
			return;
		var type = Type.resolveClass(name);
		if (type == null)
			return;
		var methods:Array<Dynamic> = s.methods;
		NativeTypes.installType(new NativeDescriptor(s.name, s.alias, type, s.iface, s.stub, [for (m in methods) (m.name : String)], s.fields));
		var parents:Array<String> = s.parents;
		for (p in parents)
			expose(p);
	}

	public static function discover(code:String):Array<String> {
		if (!available() || specs == null)
			return [];
		var tokens = identifiers(code),
			declared:Map<String, Bool> = [],
			imports:Map<String, String> = [],
			selected:Map<String, Bool> = [];
		for (i in 0...tokens.length - 1) {
			if (["class", "enum", "interface", "sharedclass", "sharedenum", "sharedinterface"].indexOf(tokens[i]) >= 0)
				declared.set(tokens[i + 1], true);
			if (tokens[i] == "import") {
				var name = tokens[i + 1];
				if (sourceNames.exists(name))
					name = sourceNames.get(name);
				var s = specs.get(name);
				if (s != null)
					imports.set(s.alias, name);
			}
		}
		for (token in tokens) {
			var name = imports.get(token);
			if (name == null)
				name = sourceNames.get(token);
			if (name == null && specs.exists(token))
				name = token;
			if (name == null && !declared.exists(token)) {
				var candidates = aliases.get(token);
				if (candidates != null && candidates.length == 1)
					name = candidates[0];
			}
			if (name != null && !declared.exists(specs.get(name).alias)) {
				expose(name);
				selected.set(name, true);
			}
		}

		var result:Array<String> = [], done:Map<String, Bool> = [];
		function add(name:String):Void {
			if (done.exists(name))
				return;
			done.set(name, true);
			var s = specs.get(name);
			if (s == null)
				return;
			var parents:Array<String> = s.parents;
			for (p in parents)
				add(p);
			if (NativeTypes.descriptors.exists(name))
				result.push(name);
		}
		for (name in selected.keys())
			add(name);
		return result;
	}

	public static function aliasPrelude(names:Array<String>):Array<String> {
		return [
			for (name in names)
				if (specs.get(name).sourceName != name) 'nativealias("' + specs.get(name).sourceName + '","' + name + '");'
		];
	}

	static function identifiers(code:String):Array<String> {
		var result:Array<String> = [], i = 0, n = code.length;
		function ident(c:Int):Bool
			return c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95 || c >= 48 && c <= 57;
		while (i < n) {
			var c = code.charCodeAt(i);
			if (c == 34 || c == 39) {
				var q = c;
				i++;
				while (i < n) {
					var v = code.charCodeAt(i++);
					if (v == 92)
						i++;
					else if (v == q)
						break;
				}
				continue;
			}
			if (code.substr(i, 2) == "~/") {
				i += 2;
				while (i < n) {
					var v = code.charCodeAt(i++);
					if (v == 92)
						i++;
					else if (v == 47)
						break;
				}
				while (i < n && ident(code.charCodeAt(i)))
					i++;
				continue;
			}
			if (code.substr(i, 2) == "//") {
				while (i < n && code.charCodeAt(i) != 10)
					i++;
				continue;
			}
			if (code.substr(i, 2) == "/*") {
				i += 2;
				var end = code.indexOf("*/", i);
				i = end < 0 ? n : end + 2;
				continue;
			}
			if (ident(c) && !(c >= 48 && c <= 57)) {
				var start = i++;
				while (i < n && (ident(code.charCodeAt(i)) || code.charCodeAt(i) == 46))
					i++;
				var word = code.substring(start, i);
				while (StringTools.endsWith(word, "."))
					word = word.substr(0, word.length - 1);
				result.push(word);
				if (word.indexOf(".") >= 0)
					for (part in word.split("."))
						result.push(part);
			} else
				i++;
		}
		return result;
	}

	public static function createAdapter(key:String):Class<Dynamic> {
		#if (cpp && scriptable && !cppia && !sscript_no_runtime_native)
		var split = key.split("|");
		if (split.length != 2)
			throw "Invalid runtime native adapter key: " + key;
		var base = split[0],
			interfaces = split[1] == "" ? [] : split[1].split(",");
		for (name in (base == "" ? [] : [base]).concat(interfaces)) {
			var s = specs == null ? null : specs.get(name);
			if (s == null)
				throw "Native type is not present in this host: " + name;
			if (s.reason != "")
				throw s.reason;
			if ((name == base && s.iface) || (name != base && !s.iface))
				throw "Invalid native base/interface combination: " + key;
			var declaredMethods:Array<Dynamic> = s.methods;
			for (m in declaredMethods)
				if (m.name == "sscriptSuperCall")
					throw "Native member uses a reserved bridge name: " + name + "." + m.name;
			if (s.abiReady != true) {
				var methods:Array<Dynamic> = s.methods;
				if (!s.iface)
					methods = methods.concat([s.ctor]);
				function abi(code:String):String
					return switch (code) {
						case "v": "void";
						case "b": "bool";
						case "i": "int";
						case "f": "Float";
						case "s": "String";
						default: "Dynamic";
					};
				for (m in methods) {
					if (m.dynamicMethod)
						continue;
					var signature = NativeRuntimeHost.signature(name, m.name);

					if (signature == null && s.iface) {
						var parents:Array<String> = s.parents;
						for (parent in parents) {
							signature = NativeRuntimeHost.signature(parent, m.name);
							if (signature != null)
								break;
						}
					}
					if (signature == null) {
						if (m.sealed)
							continue;
						throw "Native member has no hxcpp scripting bridge: " + name + "." + m.name;
					}
					var args:Array<Dynamic> = m.args;
					if (signature.length != args.length + 1)
						throw "Native member ABI mismatch: " + name + "." + m.name;
					m.ret = abi(signature.charAt(0));
					for (i in 0...args.length) {
						var code = signature.charAt(i + 1);

						args[i].type = args[i].type == "bool" && code == "i" ? "bool" : abi(code);
					}
				}
				s.abiReady = true;
			}
		}
		var generated = "hscript.native.runtime.Adapter" + (serial++),
			writer = new NativeRuntimeWriter(generated, base, interfaces, specs);
		var interfaceMethods = ["sscriptSuperCall"];
		for (i in interfaces) {
			var methods:Array<Dynamic> = specs.get(i).methods;
			for (m in methods)
				interfaceMethods.push(m.name);
		}
		var module = NativeRuntimeHost.load(writer.emit(), interfaceMethods);
		module.boot();
		var cls = module.resolveClass(generated);
		if (cls == null)
			throw "Runtime native adapter could not be resolved: " + key;
		return cls;
		#else
		throw "Runtime native inheritance requires the hxcpp target";
		#end
	}

	public static function superCall(host:Dynamic, base:String, name:String, args:Array<Dynamic>):Dynamic {
		#if (cpp && scriptable && !cppia && !sscript_no_runtime_native)
		var s = specs.get(base),
			methods:Array<Dynamic> = s == null ? [] : s.methods;
		for (m in methods)
			if (m.name == name && m.dynamicMethod)
				return Reflect.callMethod(host, Reflect.field(host, name), args);
		return NativeRuntimeHost.superCall(host, base, name, args);
		#else
		throw "Runtime native inheritance requires the hxcpp target";
		#end
	}
}

#if (cpp && scriptable && !cppia && !sscript_no_runtime_native)
@:include("sscript_native_runtime.hpp")
private extern class NativeRuntimeHost {
	@:native("sscript_native_load") static function load(code:String, methods:Array<String>):RuntimeModule;
	@:native("sscript_native_super") static function superCall(host:Dynamic, base:String, name:String, args:Array<Dynamic>):Dynamic;
	@:native("sscript_native_signature") static function signature(type:String, name:String):String;
}

@:native("::hx::CppiaLoadedModule")
private extern class RuntimeModule {
	function boot():Void;
	function resolveClass(name:String):Class<Dynamic>;
}
#end
