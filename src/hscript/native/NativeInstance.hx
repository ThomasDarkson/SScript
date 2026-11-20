package hscript.native;

@:keep
interface NativeInstance {
	public var __ss_binding:NativeBinding;
	function sscriptSuperCall(name:String, args:Array<Dynamic>):Dynamic;
}
