package hscript.backend;

import hscriptBase.Interp;

using StringTools;

/**
	Bitmask flags for categories of native class access purely by dotted string path
	that `HScriptSandbox` can block, e.g. `new sys.io.File(...)`, `Sys.systemName()`,
	`import sys.FileSystem;`, `sys.io.File.getContent(path)`, `using SomeClass;`.

	This is **not** an OS-level sandbox. It restricts what a script can reach by
	naming a class that was never explicitly given to it, it has no effect on
	anything you `set()`/`setClass()` into the script yourself.

	@see `hscript.backend.HScriptSandbox`
**/
class HScriptLib
{
	/**
		`Sys` and anything else directly under the `sys` package that isn't covered
		by a more specific category below (`sys.db.*`, `sys.*` etc.).
	**/
	public static inline final SYS:Int = 1 << 0;

	/**
		`sys.io.File`, `sys.io.FileInput`, `sys.io.FileOutput`, `sys.FileSystem`,
		`sys.io.Path`. Anything that reads, writes, lists or deletes files.
	**/
	public static inline final FILESYSTEM:Int = 1 << 1;

	/**
		`sys.io.Process`. Spawning or talking to a child process.
	**/
	public static inline final PROCESS:Int = 1 << 2;

	/**
		`sys.net.*` and `haxe.Http`, anything that can make
		a network connection.
	**/
	public static inline final NETWORK:Int = 1 << 3;

	/**
		`sys.thread.*`. Spawning threads, mutexes, locks, deques.
	**/
	public static inline final THREADING:Int = 1 << 4;

	/**
		Anything under a target specific package (`cpp.*`, `cs.*`, `java.*`,
		`js.*`, `php.*`, `python.*`, `neko.*`, `lua.*`, `hl.*`, `flash.*`). These
		commonly expose raw pointers, FFI, or platform APIs well outside anything
		a script should touch.
	**/
	public static inline final NATIVE_TARGET:Int = 1 << 5;

	/**
		`hscript.*`/`hscriptBase.*`. Stops a script from reaching back into the interpreter,
		other `SScript` instances, or the sandbox machinery itself.
	**/
	public static inline final INTERPRETER:Int = 1 << 6;

	/**
		`Reflect`. This is only reachable as an identifier, so it is already unreachable unless something
		else explicitly `set()`'d it in. This flag exists mainly so `import Reflect;` can be blocked too when that's the case.
	**/
	public static inline final REFLECTION:Int = 1 << 7;

	/**
		Same as `REFLECTION` but it blocks `Type` instead.
	**/
	public static inline final TYPE:Int = 1 << 8;

	/**
		Every category above.
	**/
	public static inline final ALL:Int = SYS | FILESYSTEM | PROCESS | NETWORK | THREADING | NATIVE_TARGET | INTERPRETER | REFLECTION | TYPE;

	/**
		"Safe by default" set for untrusted scripts: every category is blocked. A
		script sandboxed with this can still call
		methods and use anything explicitly set into it. 
		
		It just can't name its way to the filesystem, a process, the network, a
		native-target API, or the interpreter itself.
	**/
	public static inline final SANDBOX_DEFAULT:Int = ALL;

	/**
		Everything blocked except `REFLECTION`. Meant for scripts you mostly trust but still
		want walled off from the filesystem/network/process/etc.
	**/
	public static inline final TRUSTED:Int = ALL & ~REFLECTION;

	/**
		`SYS`, `FILESYSTEM`, `PROCESS`, `THREADING` and `TYPE`.

		`TYPE` is included so a script can't use `Type.resolveClass` and `Type.resolveEnum` with Reflection
		to access the their methods.
	**/
	public static inline final SYS_ONLY:Int = SYS | FILESYSTEM | PROCESS | THREADING | NATIVE_TARGET | INTERPRETER | TYPE;
}

