package hscript;

import haxe.Exception;
import haxe.Timer;

import hscriptBase.*;
import hscriptBase.Expr;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

import hscript.backend.*;
import hscript.backend.Preset.PresetMode;

using StringTools;

private typedef UnlockedFunctionCall =
{
	public var succeeded:Bool;
	public var calledFunction:String;
	public var returnValue:Null<Dynamic>;
	public var exceptions:Array<Exception>;
	public var lastReportedTime:Float;
}

/**
	Structure containing several useful pieces of information about function calls.
**/
typedef FunctionCall =
{
	/**
		If the call was successful or not.
	**/
	public var succeeded(default, null):Bool;

	/**
		Name of the function that was called.
	**/
	public var calledFunction(default, null):String;

	/**
		Function's return value. Will be null if there is no value.
	**/
	public var returnValue(default, null):Null<Dynamic>;

	/**
		Errors that occurred during this call. Will be empty if none occurred.
	**/
	public var exceptions(default, null):Array<Exception>;

	/**
		How many seconds it took to call this function.

		It will be -1 if the call was unsuccessful.
	**/
	public var lastReportedTime(default, null):Float;
}

/**
	A HScript execution helper with functions for parsing, executing, and interacting with haxe scripts.

	To get started, create an SScript instance:
	
	```haxe
	import hscript.SScript;
	class Main {
		static function main() {
			var script = new SScript();
			script.doString('
				function method()
				{
					var num = null;
					return num + 1;
				}
			');

			var call = script.call('method');
			trace(call.returnValue, call.exceptions[0]); // null, Float should be Int
		}
	}
	```

	@see `doString`
	@see `set`
	@see `call`
**/
@:structInit
@:access(hscript.backend.Preset)
@:access(hscriptBase.Interp)
@:access(hscriptBase.Parser)
@:access(hscriptBase.Tools)
@:keepSub
class SScript
{
	/**
		If not null, enables the improved field system for every script.
		
		With this enabled, one can access available classes or enums using their full name,
		making `import` optional in scripts.

		Example:

		`trace(sys.FileSystem.exists("hscript/SScript.hx")); // true` 

		This may be exhausting for old or weak computers. 
		Set this to null if you experience performance problems.
	**/
	public static var defaultImprovedField:Null<Bool> = false;

	/**
		If not null, enables debug traces for `doString` and `new()`. 
	**/
	public static var defaultDebug:Null<Bool> = null;

	/**
		Default preset mode for Haxe classes.

		MINI contains only basic classes like `Math`,
		while REGULAR contains most cross-target Haxe classes.

		Default is `MINI`. Use `NONE` for no preset.
	**/
	public static var defaultPreset:PresetMode = MINI;

	/**
		If not null, when a script is created, the function with this name
		will automatically be called.

		Default is `"main"`.
	**/
	public static var defaultFun:{functionName:String, ?arguments:Array<Dynamic>} = {functionName: "main"};

	/**
		Every created SScript instance will be stored in this map.

		The instances will be mapped with their script file path if they were created with a script file.

		Otherwise, they will use numbers for mapping. This number increases with every created SScript instance and can be accessed with `ID`.
	**/
	public static var global(default, null):Map<String, SScript> = [];

	/**
		Variables in this map will get set to all created SScript instance.
	**/
	public static var globalVariables(default, null):Map<String, Dynamic> = [];
	
	static var IDCount(default, null):Int = 0;
	
	/**
		Script-specific default function name.

		If not null, this function will be called automatically after execution.
	**/
	public var defaultFunc:{functionName:String, ?arguments:Array<Dynamic>} = null;

	/**
		If not null, enables the improved field system for this script.

		Default is `true`.

		@see `SScript.defaultImprovedField`
	**/
	public var improvedField(default, set):Bool = false;

	/**
		A custom origin you can assign to this script.

		If not null, this will act as the script's file path for error reporting.
	**/
	public var customOrigin(default, set):String;

