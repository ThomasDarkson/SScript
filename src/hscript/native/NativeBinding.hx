package hscript.native;

private typedef ScriptOwner = #if macro Dynamic #else hscript.SScript #end;

@:keep
class NativeBinding {
	public var self:NativeHandle;
	public var host:Dynamic;

	var adapter:Class<Dynamic>;
	var base:NativeDescriptor;
	var constructing = false;
	var released = false;
	var alive:Void->Bool;
	var owner:ScriptOwner;

	public function new(self:NativeHandle, key:String, ?alive:Void->Bool, ?owner:ScriptOwner) {
		this.owner = owner;
		this.alive = alive;
		this.self = self;
		var entry = NativeTypes.adapterFor(key);
		if (entry == null)
			throw "Native adapter is not registered: " + key;
		adapter = entry.adapter;
		base = entry.base == "" ? null : NativeTypes.descriptor(entry.base);
	}

	public function attach(host:Dynamic):Void {
		this.host = host;
		self.rawSet("__ss_host", new NativeHost(host));
	}

	public function build(descriptor:NativeDescriptor):NativeView {
		for (name in descriptor.methods) {
			var method = name;
			self.rawSet(method, Reflect.makeVarArgs(function(args) return superCall(method, args)));
		}
		return new NativeView(this, descriptor);
	}

	public function construct(args:Array<Dynamic>):Dynamic {
		if (host != null || constructing)
			throw "Native superclass constructor already called";
		constructing = true;
		try {
			Type.createInstance(adapter, [this, [for (a in args) NativeTypes.unwrap(a)]]);
			constructing = false;
		} catch (e:Dynamic) {
			constructing = false;
			throw e;
		}
		return null;
	}

	public function release():Void {
		if (!released) {
			released = true;
			self.release();
		}
	}

	function check():Void {
		if (alive != null && !alive())
			throw "Native script instance belongs to a destroyed or reloaded script";
		if (released)
			throw "Native script binding was released";
	}

	function boundary<T>(name:String, body:Void->T):T {
		return owner == null || owner.errorBoundaryDepth > 0 ? body() : owner.withErrorBoundary(body);
	}

	public function has(name:String):Bool
		return boundary(name, function() {
			check();
			return self.has(name);
		});

	public function invoke(name:String, args:Array<Dynamic>):Dynamic {
		return boundary(name, function() return invokeInternal(name, args));
	}

	function invokeInternal(name:String, args:Array<Dynamic>):Dynamic {
		check();
		var fn = self.rawGet(name);
		if (fn == null)
			throw "Missing script implementation: " + name;
		return NativeTypes.unwrap(Reflect.callMethod(null, fn, args));
	}

	public function readField(name:String):Dynamic
		return boundary(name, function() {
			check();
			return NativeTypes.unwrap(self.read(name));
		});

	public function writeField(name:String, value:Dynamic):Dynamic
		return boundary(name, function() {
			check();
			self.write(name, value);
			return value;
		});

	public function superCall(name:String, args:Array<Dynamic>):Dynamic {
		check();
		if (host == null)
			throw "Native member used before super(...): " + name;
		return (cast host : NativeInstance).sscriptSuperCall(name, [for (a in args) NativeTypes.unwrap(a)]);
	}

	public function hasField(name:String):Bool
		return base != null && Reflect.hasField(base.fields, name);

	public function checkFieldAccess(name:String, write:Bool):Void {
		check();
		var prop = base == null ? null : Reflect.field(base.fields, name);
		var mode = prop == null ? null : Reflect.field(prop, write ? "set" : "get");
		if (mode == "null" || mode == "never")
			throw "Cannot " + (write ? "write" : "read") + " property: " + name;
	}

	public function readBase(name:String):Dynamic {
		check();
		if (host == null)
			throw "Native field used before super(...): " + name;
		var prop = base == null ? null : Reflect.field(base.fields, name);
		if (prop != null && Reflect.field(prop, "get") == "get")
			return superCall("get_" + name, []);
		return Reflect.getProperty(host, name);
	}

	public function writeBase(name:String, value:Dynamic):Void {
		check();
		if (host == null)
			throw "Native field used before super(...): " + name;
		var prop = base == null ? null : Reflect.field(base.fields, name);
		if (prop != null && Reflect.field(prop, "set") == "set") {
			superCall("set_" + name, [value]);
			return;
		}
		Reflect.setProperty(host, name, NativeTypes.unwrap(value));
	}
}

class NativeHost {
	public var value:Dynamic;

	public function new(value:Dynamic)
		this.value = value;
}
