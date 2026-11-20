package hscript.native;

import hscript.native.NativeBinding.NativeHost;

private typedef ScriptOwner = #if macro Dynamic #else hscript.SScript #end;

#if !macro
@:build(hscript.native.NativeRuntimeBuild.build())
#end
class NativeTypes {
	public static var descriptors:Map<String, NativeDescriptor>;
	public static var adapters:Map<String, {adapter:Class<Dynamic>, base:String}>;
	static var aliases:Map<String, String>;
	static var declarations:Array<String>;
	public static var api(get, never):NativeAPI;
	static var apiValue:NativeAPI;

	static function get_api():NativeAPI {
		if (apiValue == null)
			apiValue = new NativeAPI();
		return apiValue;
	}

	static function ensure():Void {
		if (descriptors == null)
			descriptors = [];
		if (adapters == null)
			adapters = [];
		if (aliases == null)
			aliases = [];
		if (declarations == null)
			declarations = [];
	}

	public static function adapterFor(key:String):{adapter:Class<Dynamic>, base:String} {
		ensure();
		if (!adapters.exists(key) && NativeRuntime.available()) {
			var adapter = NativeRuntime.createAdapter(key);
			adapters.set(key, {adapter: adapter, base: key.split("|")[0]});
		}
		return adapters.get(key);
	}

	public static function installType(d:NativeDescriptor):Void {
		ensure();
		if (aliases.exists(d.alias) && aliases.get(d.alias) != d.name)
			aliases.set(d.alias, "");
		else
			aliases.set(d.alias, d.name);
		if (!descriptors.exists(d.name))
			declarations.push(d.stub);
		descriptors.set(d.name, d);
	}

	public static function installAdapter(key:String, base:String, adapter:Class<Dynamic>):Void {
		ensure();
		if (!adapters.exists(key))
			declarations.push('nativeadapter("' + key + '");');
		adapters.set(key, {base: base, adapter: adapter});
	}

	public static function descriptor(name:String):NativeDescriptor {
		ensure();
		var d = descriptors.get(name);
		if (d == null)
			d = descriptors.get(aliases.get(name));
		if (d == null)
			throw "Unregistered native type: " + name;
		return d;
	}

	public static function resolve(name:String):Dynamic {
		ensure();
		var d = descriptors.get(name);
		if (d == null)
			d = descriptors.get(aliases.get(name));
		return d == null ? null : d.nativeType;
	}

	public static function source(code:String, allowNative:Bool = true):String {
		ensure();
		if (!allowNative)
			return code;
		if (NativeRuntime.available() && !StringTools.startsWith(code, "/*sscript-native-prelude*/")) {
			var names = NativeRuntime.discover(code),
				stubs = NativeRuntime.aliasPrelude(names).concat([for (name in names) descriptors.get(name).stub]);

			for (key in adapters.keys())
				stubs.push('nativeadapter("' + key + '");');
			stubs.push('nativeadapter("*");');
			return "/*sscript-native-prelude*/" + stubs.join(" ") + "\n" + code;
		}
		if (declarations.length == 0 || StringTools.startsWith(code, "/*sscript-native-prelude*/"))
			return code;
		return "/*sscript-native-prelude*/" + declarations.join(" ") + "\n" + code;
	}

	public static function handle(value:Dynamic):NativeHandle {
		if (Std.isOfType(value, NativeHandle))
			return cast value;
		if (Std.isOfType(value, NativeInstance))
			return (cast value : NativeInstance).__ss_binding.self;
		return new LocalHandle(value);
	}

	public static function unwrap(value:Dynamic):Dynamic {
		if (value == null)
			return null;
		if (Std.isOfType(value, NativeDescriptor))
			return (cast value : NativeDescriptor).nativeType;
		if (Std.isOfType(value, NativeHost))
			return (cast value : NativeHost).value;
		if (Std.isOfType(value, NativeHandle)) {
			var host = (cast value : NativeHandle).rawGet("__ss_host");
			return host == null ? value : unwrap(host);
		}
		if (Type.typeof(value) == TObject) {
			var host = Reflect.field(value, "__ss_host");
			if (host != null)
				return unwrap(host);
		}
		return value;
	}