	/**
		The script's own return value.

		This is separate from individual function return values.
	**/
	public var returnValue(default, null):Null<Dynamic>;

	/**
		Unique ID for this script instance, used when no script file is provided.
	**/
	public var ID(default, null):Null<Int> = null;

	/**
		Reports how many seconds it took to execute this script.

		It will be -1 if execution failed.
	**/
	public var lastReportedTime(default, null):Float = -1;

	/**
		Used by `set`. If a class is assigned while listed here,
		an exception will be thrown.
	**/
	public var notAllowedClasses(default, null):Array<Class<Dynamic>> = [];

	/**
		Preset tool for this script.
	**/
	public var presetter(default, null):Preset;

	/**
		Use this to access to interpreter's variables!
	**/
	public var variables(get, never):Map<String, Dynamic>;

	/**
		Main interpreter responsible for executing this script.

		Do NOT modify `interp.variables` directly.
		Use `set()` instead.
	**/
	public var interp(default, null):Interp;

	/**
		Parser instance used to parse scripts.
	**/
	public var parser(default, null):Parser;

	/**
		The script source code to execute.
	**/
	public var script(default, null):String = "";

	/**
		Whether this script is active.

		Set to false to prevent execution.
	**/
	public var active:Bool = true;

	/**
		Read-only path of the script file, if loaded from disk.
	**/
	public var scriptFile(default, null):String = "";

	/**
		If true, enables error traces from script functions.
	**/
	public var traces:Bool = false;

	/**
		If true, enables debug traces from `doString`.
	**/
	public var debugTraces:Bool = false;

	/**
		Most recently called function in this script. Can be `null`!
	**/
	public var lastFunctionCall(default, null):FunctionCall;

	/**
		Most recent parsing error, if any.
	**/
	public var parsingException(default, null):Exception;

	/**
		Package path of this script.
	**/
	public var packagePath(get, null):String = "";

	@:noPrivateAccess var _destroyed(default, null):Bool;

	/**
		Creates a new SScript instance.

		@param scriptPath Script file path or raw hscript code.
		@param preset Whether to apply default preset variables.
		@param startExecute Whether to execute the script immediately. (Recommended)
	**/
	public function new(?scriptPath:String = "", ?preset:Bool = true, ?startExecute:Bool = true)
	{
		var time = Timer.stamp();

		if (defaultDebug != null)
			debugTraces = defaultDebug;
		if (defaultFun != null)
			defaultFunc = defaultFun;

		interp = new Interp();
		interp.setScr(this);
		
		if (defaultImprovedField != null)
			improvedField = defaultImprovedField;
		else 
			improvedField = false;

		parser = new Parser();

		presetter = new Preset(this);
		if (preset)
			this.preset();

		for (i => k in globalVariables)
		{
			var name:String = i;
			if (name != null) {
				if (name.endsWith("-final") && name.length > 6)
					set(name.substring(0, name.length - 6), k, true);
				else
					set(i, k, false);
			}
		}

		try 
		{
			doFile(scriptPath);
			if (startExecute)
				execute();
			lastReportedTime = Timer.stamp() - time;

			if (debugTraces && scriptPath != null && scriptPath.length > 0)
			{
				if (lastReportedTime == 0)
					trace('Script executed instantly (0 seconds)');
				else 
					trace('Script executed in ${lastReportedTime} seconds');
			}
		}
		catch (e)
		{
			lastReportedTime = -1;
		}
	}

	/**
		Executes this script once.

		This must be called at least once before calling script-defined functions.

		Don't call this if the script was already executed when creating its instance with the `startExecute` argument set to true.
	**/
	public function execute():Void
	{
		if (_destroyed || !active)
			return;

		parsingException = null;

		var origin:String = {
			if (customOrigin != null && customOrigin.length > 0)
				customOrigin;
			else if (scriptFile != null && scriptFile.length > 0)
				scriptFile;
			else 
				"SScript";
		};

		if (script != null && script.length > 0)
		{
			resetInterp();

			function tryHaxe()
			{
				try 
				{
					var expr:Expr = parser.parseString(script, origin);
					var r = interp.execute(expr);
					returnValue = r;
				}
				catch (e) 
				{
					parsingException = e;				
					returnValue = null;
				}
				
				if (defaultFunc != null)
					call(defaultFunc.functionName, defaultFunc.arguments);
			}
			
			tryHaxe();
		}
	}

