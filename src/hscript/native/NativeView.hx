package hscript.native;

class NativeView {
	var binding:NativeBinding;
	var descriptor:NativeDescriptor;

	public function new(binding, descriptor) {
		this.binding = binding;
		this.descriptor = descriptor;
	}

	public function read(name:String):Dynamic {
		if (name == "__ss_ctor")
			return Reflect.makeVarArgs(binding.construct);
		if (descriptor.methods.indexOf(name) >= 0)
			return Reflect.makeVarArgs(function(args) return binding.superCall(name, args));
		return binding.readBase(name);
	}

	public function write(name:String, value:Dynamic):Void
		binding.writeBase(name, value);
}