	public static function release(value:Dynamic):Void {
		var host = unwrap(value);
		if (Std.isOfType(host, NativeInstance))
			(cast host : NativeInstance).__ss_binding.release();
	}

	public static function special(value:Dynamic):Bool
		return Std.isOfType(value, NativeHandle)
			|| Std.isOfType(value, NativeDescriptor)
			|| Std.isOfType(value, NativeView)
			|| Std.isOfType(value, NativeInstance);

	public static function scriptName(value:Dynamic):String {
		if (value == null)
			return null;
		return Std.isOfType(value, NativeHandle) ? (cast value : NativeHandle).rawGet("__ss_name") : Reflect.field(value, "__ss_name");
	}

	public static function scriptMatches(value:Dynamic, name:String):Bool {
		if (value == null)
			return false;
		if (Std.isOfType(value, NativeInstance))
			value = (cast value : NativeInstance).__ss_binding.self;
		var handle:NativeHandle = Std.isOfType(value, NativeHandle) ? cast value : new LocalHandle(value);
		var types:Array<String> = handle.rawGet("__ss_types");
		return handle.rawGet("__ss_class") == name || handle.rawGet("__ss_enum") == name || (types != null && types.indexOf(name) >= 0);
	}

	public static function read(value:Dynamic, name:String):Dynamic {
		if (Std.isOfType(value, NativeHandle)) {
			var h:NativeHandle = cast value;
			return StringTools.startsWith(name, "__ss_raw_") ? h.rawGet(name.substr(9)) : h.read(name);
		}
		if (Std.isOfType(value, NativeDescriptor))
			return (cast value : NativeDescriptor).read(name);
		if (Std.isOfType(value, NativeView))
			return (cast value : NativeView).read(name);
		if (Std.isOfType(value, NativeInstance)) {
			var b = (cast value : NativeInstance).__ss_binding;
			if (b.has(name))
				return b.self.read(name);
			if (b.hasField(name))
				b.checkFieldAccess(name, false);
		}
		if (value != null && (Reflect.field(value, "__ss_access") != null || Reflect.field(value, "__ss_superfields") != null))
			return new LocalHandle(value).read(name);
		return Reflect.getProperty(value, name);
	}

	public static function write(value:Dynamic, name:String, v:Dynamic):Void {
		if (Std.isOfType(value, NativeHandle)) {
			var h:NativeHandle = cast value;
			if (StringTools.startsWith(name, "__ss_raw_"))
				h.rawSet(name.substr(9), v);
			else
				h.write(name, v);
			return;
		}
		if (Std.isOfType(value, NativeDescriptor)) {
			(cast value : NativeDescriptor).write(name, v);
			return;
		}
		if (Std.isOfType(value, NativeView)) {
			(cast value : NativeView).write(name, v);
			return;
		}
		if (Std.isOfType(value, NativeInstance)) {
			var b = (cast value : NativeInstance).__ss_binding;
			if (b.has(name)) {
				b.self.write(name, v);
				return;
			}
			if (b.hasField(name))
				b.checkFieldAccess(name, true);
		}
		if (value != null && (Reflect.field(value, "__ss_access") != null || Reflect.field(value, "__ss_superfields") != null)) {
			new LocalHandle(value).write(name, v);
			return;
		}
		Reflect.setProperty(value, name, unwrap(v));
	}

	#if macro
	public static function register(base:String, ?interfaces:Array<String>):Void
		NativeMacro.register(base, interfaces == null ? [] : interfaces);
	#end
}

class NativeAPI {
	var owner:Void->Int;
	var allowed:Void->Bool;
	var script:Void->ScriptOwner;

	public function new(?owner:Void->Int, ?allowed:Void->Bool, ?script:Void->ScriptOwner) {
		this.owner = owner;
		this.allowed = allowed;
		this.script = script;
	}

	public function type(name:String):NativeDescriptor {
		if (allowed != null && !allowed())
			throw "Native adapters are unavailable in sandboxed scripts";
		return NativeTypes.descriptor(name);
	}

