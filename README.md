[![](https://thomasdarkson.com/assets/stickers/sticker.png)](https://thomasdarkson.com)
[![](logo.png)](https://thomasdarkson.com)

# SScript

SuperlativeScript is a fork of HScript with fixes and improvements.

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

#### Note
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
			trace(FileSystem); // Class<sys.FileSystem>
		");
	}
}
```

SScript uses a macro for wildcard imports. In most cases, it works fine. However, if you want to disable this feature, you can define `DISABLED_MACRO_SUPERLATIVE` in your project. This is not recommended, however, as doing so will also make the `FULL` preset mode unavailable.

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
            trace(L, G); // Class<sys.FileSystem>,Class<sys.io.File>
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

			trace(1.triple()); // 3
			trace(.1.triple()); // 0.30000000000000004
			/*
				SScript doesn't check types in extension methods,
				so 'triple' returns a Float even though it should return an Int.
				Use it with caution.
			*/

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

var script:SScript = new SScript(); // Create a new SScript class
script.doString("
	var x = 12;
	trace('The value of x is $x'); // The value of x is 12

	trace('The value of x is ${x + 2}'); // The value of x is 14
"); 
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
			trace(matches); // [row,row,row]
			trace(matches.length); // 3

			// Email addresses regular expression
			// (In files, use one back slash instead)
			var emailReg = ~/[A-Z0-9._%-]+@[A-Z0-9.-]+\\.[A-Z][A-Z][A-Z]*/i;
			trace(emailReg.match("superlative@email.com")); // true
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

## Improved Field System
With SScript, you can access (excluding unused) classes or enums with their full name like Haxe.
Example:
```haxe
import hscript.SScript;
class Main {
	static function main()
	{
		var script = new SScript();
		script.doString("
			trace(haxe.Timer.stamp());
		");
	}
}
```

This makes `import` optional and it is useful for one-time use of a class or enum.
This feature may be exhausting for weak machines and is disabled by default, so if you wish to enable it set `hscript.SScript.defaultImprovedField` to `true`.

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

			trace(add()); // Exception: Not enough arguments, expected a:Int
			trace(add(0)); // 1 
			trace(add(0, 2)); // 2
		");
	}
}
```

## Presetting System
Presets are the variables that get set before the script gets executed. 

SScript has a presetting system that allows you to configure multiple preset modes.

Currently, it includes 4 modes: `NONE`, `MINI`, `REGULAR`, and `FULL`.

- `MINI` contains only basic classes and is extremely lightweight.
- `REGULAR` includes more commonly used classes.
- `FULL` includes all available classes and can be expensive when handling many scripts. (Available only if `DISABLED_MACRO_SUPERLATIVE` is not defined)

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

## Using Haxe 4.3.0 Syntaxes
SuperlativeScript supports both `?.` and `??` syntaxes including `??=`.

```haxe
import hscript.SScript;
class Main 
{
	static function main()
	{
		var script:SScript = new SScript();
		script.doString("
			var string:String = null;
			trace(string.length); // Throws an error
			trace(string?.length); // Doesn't throw an error and returns null
			trace(string ?? 'ss'); // Returns 'ss';
			trace(string ??= 'ss'); // Returns 'ss' and assigns it to `string` variable
		");
	}
}
```

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
				var num = null;
				return num + 1;
			}
		');

		var call = script.call('method');
		trace(call.returnValue, call.exceptions[0]); // null, Invalid operation: null + 1
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
		var script:SScript = new SScript();
		script.set('variable', 1);
		script.doString('
			function returnVar()
			{
				return variable + variable2;
			}
		');

		SScript.globalVariables.set('variable2', 2);
		trace(script.call('returnVar').returnValue); // 3
	}
}
```

Variables from `globalVariables` can be changed in script but the value in `SScript.globalVariables` won't be affected.
If you do not want this, add `-final` at the end of the variable name. They will act as a final and cannot be changed in script.

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

		trace(script.parsingException); // This expression cannot be accessed for writing
	}
}
```

## Special Object
Special object is an object that'll get checked if a variable is not found in a script.
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

Special objects can also be Classes and Enums.

```haxe
import hscript.SScript;

class Main 
{
	static function main()
	{
		var script:SScript = new SScript();
		script.setSpecialObject(SpecialObject);
		script.doString("
			call(); //You called me!
		");

		var script:SScript = new SScript();
		script.setSpecialObject(Special);
		script.doString("
			trace(AA(1)); //SScript:2: AA(1)
			trace(BB); //SScript:3: BB
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