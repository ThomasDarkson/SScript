package hscript.native;

interface NativeHandle {
	function release():Void;
	function has(name:String):Bool;
	function rawGet(name:String):Dynamic;
	function rawSet(name:String, value:Dynamic):Void;
	function read(name:String):Dynamic;
	function write(name:String, value:Dynamic):Void;
}