	/**
		Sets a variable in this script.

		If the key already exists, it will be replaced.
		@param key Variable name.
		@param obj The object to set. Can be left blank.
		@param setAsFinal Whether to set the object as final. If set as final,
		the object will act as a final variable and cannot be changed in the script.
		@return Returns this instance for chaining.
	**/
	public function set(key:String, ?obj:Dynamic, ?setAsFinal:Bool = false):SScript
	{
		if (_destroyed)
			return null;
		if (!active)
			return this;
		
		if (key == null || key.trim().length == 0)
			throw '$key is not a valid class name';
		else if (obj != null && (obj is Class) && notAllowedClasses.contains(obj))
			throw 'Tried to set ${Type.getClassName(obj)} which is not allowed';
		else if (Tools.keys.contains(key))
			throw '$key is a keyword and cannot be replaced';

		function setVar(key:String, obj:Dynamic):Void
		{
			if (setAsFinal)
				interp.finalVariables[key] = obj;
			else
				interp.variables[key] = obj;
		}

		setVar(key, obj);
		return this;
	}

	/**
		This is a helper function for setting classes easily.
		For example, if `cl` is the `sys.io.File` class, it will be set as `File`.
		@param cl The class to set.
		@return this instance for chaining.
	**/
	public function setClass(cl:Class<Dynamic>):SScript
	{
		if (_destroyed)
			return null;
		
		if (cl == null)
		{
			if (traces)
			{
				trace('Class cannot be null');
			}

			return null;
		}

		var clName:String = Type.getClassName(cl);
		if (clName != null)
		{
			var splitCl:Array<String> = clName.split('.');
			if (splitCl.length > 1)
			{
				clName = splitCl[splitCl.length - 1];
			}

			set(clName, cl);
		}
		return this;
	}

	/**
		Sets a class in this script from a string.
		`cl` will be formatted. For example: `sys.io.File` -> `File`.
		@param cl The class to set.
		@return this instance for chaining.
	**/
	public function setClassString(cl:String):SScript
	{
		if (_destroyed)
			return null;

		if (cl == null || cl.length < 1)
		{
			if (traces)
				trace('Class cannot be null');

			return null;
		}

		var cls:Class<Dynamic> = Type.resolveClass(cl);
		if (cls != null)
		{
			var parts = cl.split('.');
			if (parts.length > 1)
				cl = parts[parts.length - 1];

			set(cl, cls);
		}
		return this;
	}

	/**
		A special object is checked when a variable is not found in this script instance.

		A special object can't be a basic type like Int, String, Float, Array, or Bool.

		Instead, use it for something like a state instance.
		@param obj The special object. 
		@param includeFunctions If false, functions in the special object will be ignored.
		@param exclusions Optional array of fields you want to exclude.
		@return Returns this instance for chaining.
	**/
	public function setSpecialObject(obj:Dynamic, ?includeFunctions:Bool = true, ?exclusions:Array<String>):SScript
	{
		if (_destroyed)
			return null;
		if (!active)
			return this;
		if (obj == null)
			return this;
		if (exclusions == null)
			exclusions = new Array();

		var types:Array<Dynamic> = [Int, String, Float, Bool, Array];
		for (i in types)
			if (Std.isOfType(obj, i))
				throw 'Special object cannot be ${i}';

		if (interp.specialObject == null)
			interp.specialObject = {obj: null, includeFunctions: null, exclusions: null};

		interp.specialObject.obj = obj;
		interp.specialObject.exclusions = exclusions.copy();
		interp.specialObject.includeFunctions = includeFunctions;
		return this;
	}
	
