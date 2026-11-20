package hscript;

typedef ScriptError = {
	var script:SScript;
	var error:Dynamic;
	var operation:String;
	var functionName:Null<String>;
	var origin:String;
	var stack:String;
}
