[![](https://thomasdarkson.com/assets/stickers/sticker.png)](https://thomasdarkson.com)
[<img src="https://thomasdarkson.com/sscript/logo.png" style="width:40%; height:auto;">](https://thomasdarkson.com)

# SScript

SScript (also known as SuperlativeScript) is a fork of HScript with fixes and improvements.

> [!NOTE]
> SScript is a **C++ first** library. All testing and compiling is done on Haxe's C++ target. Other targets may work, but they are untested, and bugs exclusive to another target are not guaranteed to get fixes.

## Installation
`haxelib install SScript`

Enter this command in the command prompt to get the latest release from the Haxe library.

After installing SScript, don't forget to add it to your Haxe project.

------------

### OpenFL projects
Add this to `Project.xml` to add SScript to your OpenFL project:
```xml
<haxelib name="SScript"/>
```
### Haxe Projects
Add this to `build.hxml` to add SScript to your Haxe build.
```hxml
-lib SScript
```

> [!NOTE]
Haxe definition `hscriptPos` is deprecated and shouldn't be used unless you also want to use vanilla HScript.

## Usage
To use SScript, you will need either a file or a script. Using a file is recommended.

### Using without a file
```haxe
import hscript.SScript;

class Main {
	static function main() {
		var script:SScript = new SScript(); // Create a new SScript class
		script.doString("
			function returnRandom():Float
				return Math.random() * 100;
		"); // Implement the script
		var call = script.call('returnRandom');
		var randomNumber:Float = call.returnValue; // Access the returned value with returnValue
	}
}
```

### Using with a file
```haxe
import hscript.SScript;

class Main {
	static function main() {
		var script:SScript = new SScript("script.hx"); // Contains the same code as the script above
		var randomNumber:Float = script.call('returnRandom').returnValue;
	}
}
```

### New features

#### Import

SScript supports normal imports, wildcard imports and imports with aliases.

```haxe
import hscript.SScript;

class Main {
	static function main() {
		var script:SScript = new SScript();
		script.doString("
			import Date;
			trace(Date.now()); 
		");
	}
}
```

##### Wildcard Imports
```haxe
import hscript.SScript;

class Main {
	static function main() {
		var script:SScript = new SScript();
		script.doString("
			import sys.*;
			trace(FileSystem); // [SScript #1]:3: Class<sys.FileSystem>
		");
	}
}
```

SScript uses a macro for wildcard imports. In most cases, it works fine. However, if you want to disable this feature, you can define `DISABLED_MACRO_SUPERLATIVE` in your project. This is not recommended, as doing so will also make the `FULL` preset mode unavailable.

##### Import with Alias
```haxe
import hscript.SScript;

class Main 
{
	static function main()
	{
		var script:SScript = new SScript();
		script.doString("
            import sys.FileSystem in L;
            import sys.io.File as G;
            trace(L, G); // [SScript #1]:4: sys.FileSystem,sys.io.File
		");
	}
}
```

#### Static Extensions
SScript supports Static Extensions with the `using` keyword.

```haxe
import hscript.SScript;

class Main 
{
	static function main()
	{
		var script:SScript = new SScript();
		script.setClass(IntExtender);
		script.doString("
			using IntExtender;
			using StringTools;

			trace(1.triple()); // [SScript #1]:5: 3
			trace(.1.triple()); // [SScript #1]:6: 0
			/**
				SScript doesn't check types in extension methods.
				In C++, Haxe managed to downcast the float to an integer.
				It may not successfully downcast every variable, however.
			**/

			var str = 'str-end';
			trace(str.startsWith('str'), str.endsWith('-end')); // true,true
		");
	}
}

class IntExtender {
	static public function triple(i:Int):Int {
		return i * 3;
	}
}
```

As explained above, SScript doesn’t check types. It also doesn’t verify if the correct number of arguments is used; therefore, if an incorrect number of arguments is provided (such as passing two arguments to `endsWith` like `str.endsWith(str, "-end")`), Haxe will throw a vague `Something went wrong` error.

#### String Interpolation
SScript supports string interpolation. Just like in Haxe, special identifiers denoted by the dollar sign `$` within a string (enclosed by single quotes `'`) are evaluated as expressions.

```haxe
import hscript.SScript;

class Main {
	static function main()
	{
		var script:SScript = new SScript(); // Create a new SScript class
		script.doString("
			var money = 12;

			trace('Wallet: $money'); // [SScript #1]:4: Wallet: 12
			trace('Wallet 2: ${money + 2}'); // [SScript #1]:5: Wallet 2: 14
		");
	}
}
```

#### Regular Expressions
SScript has support for regular expressions. 

Example:
```haxe
import hscript.SScript;

class Main {
	static function main()
	{
		var script = new SScript();
		script.doString('
			function getMatches(ereg:EReg, input:String, index:Int = 0):Array<String> 
			{
				var matches = [];
				while (ereg.match(input)) {
					matches.push(ereg.matched(index)); 
					input = ereg.matchedRight();
				}
				return matches;
			}

			var message = "row row row your boat";
			var matches = getMatches(~/(row)/, message);
			trace(matches); // [SScript #1]:14: [row,row,row]
			trace(matches.length); // [SScript #1]:15: 3

			// Email addresses regular expression
			// (In files, use one back slash instead)
			var emailReg = ~/[A-Z0-9._%-]+@[A-Z0-9.-]+\\.[A-Z][A-Z][A-Z]*/i;
			trace(emailReg.match("superlative@email.com")); // [SScript #1]:20: true
		');
	}
}
```

You can still create regular expressions using the standard syntax:
```haxe
var r = new EReg("haxe", "i");
```

##### Limitations
With faulty EReg instances, Haxe may produce corrupted error messages. These errors cannot be caught and may crash the session.

Sometimes, Haxe may not display error messages. If this happens, the session may enter a loop and become unresponsive.

Platform limitations also apply here, the flag `u` is only available in C++ and Neko.
Flag `s` is not available in C# and JavaScript.

## HScript Sandboxing
Set `hscriptSandboxed = true` to restrict what an HScript script can reach.

```haxe
import hscript.SScript;
import hscript.backend.HScriptSandbox.HScriptLib;

class Main {
	static function main() {
		var script = new SScript();
		script.hscriptSandboxed = true; // Blocked classes are HScriptLib.SANDBOX_DEFAULT (all categories)
		
		script.doString("sys.io.File.saveContent('script.hx', 'var a = 1;');"); // fails: sys.io.File is blocked
		trace(script.parsingException);
	}
}
```

A script can reach almost anything in scope just by naming it (`new sys.io.File(...)`, `Sys.systemName()`, `import sys.FileSystem;`, `sys.io.File.getContent(path)`, `using SomeClass;`). `hscriptSandboxed` blocks that implicit, by-string resolution, grouped into categories:

| `HScriptLib` flag | Blocks |
|---|---|
| `SYS` | `Sys` and any other `sys.*` not covered below |
| `FILESYSTEM` | `sys.io.File`, `sys.FileSystem`, `sys.io.Path` etc. |
| `PROCESS` | `sys.io.Process` |
| `NETWORK` | `sys.net.*`, `haxe.Http` |
| `THREADING` | `sys.thread.*` |
| `NATIVE_TARGET` | `cpp.*`, `cs.*`, `java.*`, `js.*`, `php.*`, `python.*`, `neko.*`, `lua.*`, `hl.*`, `flash.*` |
| `INTERPRETER` | `hscript.*`, `hscriptBase.*` |
| `REFLECTION` | `Reflect` |
| `TYPE` | `Type` |

There are extra categories, just for convenience.

| `HScriptLib` flag | Blocks |
|---|---|
| `ALL` | Blocks everything, basically all flags in one |
| `SANDBOX_DEFAULT` | The same as `ALL`, default if sandboxed but `blockedLibs` is ommited |
| `TRUSTED` | Blocks everything except `REFLECTION` |
| `SYS_ONLY` | `SYS`, `FILESYSTEM`, `PROCESS`, `THREADING`, `NATIVE_TARGET`, `INTERPRETER` and `TYPE` |

## Sandbox Settings & Configuration

You can configure sandboxing using five instance properties on `SScript`, or configure them all at once using an `HScriptSandboxSettings` structure:

* **`blockedLibs` (`hscriptBlockedLibs` in `HScriptSandboxSettings`):** A bitmask of `HScriptLib` flags controlling which category groups are restricted. Defaults to `HScriptLib.SANDBOX_DEFAULT` (blocks every category above). Alternatively, set `HScriptLib.TRUSTED` to block everything except `REFLECTION` for scripts you mostly trust but still want walled off from system, network, and native APIs.
* **`extraAllowedClasses` (`hscriptExtraAllowedClasses` in `HScriptSandboxSettings`):** An array of dotted class paths or package prefixes to explicitly permit, overriding `blockedLibs` restrictions (e.g., `["sys.io.File"]`).
* **`extraBlockedClasses` (`hscriptExtraBlockedClasses` in `HScriptSandboxSettings`):** An array of dotted class paths or package prefixes to explicitly block, regardless of whether they fall under an `HScriptLib` category (e.g., `["my.pkg.Secrets"]`).
* **`instructionLimit` (`hscriptInstructionLimit` in `HScriptSandboxSettings`):** An evaluation budget specifying the maximum number of expressions/instructions the script may execute. Set to `0` or `-1` to disable (defaults to `-1`).
* **`timeLimitMs` (`hscriptTimeLimitMs`):** A wall-clock timeout in milliseconds. Set to `0` or `-1` to disable (defaults to `-1`).

Passing an `HScriptSandboxSettings` object to the `SScript` constructor automatically enables `hscriptSandboxed = true`, even if you pass an empty structure (`{}`). Omitted fields retain their default values.

```haxe
import hscript.SScript;
import hscript.backend.HScriptSandbox;

class Main {
	public static function main() {
		var script = new SScript("trace(Reflect.fields({field: 1}), sys.FileSystem.exists('script.hx')); // [SScript Sandboxed #1]:1: [field],false", true, true, { 
			blockedLibs: HScriptLib.TRUSTED, // Block all except Reflection
			instructionLimit: 1000000, // Allow 1 million expressions
			timeLimitMs: 2000, // Allow only 2 seconds for the script to hang before killing it
			extraAllowedClasses: ["sys.FileSystem"]
		});

		var script = new SScript('
			import sys.io.Process;

		    var process = new Process("haxe", ["--version"]);
			var output = process.stdout.readAll().toString();
			var exitCode = process.exitCode(); 
			trace("Output: " + output); // [SScript Sandboxed #2]:7: Output: 4.3.7
			trace("Exit Code: " + exitCode); // [SScript Sandboxed #2]:8: Exit Code: 0
			process.close(); 
		', true, true, {
			blockedLibs: HScriptLib.NATIVE_TARGET | hscript.backend.HScriptSandbox.HScriptLib.FILESYSTEM, // Block only native API and File System
		});

		var script = new SScript("trace(Sys.systemName()); // [SScript Sandboxed #3]:1: Windows", true, true, {
			blockedLibs: HScriptLib.ALL & ~HScriptLib.SYS, // Block all except Sys
		});

		var script = new SScript("
			import haxe.Http;
			import haxe.Json;

			var f = Http.requestUrl('https://raw.githubusercontent.com/ThomasDarkson/SScript/refs/heads/main/haxelib.json');
			var json = Json.parse(f);

			trace(Reflect.field(json, 'license')); // [SScript Sandboxed #4]:8: Apache
		", true, true, {
			blockedLibs: HScriptLib.ALL & ~hscript.backend.HScriptSandbox.HScriptLib.NETWORK & ~hscript.backend.HScriptSandbox.HScriptLib.REFLECTION, // Block all except Network and Reflection
		});
	}
}
```

Leave any of those fields out (or pass them as null) to keep that setting's own default.

**This is not a hard, OS-level security boundary.** It restricts *implicit* class resolution by string; it does nothing to limit whatever you set into the script yourself, those are reachable from a sandboxed script exactly as they are from a normal one.

## Improved Field System
With SScript, you can access (excluding unused) classes or enums with their full name like Haxe.
Example:
```haxe
import hscript.SScript;
class Main {
	static function main()
	{
		SScript.defaultImprovedField = true;
		var script = new SScript();
		script.doString("
			trace(haxe.Timer.stamp());
		");
	}
}
```

This makes `import` optional and it is useful for one-time use of a class or enum.
This feature may be exhausting for weak machines, so if you wish to disable it set `hscript.SScript.defaultImprovedField` to `false`.

## Reworked Function Arguments
Function arguments have been reworked, so optional arguments will work like native Haxe.

Example:
```haxe
import hscript.SScript;

class Main {
	static function main()
	{
		var script = new SScript();
		script.doString("
			function add(a:Int, ?b:Int = 1) 
			{
				return a + b;
			}

			// trace(add()); // [SScript #1]:2: Not enough arguments, expected a:Int
			trace(add(0)); // [SScript #1]:8: 1
			trace(add(0, 2)); // [SScript #1]:9: 2
		");
	}
}
```

## Compiled Functions
Script functions can be compiled into cached closures instead of being re-interpreted on every call, via `interpCompilesFunctionCode` (set `SScript.defaultCompile` to change the default for every instance created afterwards).

When enabled, a function's body is compiled the first time that function is called, then the compiled closure is reused for every call to that same function. This trades a one-time, per-function build cost for a cheaper path on every call afterwards, so it only pays off once a function is called often enough (e.g. hundreds/thousands of times, or once per frame). For a function called once or twice, leaving it disabled is slightly faster since it skips the compilation step entirely. It only affects functions with names; scripts without functions, or functions without a name, are unaffected.

This is enabled by default because, if you're not calling functions repeatedly anyway, the compilation cost is tiny (a few milliseconds at most) and generally won't matter. However, if those milliseconds do matter to you, you can disable it either by setting `SScript.defaultCompile` to `false` or by setting `interpCompilesFunctionCode` to `false` on every instance.

Example:
```haxe
import hscript.SScript;
import haxe.Timer;

class Main {
	static function main() {
		final CALLS = 20000;
		final LOOP_N = 50;

		var code = "
			function compute(n) {
				var total = 0;
				var i = 0;
				while (i < n) {
					total += i * 2 + 1;
					i += 1;
				}
				return total;
			}
		";

		var interpreted = new SScript();
		interpreted.interpCompilesFunctionCode = false;
		interpreted.doString(code);

		var compiled = new SScript();
		compiled.interpCompilesFunctionCode = true;
		compiled.doString(code);

		// Warm up
		interpreted.call("compute", [LOOP_N]);
		compiled.call("compute", [LOOP_N]);

		var startInterp = Timer.stamp();
		for (i in 0...CALLS) interpreted.call("compute", [LOOP_N]);
		var interpElapsed = Timer.stamp() - startInterp;

		var startCompiled = Timer.stamp();
		for (i in 0...CALLS) compiled.call("compute", [LOOP_N]);
		var compiledElapsed = Timer.stamp() - startCompiled;

        // Below are real numbers (with 9800X3D CPU, C++ target)
		trace('Interpreted: ${interpElapsed}s for $CALLS calls'); // Interpreted: 0.3307451s for 20000 calls
		trace('Compiled:    ${compiledElapsed}s for $CALLS calls'); // Compiled:    0.1875383s for 20000 calls
		trace('Speedup: ${interpElapsed / compiledElapsed}x'); // Speedup: 1.76361361919139x
	}
}
```

## Cached Compiled Locals (C++ only)
On the C++ target, compiled functions can cache locals variables instead of looking them up on every access, with
`interpCachesCompiledLocals` (defaults to `true`). The cache changes automatically
whenever the active local variable actually changes, so this is safe to leave on. It has no effect if compiled functions are disabled, and **this feature is available on C++ only.**

```haxe
var script = new SScript();
#if cpp
script.interpCachesCompiledLocals = false;
#end
```

## Presetting System
Presets are the variables that get set before the script gets executed. 

SScript has a presetting system that allows you to configure multiple preset modes.

Currently, it includes 4 modes: `NONE`, `MINI`, `REGULAR`, and `FULL`.

- `MINI`: Date, DateTools, EReg, Math, Reflect, Std, StringTools, Type, Sys, sys.io.File, sys.FileSystem
- `REGULAR`: All classes from `MINI` and List, StringBuf, Xml, haxe.Http, haxe.Json, haxe.Log, haxe.Serializer, haxe.Unserializer, haxe.Timer, haxe.SysTools, sys.io.Process, sys.io.FileInput, sys.io.FileOutput
- `FULL` includes all available classes in compile time and can be expensive when handling many scripts. (Available only if `DISABLED_MACRO_SUPERLATIVE` is not defined)

Example:
```haxe
import hscript.backend.Preset;
import hscript.SScript;

class Main {
	static function main() {
		SScript.defaultPreset = PresetMode.FULL;
		var script = new SScript("trace(Json); // haxe.Json class is included with REGULAR and FULL");
	}
}
```

Sandboxed scripts can use `preset`, but none of the modes above set anything unless you override `preset` with your own values.

### Setting Variables Manually
You can also set variables manually with `set`, `setClass`, `setClassString`, `setEnum` and `setByPackage` (not available if `DISABLED_MACRO_SUPERLATIVE` is defined).

`set()` and all the other methods reject language keywords as variable names (`var`, `function`, `class`, `true`, `false`, etc.).

`setEnum` has a parameter called `includeAllEnumConstructors`. If set to `true`, it adds all constructors from the provided enum to the script.

Example:
```haxe
import Type.ValueType;
import hscript.SScript;

class Main {
    static function main() {
        var script = new SScript();
        script.set("Json", haxe.Json);
        script.setClass(haxe.Serializer);
        script.setClassString("haxe.ds.ArraySort");
        script.setByPackage("sys", false); // Do NOT include sub-packages
        script.setEnum(ValueType, true); // Include all constructors in this Enum
        script.setEnum(VariableEnum, true, false); // Include only the Enum
        script.doString("
            trace(Json); // [SScript #1]:2: Class<haxe.Json>
            trace(Serializer); // [SScript #1]:3: Class<haxe.Serializer>
            trace(ArraySort); // [SScript #1]:4: Class<haxe.ds.ArraySort>
            trace(FileSystem); // [SScript #1]:5: Class<sys.FileSystem>
            trace(TInt); // [SScript #1]:6: TInt
            trace(VariableEnum.A, VariableEnum.B, VariableEnum.C); // [SScript #1]:7: A,B,C

            try {
                trace(S);
            }
            catch(e) {
                trace('Did not include sys.io package'); // [SScript #1]:13: Did not include sys.io package
            }

            try {
                trace(A, B, C);
            }
            catch(e) {
                trace('Did not include constructors'); // [SScript #1]:20: Did not include constructors
            }
        ");
    }
}

enum VariableEnum {
    A;
    B;
    C;
}
```

#### Setting variables at construction
The constructor accepts `variablesToSet`, applied before `preset` regardless of whether
`preset` is enabled:

```haxe
var script = new SScript("trace(a + b); // [SScript #1]:1: 2", true, true, [
    { name: "a", variable: 1 },
    { name: "b", variable: 2, isFinal: true }
]);
```

## Using Haxe 4.3.0 Syntaxes
SuperlativeScript supports both `?.` and `??` syntaxes including `??=`. The result of any of these can be chained with further operations, e.g. field access or another call.

```haxe
import hscript.SScript;
class Main 
{
	static function main()
	{
		var script:SScript = new SScript();
		script.doString("
			var string:String = null;
			try {
				trace(string.length);
			}
			catch(e) {
				trace(e); // [SScript #1]:7: [SScript #1]:4: Invalid access to field length
			}

			trace(string?.length); // [SScript #1]:10: null
			trace(string ?? 'ss'); // [SScript #1]:11: ss
			trace(string ??= 'fall'); // [SScript #1]:12: fall
			trace((string ?? 'fallback').length); // [SScript #1]:13: 4
		");
	}
}
```

## Multi-Catch and Typed Catch Clauses
A `try` can now have more than one `catch`, each optionally typed. Clauses are checked in order and the first one whose type matches the thrown value runs; an untyped `catch(e)` matches anything, so put it last as a catch-all.

```haxe
import hscript.SScript;
class Main
{
	static function main()
	{
		var script:SScript = new SScript();
		script.doString("
			try
			{
				throw 'oops';
			}
			catch(e:Int) { trace('int: ' + e); }
			catch(e:String) { trace('string: ' + e); } // [SScript #1]:7: string: oops
			catch(e) { trace('anything else: ' + e); }
		");
	}
}
```

## Enum Pattern Matching in Switch
`switch` supports matching against an enum constructor and binding its arguments as new locals, instead of only comparing the whole value.

```haxe
import hscript.SScript;
class Main
{
	static function main()
	{
		var script:SScript = new SScript();
		script.set("shape", Circle(5));
		script.doString("
			switch(shape)
			{
				case Circle(r): trace('circle with radius ' + r); // [SScript #1]:4: circle with radius 5
				case Square(s): trace('square with side ' + s);
				case _: trace('unknown shape');
			}
		");
	}
}
```

## `cast` and `untyped`
Both are supported.

`cast expr` has no effect. `cast(expr, Type)` is a checked cast: basic types (`Int`, `Float`, `Bool`, `String`, `Array`) are verified, a known class or enum goes through a downcast check, and a mismatch will throw a catchable exception. Casting `null` always succeeds.

```haxe
import hscript.SScript;
class Main
{
	static function main()
	{
		var script:SScript = new SScript();
		script.doString("
			var a = 5;
			trace(cast a); // [SScript #1]:3: 5

			var b = 3.7;
			trace(cast(b, Int)); // [SScript #1]:6: 3

			try {
				var c = 'not a number';
				cast(c, Int);
			} catch (e) {
				trace('bad cast: ' + e); // [SScript #1]:12: bad cast: [SScript #1]:10: Cannot cast String to Int
			}
		");
	}
}
```

`untyped expr` is a no-op, having no effect whatsoever. It's here so it could be parsed.

## Extending SScript
You can create a class extending SScript to customize it better.
```haxe
class SScriptEx extends hscript.SScript
{  
	override function preset():Void
	{
		super.preset();
		
		// Only use 'set', 'setClass' or 'setClassString' in preset
		// Macro classes are not allowed to be set
		setClass(StringTools);
		set('NaN', Math.NaN);
		setClassString('sys.io.File');
	}
}
```
Extend other functions only if you know what you're doing.

## Calling Methods from scripts
You can call methods and receive their return value from scripts using `call` function.
It needs one obligatory argument (function name) and one optional argument (function arguments array).

Using `call` will return a structure that contains the return value, if calling has been successful, exceptions if it did not, called function name and script file name of the script.

Example:
```haxe
import hscript.SScript;
class Main 
{
	static function main() {
		var script:SScript = new SScript();
		script.doString('
			function method()
			{
				return 2 + 2;
			}
		');
		var call = script.call('method');
		trace(call.returnValue); // 4

		script.doString('
			function method()
			{
				var field = null;
				return field.a;
			}
		');

		var call = script.call('method');
		trace(call.returnValue, call.exceptions[0]); // null,[SScript #1]:5: Invalid access to field a
	}
}
```

## Global Variables
With SScript, you can set variables to all existing scripts.
Example:

```haxe
import hscript.SScript;
class Main 
{
	static function main() {
		SScript.globalVariables.set('variable2', 2);
		var script:SScript = new SScript();
		script.set('variable', 1);
		script.doString('
			function returnVar()
			{
				return variable + variable2;
			}
		');

		trace(script.call('returnVar').returnValue); // 3
	}
}
```

Variables from `globalVariables` can be changed in script but the value in `SScript.globalVariables` won't be affected.
If you do not want this, add `-final` at the end of the variable name. They will act as finals and cannot be changed in script.

```haxe
import hscript.SScript;
class Main 
{
	static function main() {
		SScript.globalVariables.set('variable2-final', 2);
		
		var script:SScript = new SScript();
		script.doString('
			variable2 = 0;
		');

		trace(script.parsingException); // [SScript #1]:2: This expression cannot be accessed for writing
	}
}
```

## Special Object
A Special object is an object that'll get checked if a variable is not found in a script.
A special object cannot be a basic type like Int, Float, String, Array and Bool.

Special objects are especially useful for OpenFL and Flixel states.

Example:
```haxe
import flixel.FlxG;
import hscript.SScript;

class PlayState extends flixel.FlxState 
{
	var sprite:flixel.FlxSprite;
	override function create()
	{
		sprite = new flixel.FlxSprite();
		sprite.makeGraphic(FlxG.width, FlxG.height, FlxColor.WHITE);
		add(sprite);

		var newScript:SScript = new SScript();
		newScript.setSpecialObject(this);
		newScript.doString("sprite.visible = false;");

		super.create();
	}
}
```

Special objects can also be Classes, Enums and anonymous structures.

```haxe
import hscript.SScript;

class Main 
{
	static function main()
	{
		var script:SScript = new SScript();
		script.setSpecialObject(SpecialObject);
		script.doString("
			call(); // Main.hx:32: You called me!
		");
	    
		var script:SScript = new SScript();
		script.setSpecialObject(Special);
		script.doString("
			trace(AA(1)); // [SScript #2]:2: AA(1)
			trace(BB); // [SScript #2]:3: BB
		");

        var script:SScript = new SScript();
		script.setSpecialObject({a: 1, b: "https://thomasdarkson.com", c: [.1, .222]});
		script.doString("
			trace(a); // [SScript #3]:2: 1
            trace(b); // [SScript #3]:3: https://thomasdarkson.com
            trace(c); // [SScript #3]:4: [0.1,0.222]
		");
	}
}

class SpecialObject {
	static function call() {
		trace("You called me!");
	}
}

enum Special {
	AA(r:Int);
	BB;
}
```