	/**
		Returns the local variables of this script as a fresh map.

		Changing any value in the returned map will not change the script's variables.
	**/
	public function locals():Map<String, Dynamic>
	{
		if (_destroyed)
			return null;

		if (!active)
			return [];

		var newMap:Map<String, Dynamic> = new Map();
		for (i in interp.locals.keys())
		{
			var v = interp.locals[i];
			if (v != null)
				newMap[i] = v.r;
		}
		return newMap;
	}

	/**
		Removes a variable from this script. 

		If a variable named `key` does not exist, this function won't do anything.
		@param key Variable name to remove.
		@return Returns this instance for chaining.
	**/
	public function remove(key:String):SScript
	{
		if (_destroyed)
			return this;
		if (key == null || key.trim().length == 0)
			return this;
		if (!active)
			return this;

		if (interp.finalVariables.exists(key))
			interp.finalVariables.remove(key);
		if (interp.variables.exists(key))
			interp.variables.remove(key);

		return this;
	}

	@:deprecated('Use remove instead')
	public function unset(key:String):SScript
	{
		return remove(key);
	}

	/**
		Gets a variable by name. 

		If a variable named `key` does not exist, `null` is returned.
		@param key Variable name.
		@return The object got by name.
	**/
	public function get(key:String):Dynamic
	{
		if (_destroyed)
			return null;
		if (key == null || key.trim().length == 0)
			return null;

		if (!active)
		{
			if (traces)
				trace("This script is not active!");

			return null;
		}

		if (interp.locals.exists(key))
       		return interp.locals.get(key).r;

		var r = interp.finalVariables.get(key);
		if (r == null)
			r = interp.variables.get(key);

		return r;
	}

	/**
		Calls a function from this script.

		**WARNING**:
		The script must be executed at least once before calling functions.

		@param func Function name in script. 
		@param args Arguments for `func`. If the function does not require arguments, leave this as `null`.
		@return Returns a `FunctionCall` object.
	**/
	public function call(func:String, ?args:Array<Dynamic> = null):FunctionCall
	{
		if (_destroyed)
			return {
				exceptions: [new Exception((if (scriptFile != null && scriptFile.length > 0) scriptFile else "SScript instance") + " is destroyed.")],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};

		if (!active)
			return {
				exceptions: [new Exception((if (scriptFile != null && scriptFile.length > 0) scriptFile else "SScript instance") + " is not active.")],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};

		var time:Float = Timer.stamp();

		var scriptFile:String = if (scriptFile != null && scriptFile.length > 0) scriptFile else "";
		var caller:UnlockedFunctionCall = {
			exceptions: [],
			calledFunction: func,
			succeeded: false,
			returnValue: null,
			lastReportedTime: -1
		}
		if (args == null)
			args = new Array();

		var pushedExceptions:Array<String> = new Array();
		function pushException(e:String)
		{
			if (!pushedExceptions.contains(e))
				caller.exceptions.push(new Exception(e));
			
			pushedExceptions.push(e);
		}
		if (func == null || func.trim().length == 0)
		{
			if (traces)
				trace('Function name cannot be invalid for $scriptFile!');

			pushException('Function name cannot be invalid for $scriptFile!');
			return caller;
		}
		
		var fun = get(func);
		if (fun != null && Type.typeof(fun) != TFunction)
		{
			if (traces)
				trace('$func is not a function');

			pushException('$func is not a function');
		}
		else if (fun == null)
		{
			if (traces)
				trace('Function $func does not exist in $scriptFile.');

			if (scriptFile != null && scriptFile.length > 0)
				pushException('Function $func does not exist in $scriptFile.');
			else 
				pushException('Function $func does not exist in this SScript instance. ID: ' + this.ID);
		}
		else 
		{
			var oldCaller = caller;
			try
			{
				var functionField:Dynamic = Reflect.callMethod(this, fun, args);
				caller = {
					exceptions: caller.exceptions,
					calledFunction: func,
					succeeded: true,
					returnValue: functionField,
					lastReportedTime: -1
				};
				caller.lastReportedTime = Timer.stamp() - time;
			}
			catch (e)
			{
				caller = oldCaller;
				caller.exceptions.insert(0, e);
			}

			lastFunctionCall = caller;
		}

		return caller;
	}

