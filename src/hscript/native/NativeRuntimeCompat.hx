package hscript.native;

#if macro
import haxe.macro.Context;
import haxe.macro.Compiler;
import haxe.macro.Type;
import sys.io.File;
import sys.FileSystem;

@:access(hscript.native.NativeMacro)
class NativeRuntimeCompat {
	static var classes:Map<String, Array<String>> = [];
	static var compile = false;
	static var active = false;

	public static function unsafe(t:Type):Bool {
		return switch (t) {
			case TLazy(f): unsafe(f());
			case TMono(r): r.get() != null && unsafe(r.get());
			case TFun(args, ret): unsafe(ret) || Lambda.exists(args, a -> unsafe(a.t));
			case TType(r, p): var d = r.get(); (d.pack.join(".") == "cpp" && pointerName(d.name)) || unsafe(Context.follow(t));
			case TAbstract(r, p): var d = r.get(); (d.pack.join(".") == "cpp" && pointerName(d.name)) || (d.name == "Null" && p.length == 1 && unsafe(p[0]));
			case TInst(r, _): var c = r.get(); (c.pack.join(".") == "cpp" && pointerName(c.name)) || nativePointer(c.meta);
			default: false;
		};
	}

	static function nativePointer(meta:MetaAccess):Bool {
		for (m in meta.get())
			if (m.name == ":native")
				for (p in m.params)
					switch (p.expr) {
						case EConst(CString(s, _)) if (s.indexOf("*") >= 0):
							return true;
						default:
					}
		return false;
	}

	static function pointerName(name:String):Bool
		return [
			"RawPointer",
			"RawConstPointer",
			"ConstCharStar",
			"CastCharStar",
			"CharStar",
			"Star",
			"ConstStar",
			"VoidStar",
			"VoidStarConstStar",
			"AutoCast",
			"Function",
			"Callable"
		].indexOf(name) >= 0;

	public static function init():Void {
		if (active)
			return;
		active = true;

		compile = !Context.defined("no-compilation");
		if (compile)
			Compiler.define("no-compilation");
		Context.onAfterGenerate(finish);
	}

	public static function collect(c:ClassType):Void {
		if (c.isExtern || c.isPrivate || c.meta.has(":nativeGen"))
			return;
		var names:Array<String> = [];
		for (f in NativeMacro.flat(c))
			switch (f.kind) {
				case FMethod(_) if (unsafe(f.type)):
					names.push(f.name);
				default:
			}
		for (f in c.statics.get())
			switch (f.kind) {
				case FMethod(_) if (unsafe(f.type)):
					names.push(f.name);
				default:
			}
		if (c.constructor != null && unsafe(c.constructor.get().type))
			names.push("__construct");
		if (names.length == 0)
			return;
		var path = c.pack.concat([c.name]).join("/");
		for (m in c.meta.get())
			if (m.name == ":native" && m.params.length == 1)
				switch (m.params[0].expr) {
					case EConst(CString(s, _)):
						path = s.split(".").join("/");
					default:
				}
		classes.set(path, names);
	}

	static function closeBrace(s:String, start:Int):Int {
		var depth = 0, i = start;
		while (i < s.length) {
			var c = s.charAt(i++);
			if (c == '"' || c == "'") {
				var q = c;
				while (i < s.length) {
					var v = s.charAt(i++);
					if (v == "\\")
						i++;
					else if (v == q)
						break;
				}
			} else if (c == "/" && s.charAt(i) == "/") {
				while (i < s.length && s.charAt(i) != "\n")
					i++;
			} else if (c == "/" && s.charAt(i) == "*") {
				var end = s.indexOf("*/", i + 1);
				if (end < 0)
					break;
				i = end + 2;
			} else if (c == "{")
				depth++;
			else if (c == "}" && --depth == 0)
				return i;
		}
		Context.fatalError("SScript: malformed generated C++ function", Context.currentPos());
		return -1;
	}

	public static function patch(s:String, names:Array<String>):String {
		for (name in names) {
			var thunk = name == "__construct" ? "__script_construct_func" : "__s_" + name;
			var re = new EReg("static void CPPIA_CALL " + thunk + "\\([^\\n]*\\) \\{", "g");
			var offset = 0;
			while (re.matchSub(s, offset)) {
				var p = re.matchedPos(),
					open = p.pos + p.len - 1,
					end = closeBrace(s, open);
				var body = '\n ::hx::Throw(HX_CSTRING("SScript: raw native callback ' + name + ' is not script-callable"));\n';
				s = s.substring(0, open + 1) + body + s.substring(end - 1);
				offset = open + 1 + body.length + 1;
			}
		}

		var marker = ~/class [A-Za-z0-9_]+__scriptable : public [^\n]+\{/;
		if (marker.match(s)) {
			var p = marker.matchedPos(),
				open = p.pos + p.len - 1,
				end = closeBrace(s, open);
			var block = s.substring(open + 1, end - 1);
			for (name in names)
				if (name != "__construct") {
					var re = new EReg("\n[ \\t]+[^\\n{};]+ " + name + "\\( [^\\n]*\\) \\{", "g"), offset = 0;
					while (re.matchSub(block, offset)) {
						var q = re.matchedPos(),
							finish = closeBrace(block, q.pos + q.len - 1);
						block = block.substring(0, q.pos) + block.substring(finish);
						offset = q.pos;
					}
				}
			s = s.substring(0, open + 1) + block + s.substring(end - 1);
		}
		return s;
	}

	static function finish():Void {
		var output = Compiler.getOutput(), doCompile = compile;
		var pending = classes;
		classes = [];
		compile = false;
		active = false;
		for (path => names in pending) {
			var file = output + "/src/" + path + ".cpp";
			if (!FileSystem.exists(file))
				continue;
			var original = File.getContent(file),
				changed = patch(original, names);
			if (changed != original)
				File.saveContent(file, changed);
		}
		if (!doCompile)
			return;
		var args = ["run", "hxcpp", "Build.xml", "haxe"];
		if (Context.defined("debug"))
			args.push("-Ddebug");
		for (name => value in Context.getDefines())
			if (["true", "sys", "dce", "cpp", "debug", "no-compilation", "no_compilation"].indexOf(name) < 0)
				args.push("-D" + name + "=" + value);
		for (path in Context.getClassPath())
			args.push("-I" + FileSystem.absolutePath(path));
		var cwd = Sys.getCwd(), status = 0;
		try {
			Sys.setCwd(output);
			status = Sys.command("haxelib", args);
			Sys.setCwd(cwd);
		} catch (e:Dynamic) {
			Sys.setCwd(cwd);
			throw e;
		}
		if (status != 0)
			Context.fatalError("SScript: hxcpp build failed (exit " + status + ")", Context.currentPos());
	}
}
#end