	public function prepare(value:Dynamic, key:String):NativeBinding {
		if (allowed != null && !allowed())
			throw "Native adapters are unavailable in sandboxed scripts";
		var token = owner == null ? 0 : owner();
		return new NativeBinding(NativeTypes.handle(value), key, owner == null ? null : function() {
			return owner() == token && token >= 0;
		}, script == null ? null : script());
	}

	public function construct(binding:NativeBinding):Void
		binding.construct([]);

	public function cancel(binding:NativeBinding):Void
		binding.release();

	public function finish(value:Dynamic):Dynamic {
		var handle = NativeTypes.handle(value),
			b:NativeBinding = handle.rawGet("__ss_binding");
		if (b == null || b.host == null)
			throw "Native superclass constructor was not called";
		return b.host;
	}
}

class LocalHandle implements NativeHandle {
	var value:Dynamic;

	public function new(value:Dynamic)
		this.value = value;

	public function release():Void {}

	public function has(name:String):Bool
		return Reflect.hasField(value, name);

	public function rawGet(name:String):Dynamic
		return Reflect.field(value, name);

	public function rawSet(name:String, v:Dynamic):Void
		Reflect.setField(value, name, v);

	public function read(name:String):Dynamic {
		if (StringTools.startsWith(name, "__ss_raw_"))
			return rawGet(name.substr(9));
		var receiver = Reflect.field(value, "__ss_receiver"),
			fields = Reflect.field(value, "__ss_superfields");
		var superProperty = fields == null ? null : Reflect.field(fields, name);
		if (receiver != null && superProperty != null) {
			if (superProperty.get == "get")
				return Reflect.callMethod(null, rawGet("get_" + name), []);
			if (superProperty.get == "never")
				throw "Cannot read property: " + name;
			var h = NativeTypes.handle(receiver),
				binding:NativeBinding = h.rawGet("__ss_binding");
			if (!h.has(name) && binding != null && binding.hasField(name))
				return binding.readBase(name);
			return h.rawGet(name);
		}
		var access = Reflect.field(value, "__ss_access"),
			prop = access == null ? null : Reflect.field(access, name);
		if (prop != null) {
			var mode:String = Reflect.field(prop, "get");
			if (mode == "get")
				return Reflect.callMethod(null, rawGet("get_" + name), []);
			if (mode == "null" || mode == "never")
				throw "Cannot read property: " + name;
		}
		var parent = Reflect.field(value, "__ss_parent");
		return !has(name) && parent != null ? NativeTypes.read(parent, name) : rawGet(name);
	}

	public function write(name:String, v:Dynamic):Void {
		if (StringTools.startsWith(name, "__ss_raw_")) {
			rawSet(name.substr(9), v);
			return;
		}
		var receiver = Reflect.field(value, "__ss_receiver"),
			fields = Reflect.field(value, "__ss_superfields");
		var superProperty = fields == null ? null : Reflect.field(fields, name);
		if (receiver != null && superProperty != null) {
			if (superProperty.set == "set") {
				Reflect.callMethod(null, rawGet("set_" + name), [v]);
				return;
			}
			if (superProperty.set == "never")
				throw "Cannot write property: " + name;
			var h = NativeTypes.handle(receiver),
				binding:NativeBinding = h.rawGet("__ss_binding");
			if (!h.has(name) && binding != null && binding.hasField(name))
				binding.writeBase(name, v);
			else
				h.rawSet(name, v);
			return;
		}
		var access = Reflect.field(value, "__ss_access"),
			prop = access == null ? null : Reflect.field(access, name);
		if (prop != null) {
			var mode:String = Reflect.field(prop, "set");
			if (mode == "set") {
				Reflect.callMethod(null, rawGet("set_" + name), [v]);
				return;
			}
			if (mode == "null" || mode == "never")
				throw "Cannot write property: " + name;
		}
		var parent = Reflect.field(value, "__ss_parent");
		if (!has(name) && parent != null)
			NativeTypes.write(parent, name, v);
		else
			rawSet(name, v);
	}
}