	/**
		Clears all variables assigned to this script.

		@return Returns this instance for chaining.
	**/
	public function clear():SScript
	{
		if (_destroyed)
			return null;
		if (!active)
			return this;

		for (i in interp.variables.keys())
				interp.variables.remove(i);

		for (i in interp.finalVariables.keys())
			interp.finalVariables.remove(i);

		return this;
	}

	/**
		Checks whether `key` exists in this script's interpreter.
		@param key The variable name to look for.
		@return Returns true if `key` is found in the interpreter.
	**/
	public function exists(key:String):Bool
	{
		if (_destroyed)
			return false;
		if (!active)
			return false;
		if (key == null || key.trim().length == 0)
			return false;

		if (interp.locals.exists(key))
        	return true;
		if (interp.finalVariables.exists(key))
			return true;
		if (interp.variables.exists(key))
			return true;

		return false;
	}

	/**
		Sets useful default variables to make this script easier to use.
		Override this function to set your custom values as well.

		Don't forget to call `super.preset()`!
	**/
	public function preset():Void
	{
		if (_destroyed)
			return;
		if (!active)
			return;

		presetter.preset();
	}

	function resetInterp():Void
	{
		if (_destroyed)
			return;

		interp.locals = #if haxe3 new Map() #else new Hash() #end;
		while (interp.declared.length > 0)
			interp.declared.pop();
	}

	function destroyInterp():Void 
	{
		if (_destroyed)
			return;

		interp.specialObject = null;
		interp.script = null;
		interp.locals = null;
		interp.variables = null;
		interp.finalVariables = null;
		interp.declared = null;
	}

	function useIDForGlobal() 
	{
		if (ID == null) {
			ID = IDCount + 1;
			IDCount++;
		}
		global[Std.string(ID)] = this;
	}

	function doFile(scriptPath:String):Void
	{
		if (_destroyed)
			return;

		if (scriptPath == null || scriptPath.length < 1 || StringTools.trim(scriptPath).length == 0)
		{
			useIDForGlobal();
			return;
		}

		if (scriptPath != null && scriptPath.length > 0)
		{
			#if sys
			if (FileSystem.exists(scriptPath))
			{
				scriptFile = scriptPath;
				script = File.getContent(scriptPath);
			}
			else
			{
				scriptFile = "";
				script = scriptPath;
			}
			#else
			scriptFile = "";
			script = scriptPath;
			#end

			if (scriptFile != null && scriptFile.length > 0)
				global[scriptFile] = this;
			else if (script != null && script.length > 0)
				useIDForGlobal();
		}
	}

	/**
		Executes a string once instead of a script file.

		This does not change `scriptFile`, but it does change `script`.

		Even though this function is faster,
		it should be avoided whenever possible.
		Always try to use a script file.
		@param string The string you want to execute. If this argument is a file path, this will behave like `new()` and will change `scriptFile`.
		@param origin Optional origin to use for this script, it will appear on traces.
		@return Returns this instance for chaining. Returns `null` if it fails.
	**/
	public function doString(string:String, ?origin:String):SScript
	{
		if (_destroyed)
			return null;
		if (!active)
			return null;
		if (string == null || string.length < 1 || StringTools.trim(string).length == 0)
			return this;

		parsingException = null;

		var time = Timer.stamp();
		try 
		{
			#if sys
			if (string.length < 260 && FileSystem.exists(string))
			{
				scriptFile = string;
				origin = string;
				string = File.getContent(string);
			}
			#end

			var og:String = origin;
			if (og != null && og.length > 0)
				customOrigin = og;
			if (og == null || og.length < 1)
				og = customOrigin;
			if (og == null || og.length < 1)
				og = "SScript";

			resetInterp();
		
			script = string;
			
			if (scriptFile != null && scriptFile.length > 0)
			{
				global[scriptFile] = this;
			}
			else if (script != null && script.length > 0)
			{
				useIDForGlobal();
			}

			function tryHaxe()
			{
				try 
				{
					var expr:Expr = parser.parseString(script, og);
					var r = interp.execute(expr);
					returnValue = r;
				}
				catch (e) 
				{
					parsingException = e;				
					returnValue = null;
				}

				if (defaultFunc != null)
					call(defaultFunc.functionName, defaultFunc.arguments);
			}

			tryHaxe();	
			
			lastReportedTime = Timer.stamp() - time;
 
			if (debugTraces)
			{
				if (lastReportedTime == 0)
					trace('SScript instance brewed instantly (0s)');
				else 
					trace('SScript instance brewed in ${lastReportedTime}s');
			}
		}
		catch (e) lastReportedTime = -1;

		return this;
	}