/**
	Everything needed to sandbox an HScript script. All fields are
	optional; a field left out keeps that setting's own default (see
	`SScript.hscriptBlockedLibs`/`hscriptExtraBlockedClasses`/
	`hscriptExtraAllowedClasses`/`hscriptInstructionLimit`/`hscriptTimeLimitMs`).

	Passing an `HScriptSandboxSettings` value at all (even `{}`) will turn
	`hscriptSandboxed` on; there's no separate `enabled` field.
**/
typedef HScriptSandboxSettings = {
	/**
		Bitmask of `HScriptLib` flags. Defaults to `hscriptBlockedLibs`'s
		own default (`HScriptLib.SANDBOX_DEFAULT`) when omitted.
	**/
	public var ?blockedLibs:Int;

	/**
		Additional dotted class paths (or package prefixes) to block
		regardless of `blockedLibs`. Defaults to `hscriptExtraBlockedClasses`'s
		own default (`null`) when omitted.
	**/
	public var ?extraBlockedClasses:Array<String>;

	/**
		Dotted class paths (or package prefixes) to always allow, even if
		their category is blocked by `blockedLibs`. Defaults to
		`hscriptExtraAllowedClasses`'s own default (`null`) when omitted.
	**/
	public var ?extraAllowedClasses:Array<String>;

	/**
		Expression-evaluation budget. Defaults to
		`hscriptInstructionLimit`'s (`-1`) own default when omitted.
	**/
	public var ?instructionLimit:Int;

	/**
		Wall-clock budget in milliseconds. Defaults to
		`hscriptTimeLimitMs`'s (`-1`) own default when omitted.
	**/
	public var ?timeLimitMs:Int;
}

class HScriptSandbox
{
	public static function apply(interp:Interp, blockedLibs:Int, ?extraBlockedClasses:Array<String>, ?extraAllowedClasses:Array<String>,
			instructionLimit:Int = 0, timeLimitMs:Int = 0):Void
	{
		if (interp == null)
			return;

		@:privateAccess
		{
			interp.sandboxed = true;
			interp.sandboxBlockedLibs = blockedLibs;
			interp.sandboxExtraBlockedClasses = extraBlockedClasses;
			interp.sandboxExtraAllowedClasses = extraAllowedClasses;
			interp.sandboxInstructionLimit = instructionLimit;
			interp.sandboxTimeLimitMs = timeLimitMs;
			interp.resetSandboxLimiter();
		}
	}

	public static function remove(interp:Interp):Void
	{
		if (interp == null)
			return;

		@:privateAccess
		{
			interp.sandboxed = false;
			interp.sandboxBlockedLibs = 0;
			interp.sandboxExtraBlockedClasses = null;
			interp.sandboxExtraAllowedClasses = null;
			interp.sandboxInstructionLimit = 0;
			interp.sandboxTimeLimitMs = 0;
		}
	}

	public static function isAllowed(path:String, blockedLibs:Int, ?extraBlockedClasses:Array<String>, ?extraAllowedClasses:Array<String>):Bool
	{
		if (path == null || path.length == 0)
			return true;

		if (extraAllowedClasses != null)
			for (pre in extraAllowedClasses)
				if (matches(path, pre))
					return true;

		if (extraBlockedClasses != null)
			for (pre in extraBlockedClasses)
				if (matches(path, pre))
					return false;

		var cat = categoryOf(path);
		if (cat != 0 && blockedLibs & cat != 0)
			return false;

		return true;
	}

	static inline function matches(path:String, prefix:String):Bool
	{
		return path == prefix || path.startsWith(prefix + ".");
	}

	static function categoryOf(path:String):Int
	{
		if (path == "Reflect")
			return HScriptLib.REFLECTION;
		
		if (path == "Type")
			return HScriptLib.TYPE;

		if (path == "haxe.Http" || path.startsWith("haxe.Http."))
			return HScriptLib.NETWORK;

		if (path.startsWith("hscript.") || path.startsWith("hscriptBase."))
			return HScriptLib.INTERPRETER;

		if (path.startsWith("cpp.") || path.startsWith("cs.") || path.startsWith("java.") || path.startsWith("js.") || path.startsWith("php.")
			|| path.startsWith("python.") || path.startsWith("neko.") || path.startsWith("lua.") || path.startsWith("hl.") || path.startsWith("flash."))
			return HScriptLib.NATIVE_TARGET;

		if (path == "Sys")
			return HScriptLib.SYS;

		if (path.startsWith("sys.")) {
			if (path.startsWith("sys.io.Process"))
				return HScriptLib.PROCESS;
			if (path.startsWith("sys.thread."))
				return HScriptLib.THREADING;
			if (path.startsWith("sys.net."))
				return HScriptLib.NETWORK;
			if (path.startsWith("sys.io.") || path.startsWith("sys.FileSystem"))
				return HScriptLib.FILESYSTEM;
			return HScriptLib.SYS;
		}

		return 0;
	}
}
