package hscript.native;

class NativeDescriptor {
	public var name:String;
	public var alias:String;
	public var nativeType:Dynamic;
	public var isInterface:Bool;
	public var stub:String;
	public var methods:Array<String>;
	public var fields:Dynamic;

	public function new(name:String, alias:String, nativeType:Dynamic, isInterface:Bool, stub:String, methods:Array<String>, fields:Dynamic) {
		this.name = name;
		this.alias = alias;
		this.nativeType = nativeType;
		this.isInterface = isInterface;
		this.stub = stub;
		this.methods = methods;
		this.fields = fields;
	}

	public function read(name:String):Dynamic {
		if (name == "__ss_name")
			return alias;
		if (name == "__ss_nativeType")
			return nativeType;
		if (name == "__ss_interface")
			return isInterface;
		if (name == "__ss_build")
			return function(self:Dynamic):Dynamic {
				var binding:NativeBinding = NativeTypes.handle(self).rawGet("__ss_binding");
				return binding.build(this);
			};
		if (name == "__ss_create")
			return Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic {
				if (isInterface)
					throw "Cannot instantiate interface: " + this.name;
				return Type.createInstance(cast nativeType, [for (a in args) NativeTypes.unwrap(a)]);
			});
		if (StringTools.startsWith(name, "__ss_raw_"))
			name = name.substr(9);
		var owner = cast(nativeType, Class<Dynamic>);
		while (owner != null && !Reflect.hasField(owner, name))
			owner = Type.getSuperClass(owner);
		return Reflect.getProperty(owner == null ? nativeType : owner, name);
	}

	public function write(name:String, value:Dynamic):Void {
		if (StringTools.startsWith(name, "__ss_raw_"))
			name = name.substr(9);
		var owner = cast(nativeType, Class<Dynamic>);
		while (owner != null && !Reflect.hasField(owner, name))
			owner = Type.getSuperClass(owner);
		Reflect.setProperty(owner == null ? nativeType : owner, name, NativeTypes.unwrap(value));
	}
}