	inline function toString():String
	{
		if (_destroyed)
			return "null";

		if (scriptFile != null && scriptFile.length > 0)
			return scriptFile;

		return "[SScript]";
	}

	#if sys
	/**
		Finds scripts in the provided path and returns them in an array.

		Make sure `path` is a directory!

		If `extensions` is not `null`, file extensions will be checked.
		Otherwise, only files with the `.hx` extensions will be checked and listed.

		@param path The directory to check. Non-directory paths will be ignored.
		@param extensions Optional extension to check in file names.
		@return An array of found scripts.
	**/
	#else
	/**
		Finds scripts in the provided path and returns them in an array.

		This function will always return an empty array, because you are targeting an unsupported target.
		@return An empty array.
	**/
	#end
	public static function listScripts(path:String, ?extensions:Array<String>):Array<SScript>
	{
		if (!path.endsWith('/'))
			path += '/';

		if (extensions == null || extensions.length < 1)
			extensions = ['hx'];

		var list:Array<SScript> = [];
		#if sys
		if (FileSystem.exists(path) && FileSystem.isDirectory(path))
		{
			var files:Array<String> = FileSystem.readDirectory(path);
			for (i in files)
			{
				var hasExtension:Bool = false;
				for (l in extensions)
				{
					if (i.endsWith(l))
					{
						hasExtension = true;
						break;
					}
				}
				if (hasExtension && FileSystem.exists(path + i))
					list.push(new SScript(path + i));
			}
		}
		#end
		
		return list;
	}

	/**
		This function makes this script instance completely unusable and impossible to restore.

		If you don't want to destroy your script just yet, just set `active` to false!

		Override this function if you set up other variables to destroy them.
	**/
	public function destroy():Void
	{
		if (_destroyed)
			return;

		if (global.exists(scriptFile) && scriptFile != null && scriptFile.length > 0)
			global.remove(scriptFile);
		if (ID != null && global.exists(Std.string(ID)))
			global.remove(Std.string(ID));

		presetter.destroy();

		clear();
		resetInterp();
		destroyInterp();

		parsingException = null;
		customOrigin = null;
		parser = null;
		interp = null;
		script = null;
		scriptFile = null;
		active = false;
		notAllowedClasses = null;
		lastReportedTime = -1;
		ID = null;
		returnValue = null;
		_destroyed = true;
	}

	function get_variables():Map<String, Dynamic>
	{
		if (_destroyed)
			return null;

		return interp.variables;
	}

	function setPackagePath(p):String
	{
		if (_destroyed)
			return null;

		return packagePath = p;
	}

	function get_packagePath():String
	{
		if (_destroyed)
			return null;

		return packagePath;
	}

	function set_customOrigin(value:String):String
	{
		if (_destroyed)
			return null;
		
		@:privateAccess parser.origin = value;
		return customOrigin = value;
	}

	function set_improvedField(value:Bool):Bool
	{
		if (_destroyed)
			return false;

		if (interp != null)
			interp.improvedField = value;
		return improvedField = value;
	}
}