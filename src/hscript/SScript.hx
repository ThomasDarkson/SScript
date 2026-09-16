package hscript;

import haxe.ds.StringMap;
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
import hscript.backend.HScriptSandbox;
import hscript.backend.HScriptSandbox.HScriptLib;
import hscript.backend.HScriptSandbox.HScriptSandboxSettings;


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
	[![](https://thomasdarkson.com/assets/stickers/sticker.png)](https://thomasdarkson.com)

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

	You can also use files! (Not available on JavaScript)

	```haxe
	import hscript.SScript;
	class Main {
		static function main() {
			var script = new SScript("script.hx");
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
	public static final SSCRIPT_VERSION:String = "23.0.0";
	
	/**
		If not null, enables the improved field system for every script.
		
		With this enabled, one can access available classes or enums using their full name,
		making `import` optional in scripts.

		Example:

		`trace(sys.FileSystem.exists("hscript/SScript.hx")); // true` 

		This may be exhausting for old computers since it uses Reflection. 
		Set this to false if you experience performance problems.
	**/
	public static var defaultImprovedField:Null<Bool> = true;

	/**
		If not null, enables debug traces for `execute`, `doString` and `new()`. 

		@see `debugTraces`
	**/
	public static var defaultDebug:Null<Bool> = null;

	/**
		If not null, enables error traces for all of the methods. 

		@see `traces`
	**/
	public static var defaultTraces:Null<Bool> = null;

	/**
		Default preset mode for Haxe classes.

		**MINI** contains only basic classes like `Math`.

		**REGULAR** contains most cross-target Haxe classes.

		**FULL** contains all existing classes.
		Can get expensive if you're handling a lot of scripts.

		Default is `REGULAR`. Use `NONE` for no preset.
	**/
	public static var defaultPreset(default, set):PresetMode = REGULAR;

	/**
		If not null, when a script is created, the function with this name
		will automatically be called.

		Default is `"main"`.
	**/
	public static var defaultFun:{functionName:String, ?arguments:Array<Dynamic>} = {functionName: "main"};
	
	/**
		If not null, sets the initial value of `interpCompilesFunctionCode` for
		every SScript instance created afterwards.

		@see `interpCompilesFunctionCode`
	**/
	public static var defaultCompile:Null<Bool> = null;

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

	/**
		Parser instance **only** used to parse interpolated strings.
	**/
	public static final stringParser:Parser = new Parser();
	
	static var IDCount(default, null):Int = 0;

	static final scriptCache:StringMap<Expr> = new StringMap();
	
	/**
		Script-specific default function name.

		If not null, this function will be called automatically after execution.
	**/
	public var defaultFunc:{functionName:String, ?arguments:Array<Dynamic>} = null;

	/**
		If true, enables the improved field system for this script.

		@see `SScript.defaultImprovedField`
	**/
	public var improvedField(default, set):Bool = true;

	/**
		Whether this script's functions are compiled into closures the
		first time they're called.

		When `true`, a function's body is compiled once, 
		which is then cached and reused for every call to that same
		function. This trades a one-time, per-function build cost for a
		cheaper path on every call afterwards.

		That trade only pays off once a function is called often enough 
		(e.g. hundreds or thousands of calls, or a function that runs every frame). 
		For a function called once or twice, interpreted mode is slightly faster,
		since it skips the compilation step entirely.

		Interpreter will not compile any code other than function code,
		so this option has no effect on scripts that have no functions in it.
		It will not compile functions that lack a name, either.

		@see `SScript.defaultCompile`
	**/
	public var interpCompilesFunctionCode(default, set):Bool = true;

	#if cpp
	/**
		Whether in compiled functions, local variables are cached and the latest one is used
		instead of re-evaluating local variables, making scripts run faster.

		This feature is available in **C++ only**, and has no effect if `interpCompilesFunctionCode` is `false`.
	**/
	public var interpCachesCompiledLocals(default, set):Bool = true;
	#end

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

		Has no effect since version `23.0.0`.
	**/
	public var notAllowedClasses(default, null):Array<Class<Dynamic>> = [];

	/**
		Preset mode of this script. 

		@see SScript.defaultPreset
	**/
	public var presetMode(default, set):PresetMode;

	/**
		Use this to access to interpreter's variables!
	**/
	public var variables(get, never):Map<String, Dynamic>;

	/**
		Main interpreter responsible for executing this script.

		Do NOT modify `interp.variables` directly.
		Use `set()` or `remove()` instead.
	**/
	public var interp(default, null):Interp;

	/**
		Whether this script is sandboxed.

		A sandboxed script can't name its way to a class it wasn't explicitly
		given: no `new sys.io.File()`, no `Sys.systemName()`, no `import sys.FileSystem;`, 
		no `sys.io.File.getContent(path)`, no `using` a foreign
		class. Whichever `hscript.backend.HScriptSandbox.HScriptLib` categories
		are set in `hscriptBlockedLibs` are unreachable that way. It's also bounded
		by `hscriptInstructionLimit` and `hscriptTimeLimitMs`, so something like a `while(true){}` can't hang the host.

		This is **not** an OS-level sandbox. It restricts implicit class
		resolution by string, not what you set into the script yourself. Anything you expose that way is
		reachable from a sandboxed script exactly as it would be from a normal
		one.

		Re-applied every time `execute()` runs, so it's safe to flip this (and
		other options) between calls to `execute()` on the same instance.

		Defaults to `false`.

		@see `hscript.backend.HScriptSandbox.HScriptLib`
	**/
	public var hscriptSandboxed:Bool = false;

	/**
		Bitmask of `hscript.backend.HScriptSandbox.HScriptLib` flags controlling
		which categories of implicit class access are blocked when
		`hscriptSandboxed` is `true`. Ignored when `hscriptSandboxed` is `false`.

		Defaults to `HScriptLib.SANDBOX_DEFAULT` (every category blocked).
	**/
	public var hscriptBlockedLibs:Int = HScriptLib.SANDBOX_DEFAULT;

	/**
		Additional dotted class paths (or package prefixes) to block regardless
		of `hscriptBlockedLibs`, e.g. `["my.pkg.Secrets"]`. Checked before
		`hscriptBlockedLibs`, and after `hscriptExtraAllowedClasses`.

		Ignored when `hscriptSandboxed` is `false`.
	**/
	public var hscriptExtraBlockedClasses:Array<String> = [];

	/**
		Dotted class paths (or package prefixes) to always allow, even if their
		category would otherwise be blocked by `hscriptBlockedLibs`. Checked
		before `hscriptExtraBlockedClasses`/`hscriptBlockedLibs`.

		Ignored when `hscriptSandboxed` is `false`.
	**/
	public var hscriptExtraAllowedClasses:Array<String> = [];

	/**
		Rough budget on how many expressions a sandboxed script may evaluate
		(checked periodically as the script runs) before it's aborted.

		`<= 0` disables the check. Ignored unless `hscriptSandboxed` is `true`.

		Defaults to `-1`.
	**/
	public var hscriptInstructionLimit:Int = -1;

	/**
		Rough wall-clock budget in milliseconds for a sandboxed script, checked
		on the same periodic check as `hscriptInstructionLimit`.

		`<= 0` disables the check. Ignored unless `hscriptSandboxed` is `true`.

		Defaults to `-1`.
	**/
	public var hscriptTimeLimitMs:Int = -1;

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
		If true, prints one line every time this script is
		(re-)executed, via `execute()`, `doString()`, or the constructor.

		Each line reports which script it was, which method
		ran it, how long it took, and the outcome: the resulting
		`returnValue` on success, or the caught exception's message on
		failure. For example:

		`[SScript #3] doString() ran in 0.0002s -> returned 3`

		`[SScript (script.hx)] execute() ran in 0.0011s -> failed: Unknown variable: a`

		Useful for spotting slow scripts or silent parsing failures without
		having to manually check `parsingException` after
		every call.
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

	var shouldWarn:Bool = true;
	var reportTrace:Bool = true;
	@:noPrivateAccess var _destroyed(default, null):Bool;

	/**
		Creates a new SScript instance.
		
		@param scriptPath The script file path or raw hscript code.
		@param preset Whether to apply the default preset variables.
		@param startExecute Whether to execute the script immediately. (Recommended)
		@param variablesToSet If not null or empty, sets the variables passed to this script before applying `preset`, regardless of the value of argument `preset`.
		@param hscriptSandbox If not null, sandboxes this script according to `hscriptSandboxed`'s documentation. Equivalent to setting `hscriptSandboxed = true` plus whichever fields of `HScriptSandboxSettings` you pass. Has no effect if `startExecute` is false; set the properties directly before calling `execute()` in that case.
	**/
	public function new(?scriptPath:String = "", ?preset:Bool = true, ?startExecute:Bool = true, ?variablesToSet:Array<{name:String, ?variable:Dynamic, ?isFinal:Bool}>, ?hscriptSandbox:HScriptSandboxSettings)
	{
		if (hscriptSandbox != null) {
			hscriptSandboxed = true;
			if (hscriptSandbox.blockedLibs != null)
				this.hscriptBlockedLibs = hscriptSandbox.blockedLibs;
			if (hscriptSandbox.extraBlockedClasses != null)
				this.hscriptExtraBlockedClasses = hscriptSandbox.extraBlockedClasses;
			if (hscriptSandbox.extraAllowedClasses != null)
				this.hscriptExtraAllowedClasses = hscriptSandbox.extraAllowedClasses;
			if (hscriptSandbox.instructionLimit != null)
				this.hscriptInstructionLimit = hscriptSandbox.instructionLimit;
			if (hscriptSandbox.timeLimitMs != null)
				this.hscriptTimeLimitMs = hscriptSandbox.timeLimitMs;
		}

		var time = Timer.stamp();

		if (defaultDebug != null)
			debugTraces = defaultDebug;
		if (defaultFun != null)
			defaultFunc = defaultFun;
		if (defaultTraces != null)
			traces = defaultTraces;

		interp = new Interp();
		interp.setScr(this);

		if (defaultCompile != null)
			interpCompilesFunctionCode = defaultCompile;
		else
			interpCompilesFunctionCode = true;
		
		if (defaultImprovedField != null)
			improvedField = defaultImprovedField;
		else 
			improvedField = true;

		parser = new Parser();

		if (variablesToSet != null && variablesToSet.length > 0)
		{
			for (i in variablesToSet) 
			{
				var name = i.name;
				var v = i.variable;
				var f = i.isFinal;

				if (name != null)
				{
					set(name, v, f);
				}
			}
		}

		presetMode = defaultPreset;
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
			reportTrace = false;
			if (startExecute)
				execute();
			reportTrace = true;
			lastReportedTime = Timer.stamp() - time;

			if (startExecute && scriptPath != null && scriptPath.length > 0)
				debugTrace("new()");
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

		var time = Timer.stamp();

		var origin:String = {
			if (customOrigin != null && customOrigin.length > 0)
				customOrigin;
			else if (scriptFile != null && scriptFile.length > 0)
				scriptFile;
			else 
				toString();
		};

		if (script != null && script.length > 0)
		{
			resetInterp();

			function tryHaxe()
			{
				try 
				{
					var expr:Expr = null;
					if (scriptCache.exists(script))
						expr = scriptCache.get(script);
					else 
					{
						expr = parser.parseString(script, origin);
						scriptCache.set(script, expr);
					}
					var r = interp.execute(expr);
					returnValue = r;
				}
				catch (e) 
				{
					parsingException = e;				
					returnValue = null;
					scriptCache.remove(script);
				}
				
				if (defaultFunc != null) 
				{
					shouldWarn = false;
					call(defaultFunc.functionName, defaultFunc.arguments);
					shouldWarn = true;
				}
			}
			
			tryHaxe();
		}

		lastReportedTime = Timer.stamp() - time;
		if (reportTrace)
			debugTrace("execute()");
	}

	function debugTrace(calledFrom:String):Void
	{
		if (!debugTraces)
			return;

		var buf = new StringBuf();
		buf.add(toString());
		buf.add(" ");
		buf.add(calledFrom);
		buf.add(" ran in ");
		buf.add(Std.string(lastReportedTime));
		buf.add("s -> ");

		if (parsingException != null)
		{
			buf.add("failed: ");
			buf.add(parsingException.message);
		}
		else
		{
			if (returnValue == null)
				buf.add("it was a success and didn't return anything");
			else 
			{
				buf.add("it was a success and returned ");
				buf.add(Std.string(returnValue));
			}
		}

		var bufS = buf.toString();
		trace(bufS);
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
	public function set(key:String, ?obj:Dynamic, ?setAsFinal:Bool = null):SScript
	{
		if (_destroyed)
			return null;
		if (!active)
			return this;
		
		if (key == null) 
		{
			traceError('$key is not a valid variable name', "set", [key, obj, setAsFinal]);
			return this;
		}
		else if (Tools.keys.exists(key))
		{
			traceError('$key is not a keyword therefore cannot be set', "set", [key, obj, setAsFinal]);
			return this;
		}
		interp.variables[key] = { r : obj , isFinal : setAsFinal };

		return this;
	}

	/**
		This is a helper function for setting classes easily.
		For example, if `cl` is the `sys.io.File` class, it will be set as `File`.
		@param cl The class to set.
		@param setAsFinal Whether to set the object as final. If set as final,
		the object will act as a final variable and cannot be changed in the script.
		@return this instance for chaining.
	**/
	public function setClass(cl:Class<Dynamic>, ?setAsFinal:Bool):SScript
	{
		if (_destroyed)
			return null;
		
		if (cl == null)
		{
			if (traces)
			{
				traceError('Class cannot be null', 'setClass', [cl, setAsFinal]);
			}

			return this;
		}

		if (setAsFinal == null)
			setAsFinal = cl != null;

		var clName:String = Type.getClassName(cl);
		if (clName != null)
		{
			var splitCl:Array<String> = clName.split('.');
			if (splitCl.length > 1)
			{
				clName = splitCl[splitCl.length - 1];
			}

			set(clName, cl, setAsFinal);
		}
		return this;
	}

	/**
		This is a helper function for setting enums easily.
		For example, if `en` is the `Type.ValueType` enum, it will be set as `ValueType`.

		All of the enum's constructors are also set, for example `Type.ValueType.TClass(_)` will be set as `TClass`.
		@param en The enum to set.
		@param setAsFinal Whether to set the object as final. If set as final,
		the object will act as a final variable and cannot be changed in the script.
		@param includeAllEnumConstructors If true, all constructors in this enum will also be set in the script.
		@return this instance for chaining.
	**/
	public function setEnum(en:Enum<Dynamic>, ?setAsFinal:Bool, ?includeAllEnumConstructors:Bool = true):SScript
	{
		if (_destroyed)
			return null;
		
		if (en == null)
		{
			if (traces)
			{
				traceError('Enum cannot be null', 'setClass', [en, setAsFinal]);
			}

			return this;
		}

		if (setAsFinal == null)
			setAsFinal = en != null;

		var clName:String = Type.getEnumName(en);
		if (clName != null)
		{
			var splitCl:Array<String> = clName.split('.');
			if (splitCl.length > 1)
			{
				clName = splitCl[splitCl.length - 1];
			}

			set(clName, en, setAsFinal);

			if (includeAllEnumConstructors)
			{
				for (i in Type.getEnumConstructs(en))
					set(i, Reflect.field(en, i), setAsFinal);
			}
		}
		return this;
	}

	/**
		Sets a class in this script from a string.
		`cl` will be formatted. (e.g., `sys.io.File` -> `File`)
		@param cl The class to set.
		@param setAsFinal Whether to set the object as final. If set as final,
		the object will act as a final variable and cannot be changed in the script. 
		@return this instance for chaining.
	**/
	public function setClassString(cl:String, ?setAsFinal:Bool):SScript
	{
		if (_destroyed)
			return null;

		if (cl == null || cl.length < 1)
		{
			if (traces)
				traceError('Class cannot be null', 'setClassString', [cl, setAsFinal]);

			return this;
		}

		var cls:Class<Dynamic> = Type.resolveClass(cl);
		if (cls != null)
		{
			if (setAsFinal == null)
				setAsFinal = cls != null;

			var parts = cl.split('.');
			if (parts.length > 1)
				cl = parts[parts.length - 1];

			set(cl, cls, setAsFinal);
		}
		return this;
	}

	#if (!DISABLED_MACRO_SUPERLATIVE && !python)
	/**
		Sets multiple classes in this script from the provided package.

		@param _package The package name containing the classes (e.g., `sys.io`)
		@param recursive Whether to include classes in sub-packages (e.g., if true and `_package` is `sys`, `sys.io.File` will be included)
		@param setAsFinal Whether to set the classes as final. If set as final,
		the classes will act as a final variable and cannot be changed in the script.
		@return this instance for chaining.
	**/
	public function setByPackage(_package:String, ?recursive:Bool = true, ?setAsFinal:Bool):SScript 
	{
		if (_destroyed)
			return null;

		if (_package == null || (_package = StringTools.trim(_package)).length < 1)
		{
			if (traces)
				traceError('Package name cannot be null or empty', 'setByPackage', [_package, recursive, setAsFinal]);

			return this;
		}

		var prefix:String = _package;
		if (!StringTools.endsWith(_package, "."))
			prefix += ".";
			
		var prefixLength:Int = prefix.length;

		for (i => k in Tools.allClassesAvailable) 
		{
			if (!StringTools.startsWith(i, prefix))
				continue;

			if (!recursive)
			{
				if (i.indexOf('.', prefixLength) != -1)
					continue;
			}

			if (setAsFinal == null)
				setAsFinal = k != null;

			setClass(k, setAsFinal);
		}

		return this;
	}
	#else
	/**
		Sets multiple classes in this script from the provided package.

		**This function will only return this instance for chaining**, **because it requires** `DISABLED_MACRO_SUPERLATIVE` **to be undefined to work properly.**

		@param cl The package name with classes in it (e.g., `sys.io`)
		@param recursive Whether to include classes in sub-packages (e.g., if true and `_package` is `sys`, `sys.io.File` will be included)
		@param setAsFinal Whether to set the classes as final. If set as final,
		the classes will act as a final variable and cannot be changed in the script.
		@return this instance for chaining.
	**/
	public function setByPackage(_package:String, ?recursive:Bool = true, ?setAsFinal:Bool):SScript 
	{
		return this;
	}
	#end

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
			return removeSpecialObject();
		if (exclusions == null)
			exclusions = new Array();

		var types:Array<Dynamic> = [Int, String, Float, Bool, Array];
		for (i in types)
			if (Std.isOfType(obj, i)) {
				traceError('Special object cannot be ${i}', "setSpecialObject", [obj, includeFunctions, exclusions]);
				return this;
			}

		switch Type.typeof(obj) {
			case TEnum(e):
				traceError('Special object cannot be an enum constructor (${Type.getEnumName(e)})', "setSpecialObject", [obj, includeFunctions, exclusions]);
				return this;
			default:
		}

		if (interp.specialObject == null)
			interp.specialObject = {obj: null, includeFunctions: null, exclusions: null};

		interp.specialObject.obj = obj;
		interp.specialObject.exclusions = exclusions.copy();
		interp.specialObject.includeFunctions = includeFunctions;
		interp.generateSpecialObjectFields();
		return this;
	}

	/**
		Removes the special object that was assigned to this script.
		@return Returns this instance for chaining.
	**/
	public function removeSpecialObject():SScript
	{
		if (_destroyed)
			return null;
		if (!active)
			return this;
		
		interp.specialObject = null;
		interp.generateSpecialObjectFields();
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

		if (interp.locals.exists(key))
			interp.locals.remove(key);
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
				traceError("This script is not active!", "get");

			return null;
		}

		if (interp.locals.exists(key))
       		return interp.locals.get(key).r;

		var r = interp.variables.get(key);
		return r != null ? r.r : null;
	}

	/**
		Calls a function from this script.

		**WARNING**:
		The script must be executed at least once before calling functions.

		@param func Function name in script. 
		@param args Arguments for `func`. If the function does not require arguments, leave this as `null`.
		@param className This argument is unused and has no effect. It was added to add backwards compatibility for projects using very old SScript versions (**3.0.0**-**4.1.0**).
		@return Returns a `FunctionCall` object.
	**/
	public function call(func:String, ?args:Array<Dynamic> = null, ?className:String):FunctionCall
	{
		if (_destroyed)
			return {
				exceptions: [new Exception(toString() + " is destroyed.")],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};

		if (!active)
			return {
				exceptions: [new Exception(toString() + " is not active.")],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};

		var time:Float = Timer.stamp();

		var scriptFile:String = if (scriptFile != null && scriptFile.length > 0) scriptFile else "";

		if (args == null)
			args = new Array();

		if (func == null || func.trim().length == 0)
		{
			if (traces)
				traceError('Function name cannot be invalid', 'call', [func, args]);

			return {
				exceptions: [new Exception('Function name cannot be invalid' + ((scriptFile != null && scriptFile.length > 0) ? 'for $scriptFile!' : ''))],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};
		}

		var fun = get(func);
		var caller:UnlockedFunctionCall;
		if (fun != null && Type.typeof(fun) != TFunction)
		{
			if (traces)
				traceError('$func is not a function', 'call', [func, args]);

			caller = {
				exceptions: [new Exception('$func is not a function')],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};
		}
		else if (fun == null)
		{
			if (traces)
				traceError('Function $func does not exist', "call", [func, args]);

			caller = {
				exceptions: [new Exception('Function $func does not exist in ${toString()}.')],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};
		}
		else 
		{
			caller = {
				exceptions: [],
				calledFunction: func,
				succeeded: false,
				returnValue: null,
				lastReportedTime: -1
			};
			var oldCaller = caller;
			try
			{
				if (hscriptSandboxed && interp != null)
					interp.resetSandboxLimiter();

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

		for (i in [for (k in interp.locals.keys()) k])
			interp.locals.remove(i);

		for (i in [for (k in interp.variables.keys()) k])
			interp.variables.remove(i);

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
		if (interp.variables.exists(key))
			return true;

		return false;
	}

	/**
		Sets useful default variables to make this script easier to use.
		Override this function to set your custom values as well.

		Sandboxed scripts don't get preset values, but you can still override this and put in your own variables.

		Don't forget to call `super.preset()` (at the top of the overriden function)!
	**/
	public function preset():Void
	{
		if (_destroyed)
			return;
		if (!active)
			return;

		if (!hscriptSandboxed)
			Preset.preset(this);
	}

	function resetInterp():Void
	{
		if (_destroyed)
			return;

		interp.locals = new Map();
		while (interp.declared.length > 0)
			interp.declared.pop();

		interp.compiledExprFuncCache.clear();

		if (hscriptSandboxed)
			HScriptSandbox.apply(interp, hscriptBlockedLibs, hscriptExtraBlockedClasses, hscriptExtraAllowedClasses, hscriptInstructionLimit,
				hscriptTimeLimitMs);
		else
			HScriptSandbox.remove(interp);
	}

	function destroyInterp():Void 
	{
		if (_destroyed)
			return;

		interp.interpStringExprCache = null;
		interp.compiledExprFuncCache = null;
		interp.specialObject = null;
		interp.usingMethods = null;
		interp.script = null;
		interp.locals = null;
		interp.variables = null;
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
			return this;
		if (string == null || string.trim().length == 0)
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
				og = toString();

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
				{
					shouldWarn = false;
					call(defaultFunc.functionName, defaultFunc.arguments);
					shouldWarn = true;
				}
			}

			tryHaxe();	
			
			lastReportedTime = Timer.stamp() - time;
			debugTrace("doString()");
		}
		catch (e) lastReportedTime = -1;

		return this;
	}

	/**
		Converts this instance of SScript to a String and returns it.

		For scripts without a file, it will use its `ID`. (e.g, "`[SScript #618]`")

		For scripts with a file, it will use the file name. (e.g, "`[SScript (script.hx)]`")

		Sandboxed scripts will be labeled as "SScript Sandboxed". (e.g, "`[SScript Sandboxed #618]`")

		@return This SScript instance as a string.
	**/
	public inline function toString():String
	{
		if (_destroyed)
			return "null";

		var sandboxed = hscriptSandboxed;

		if (scriptFile != null && scriptFile.length > 0 && StringTools.trim(scriptFile).length > 0) 
			return (sandboxed ? "[SScript Sandboxed" : "[SScript") + " (" + scriptFile + ")]";

		return (sandboxed ? "[SScript Sandboxed" : "[SScript") + (ID != null ? (" #" + ID) : "") + "]";
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

		if (scriptFile != null && scriptFile.length > 0 && global.exists(scriptFile))
			global.remove(scriptFile);
		if (ID != null && global.exists(Std.string(ID)))
			global.remove(Std.string(ID));

		removeSpecialObject();
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

	public dynamic function traceError(error:String, funcCalled:String, ?args:Array<Dynamic>)
	{
		if (!shouldWarn)
			return;

		var buf = new StringBuf();
		buf.add(this.toString());
		buf.add(" ");
		buf.add(error);
		buf.add(", error message from function '");
		buf.add(funcCalled);
		buf.add("'");

		if (args != null && args.length > 0)
		{
			buf.add(", passed arguments are: ");
			buf.add(args.join(", "));
		}

		trace(buf.toString());
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

	static var showedWarning:Bool = false;
	static function set_defaultPreset(value:PresetMode):PresetMode {
		#if (!DISABLED_MACRO_SUPERLATIVE && !python)
		if (value == FULL && !showedWarning) {
			trace("You set preset mode to FULL, which contains all existing classes.");
			trace("If you're handling a lot of scripts, this can get very expensive.");
			trace("See REGULAR or MINI for alternatives.");

			showedWarning = true;
		}
		#end

		return defaultPreset = value;
	}

	function set_presetMode(value:PresetMode):PresetMode {
		if (_destroyed)
			return null;
		return presetMode = value;
	}

	function set_interpCompilesFunctionCode(value:Bool):Bool {
		if (_destroyed)
			return false;
		if (interp == null)
			return value;
		interp.compiled = value;
		return interpCompilesFunctionCode = value;
	}

	#if cpp
	function set_interpCachesCompiledLocals(value:Bool):Bool {
		if (_destroyed)
			return false;
		if (interp != null)
			interp.cppLocalCacheEnabled = value;
		return interpCachesCompiledLocals = value;
	}
	#end
}