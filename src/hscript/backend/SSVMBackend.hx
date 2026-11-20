package hscript.backend;

#if cpp
import cpp.Callable;
import cpp.ConstCharStar;
import cpp.Pointer;
import cpp.RawPointer;
import haxe.Exception;
import hscript.native.NativeTypes;
import hscript.native.NativeHandle;
import hscript.native.NativeInstance;
import hscript.native.NativeBinding.NativeHost;

@:include("ssvm.hpp")
@:native("ssvm_vm")
@:structAccess
extern class SSVMNativeVM {}

@:include("ssvm.hpp")
extern class SSVMNative {
	@:native("ssvm_create") static function create():RawPointer<SSVMNativeVM>;
	@:native("ssvm_destroy") static function destroy(vm:RawPointer<SSVMNativeVM>):Void;
	@:native("ssvm_last_error") static function lastError(vm:RawPointer<SSVMNativeVM>):ConstCharStar;
	@:native("ssvm_set_callbacks") static function setCallbacks(vm:RawPointer<SSVMNativeVM>, get:Callable<Int->ConstCharStar->Int>,
		set:Callable<Int->ConstCharStar->Int->Int>, call:Callable<Int->Int->RawPointer<Int>->Int>,
		method:Callable<Int->ConstCharStar->Int->RawPointer<Int>->Int>, construct:Callable<Int->Int->RawPointer<Int>->Int>, getIdx:Callable<Int->Int->Int>,
		setIdx:Callable<Int->Int->Int->Int>, equals:Callable<Int->Int->Int>, toStr:Callable<Int->ConstCharStar>, release:Callable<Int->Void>,
		print:Callable<ConstCharStar->Int->Int->RawPointer<ConstCharStar>->Void>, isType:Callable<Int->ConstCharStar->Int>):Void;
	@:native("ssvm_self_clear") static function selfClear(vm:RawPointer<SSVMNativeVM>):Void;
	@:native("ssvm_self_field") static function selfField(vm:RawPointer<SSVMNativeVM>, n:ConstCharStar):Void;
	@:native("ssvm_self_bind") static function selfBind(vm:RawPointer<SSVMNativeVM>, ref:Int):Void;
	@:native("ssvm_self_active") static function selfActive(vm:RawPointer<SSVMNativeVM>):Int;
	@:native("ssvm_compile") static function compile(vm:RawPointer<SSVMNativeVM>, src:ConstCharStar, origin:ConstCharStar):Int;
	@:native("ssvm_program_unsupported") static function programUnsupported(vm:RawPointer<SSVMNativeVM>, p:Int):ConstCharStar;
	@:native("ssvm_program_need_count") static function needCount(vm:RawPointer<SSVMNativeVM>, p:Int):Int;
	@:native("ssvm_program_need") static function need(vm:RawPointer<SSVMNativeVM>, p:Int, i:Int):ConstCharStar;
	@:native("ssvm_program_need_deferred") static function needDeferred(vm:RawPointer<SSVMNativeVM>, p:Int, i:Int):Int;
	@:native("ssvm_program_declared_count") static function declaredCount(vm:RawPointer<SSVMNativeVM>, p:Int):Int;
	@:native("ssvm_program_declared") static function declared(vm:RawPointer<SSVMNativeVM>, p:Int, i:Int):ConstCharStar;
	@:native("ssvm_program_import_count") static function importCount(vm:RawPointer<SSVMNativeVM>, p:Int):Int;
	@:native("ssvm_program_import_name") static function importName(vm:RawPointer<SSVMNativeVM>, p:Int, i:Int):ConstCharStar;
	@:native("ssvm_program_import_path") static function importPath(vm:RawPointer<SSVMNativeVM>, p:Int, i:Int):ConstCharStar;
	@:native("ssvm_run") static function run(vm:RawPointer<SSVMNativeVM>, p:Int):Int;
	@:native("ssvm_result_ref") static function resultRef(vm:RawPointer<SSVMNativeVM>):Int;
	@:native("ssvm_has_global") static function hasGlobal(vm:RawPointer<SSVMNativeVM>, n:ConstCharStar):Int;
	@:native("ssvm_global_is_builtin") static function isBuiltin(vm:RawPointer<SSVMNativeVM>, n:ConstCharStar):Int;
	@:native("ssvm_undef_global") static function undefGlobal(vm:RawPointer<SSVMNativeVM>, n:ConstCharStar):Void;
	@:native("ssvm_get_global_ref") static function getGlobalRef(vm:RawPointer<SSVMNativeVM>, n:ConstCharStar):Int;
	@:native("ssvm_set_global_ref") static function setGlobalRef(vm:RawPointer<SSVMNativeVM>, n:ConstCharStar, ref:Int):Void;
	@:native("ssvm_call_global") static function callGlobal(vm:RawPointer<SSVMNativeVM>, n:ConstCharStar, argc:Int, args:RawPointer<Int>):Int;
	@:native("ssvm_call_ref") static function callRef(vm:RawPointer<SSVMNativeVM>, fn:Int, argc:Int, args:RawPointer<Int>):Int;
	@:native("ssvm_error_ref") static function errorRef(vm:RawPointer<SSVMNativeVM>):Int;
	@:native("ssvm_set_host_error") static function setHostError(vm:RawPointer<SSVMNativeVM>, ref:Int):Void;
	@:native("ssvm_ref_null") static function refNull(vm:RawPointer<SSVMNativeVM>):Int;
	@:native("ssvm_ref_bool") static function refBool(vm:RawPointer<SSVMNativeVM>, b:Int):Int;
	@:native("ssvm_ref_int") static function refInt(vm:RawPointer<SSVMNativeVM>, i:Int):Int;
	@:native("ssvm_ref_float") static function refFloat(vm:RawPointer<SSVMNativeVM>, d:Float):Int;
	@:native("ssvm_ref_string") static function refString(vm:RawPointer<SSVMNativeVM>, s:ConstCharStar):Int;
	@:native("ssvm_ref_host") static function refHost(vm:RawPointer<SSVMNativeVM>, id:Int):Int;
	@:native("ssvm_ref_dup") static function refDup(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_free") static function refFree(vm:RawPointer<SSVMNativeVM>, r:Int):Void;
	@:native("ssvm_ref_type") static function refType(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_get_int") static function refGetInt(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_get_float") static function refGetFloat(vm:RawPointer<SSVMNativeVM>, r:Int):Float;
	@:native("ssvm_ref_get_bool") static function refGetBool(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_get_string") static function refGetString(vm:RawPointer<SSVMNativeVM>, r:Int):ConstCharStar;
	@:native("ssvm_ref_host_id") static function refHostId(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_array_len") static function arrayLen(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_array_get") static function arrayGet(vm:RawPointer<SSVMNativeVM>, r:Int, i:Int):Int;
	@:native("ssvm_ref_object_get") static function objectGet(vm:RawPointer<SSVMNativeVM>, r:Int, name:ConstCharStar, raw:Int):Int;
	@:native("ssvm_ref_object_set") static function objectSet(vm:RawPointer<SSVMNativeVM>, r:Int, name:ConstCharStar, value:Int, raw:Int):Int;
	@:native("ssvm_ref_object_len") static function objectLen(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_object_key") static function objectKey(vm:RawPointer<SSVMNativeVM>, r:Int, i:Int):ConstCharStar;
	@:native("ssvm_ref_object_val") static function objectVal(vm:RawPointer<SSVMNativeVM>, r:Int, i:Int):Int;
	@:native("ssvm_ref_map_raw_len") static function mapRawLen(vm:RawPointer<SSVMNativeVM>, r:Int):Int;
	@:native("ssvm_ref_map_key") static function mapKey(vm:RawPointer<SSVMNativeVM>, r:Int, i:Int):Int;
	@:native("ssvm_ref_map_val") static function mapVal(vm:RawPointer<SSVMNativeVM>, r:Int, i:Int):Int;
}

private class VMObject implements NativeHandle {
	public var backend:SSVMBackend;
	public var ref:Int;

	public function new(backend:SSVMBackend, ref:Int) {
		this.backend = backend;
		this.ref = ref;
	}

	public function release():Void {
		if (ref >= 0 && backend.vm != null)
			SSVMNative.refFree(backend.vm, ref);
		ref = -1;
	}

	public static function finalize(o:VMObject):Void
		o.release();

	public function has(name:String):Bool
		return backend.nativeHas(ref, name);

	public function rawGet(name:String):Dynamic
		return backend.nativeGet(ref, name, true);

	public function rawSet(name:String, value:Dynamic):Void
		backend.nativeSet(ref, name, value, true);

	public function read(name:String):Dynamic
		return backend.nativeGet(ref, name, false);

	public function write(name:String, value:Dynamic):Void
		backend.nativeSet(ref, name, value, false);
}

private class VMFunc {
	public var backend:SSVMBackend;
	public var ref:Int;

	public function new(b:SSVMBackend, r:Int) {
		backend = b;
		ref = r;
	}

	public function invoke(args:Array<Dynamic>):Dynamic
		return backend.callRefValue(ref, args);

	public static function finalize(f:VMFunc):Void {
		var b = f.backend;
		if (b != null && b.vm != null)
			SSVMNative.refFree(b.vm, f.ref);
	}
}

@:build(hscript.backend.SSVMBuild.build())
@:keep
private class SSVMBackendImpl {
	static var objs:Array<Dynamic> = [];
	static var freeIds:Array<Int> = [];
	static var active:SSVMBackend = null;
	static var strHold:String = "";
	static var alwaysBuiltin:Array<String> = [
		"trace",
		"null",
		"true",
		"false",
		"Bool",
		"Int",
		"Float",
		"String",
		"Array",
		"Map",
		"Dynamic",
		"StringMap",
		"IntMap",
		"ObjectMap",
		"Void",
		"Any",
		"haxe",
		"Timer"
	];

	static function register(o:Dynamic):Int {
		if (freeIds.length > 0) {
			var id = freeIds.pop();
			objs[id] = o;
			return id;
		}
		objs.push(o);
		return objs.length - 1;
	}

	public static function liveHostObjects():Int
		return objs.length - freeIds.length;

	public var vm(default, null):RawPointer<SSVMNativeVM>;
	public var owner:hscript.SScript;
	public var declared(default, null):Array<String> = [];

	var declaredSet:Map<String, Bool> = new Map();
	var fnCache:Map<String, Dynamic> = new Map();
	var prog:Int = -1;
	var origin:String;

	function new() {
		vm = SSVMNative.create();
		SSVMNative.setCallbacks(vm, Callable.fromStaticFunction(cbGet), Callable.fromStaticFunction(cbSet), Callable.fromStaticFunction(cbCall),
			Callable.fromStaticFunction(cbMethod), Callable.fromStaticFunction(cbNew), Callable.fromStaticFunction(cbGetIdx),
			Callable.fromStaticFunction(cbSetIdx), Callable.fromStaticFunction(cbEquals), Callable.fromStaticFunction(cbToStr),
			Callable.fromStaticFunction(cbRelease), Callable.fromStaticFunction(cbPrint), Callable.fromStaticFunction(cbIsType));
	}

	public function destroy():Void {
		if (vm == null)
			return;
		var v = vm;
		var saved = active;
		active = this;
		fnCache = new Map();
		vm = null;
		SSVMNative.destroy(v);
		active = saved == this ? null : saved;
	}

	public static var debug:Bool = #if SSVM_DEBUG true #else false #end;

	static function why(msg:String):Bool {
		if (debug)
			Sys.println("[ssvm] interpreter fallback: " + msg);
		return false;
	}

	public static function create(code:String, origin:String, lookup:String->Dynamic, ?selfObj:Dynamic, ?selfFields:Array<String>):SSVMBackend {
		var b = new SSVMBackend();
		var ok = false;
		var saved = active;
		active = b;
		try {
			if (selfObj != null && selfFields != null && selfFields.length > 0)
				b.bindSelf(selfObj, selfFields);
			ok = b.prepare(code, origin, lookup);
		} catch (e)
			ok = why("exception " + e);
		active = saved;
		if (!ok) {
			b.destroy();
			return null;
		}
		return b;
	}

	function bindSelf(obj:Dynamic, fields:Array<String>):Void {
		for (f in fields)
			SSVMNative.selfField(vm, ConstCharStar.fromString(f));
		SSVMNative.selfBind(vm, toRef(obj));
	}

	public function hasSelf():Bool
		return vm != null && SSVMNative.selfActive(vm) != 0;

	public function rebindSelf(obj:Dynamic):Void {
		if (!hasSelf())
			return;
		var saved = active;
		active = this;
		SSVMNative.selfBind(vm, toRef(obj));
		active = saved;
	}

	function prepare(code:String, origin:String, lookup:String->Dynamic):Bool {
		this.origin = origin;
		prog = SSVMNative.compile(vm, code, origin);
		if (prog < 0)
			return why("compile: " + SSVMNative.lastError(vm).toString());
		var un = SSVMNative.programUnsupported(vm, prog).toString();
		if (un != "")
			return why("unsupported: " + un);

		var bound = new Map<String, Bool>();
		for (i in 0...SSVMNative.importCount(vm, prog)) {
			var name = SSVMNative.importName(vm, prog, i).toString();
			var path = SSVMNative.importPath(vm, prog, i).toString();
			if (name == "") {
				for (field => value in resolveWildcard(path)) {
					bindValue(field, value);
					bound[field] = true;
				}
				continue;
			}
			var c:Dynamic = resolveImport(path);
			if (c == null) {
				if (debug)
					Sys.println("[ssvm] ignoring unresolved import " + path + " (only matters if the script uses it)");
				continue;
			}
			bindValue(name, c);
			bound[name] = true;
		}

		for (i in 0...SSVMNative.declaredCount(vm, prog)) {
			var n = SSVMNative.declared(vm, prog, i).toString();
			declared.push(n);
			declaredSet[n] = true;
		}

		for (i in 0...SSVMNative.needCount(vm, prog)) {
			var n = SSVMNative.need(vm, prog, i).toString();
			if (bound.exists(n))
				continue;
			if (n == "__ss_regex") {
				bindValue(n, EReg);
				continue;
			}
			var builtin = SSVMNative.isBuiltin(vm, n) != 0;
			var v:Dynamic = lookup(n);
			if (n == "EReg")
				bindValue(n, v == null ? EReg : v);
			else if (builtin) {
				if (alwaysBuiltin.indexOf(n) >= 0 || v == null || v == Type.resolveClass(n))
					continue;
				bindValue(n, v);
			} else if (v != null)
				bindValue(n, v);
			else if (n.indexOf(".") >= 0 && (v = resolveType(n)) != null)
				bindValue(n, v);
			else if (SSVMNative.hasGlobal(vm, n) == 0 && SSVMNative.needDeferred(vm, prog, i) == 0)
				return why("unresolved name " + n);
		}
		return true;
	}

	static function resolveType(path:String):Dynamic {
		var c:Dynamic = Type.resolveClass(path);
		if (c == null)
			c = Type.resolveEnum(path);
		return c;
	}

	static function resolveWildcard(path:String):Map<String, Dynamic> {
		var fields:Map<String, Dynamic> = [];
		var type:Dynamic = Type.resolveClass(path);
		var isEnum = type == null;
		if (isEnum)
			type = Type.resolveEnum(path);
		if (type != null) {
			var names = isEnum ? Type.getEnumConstructs(type) : Type.getClassFields(type);
			for (name in names) {
				var value = isEnum ? Reflect.field(type, name) : Reflect.getProperty(type, name);
				if (value != null)
					fields[name] = value;
			}
		} else {
			#if !DISABLED_MACRO_SUPERLATIVE
			var prefix = path + ".";
			for (name => value in @:privateAccess hscriptBase.Tools.allClassesAvailable) {
				if (StringTools.startsWith(name, prefix) && name.indexOf(".", prefix.length) < 0)
					fields[name.substr(prefix.length)] = value;
			}
			#end
		}
		return fields;
	}

	/**
		Resolves the path of an `import`. Besides the plain `pack.Type` form this handles:
		- types declared inside another module (`flixel.text.FlxText.FlxTextBorderStyle`): at run time these are named
		  `pack.Type`, without the module, so the module segment is dropped;
		- a static field / inner value of a resolvable prefix (`pack.Class.field`), like the interpreter does.
	**/
	static function resolveImport(path:String):Dynamic {
		var c = resolveType(path);
		if (c != null)
			return c;

		var parts = path.split(".");
		if (parts.length >= 2) {
			for (drop in 1...parts.length) {
				var idx = parts.length - 1 - drop;
				if (idx < 0)
					break;
				var p2 = parts.copy();
				p2.splice(idx, 1);
				c = resolveType(p2.join("."));
				if (c != null)
					return c;
			}
		}

		for (i in 1...parts.length) {
			var base:Dynamic = resolveType(parts.slice(0, i).join("."));
			if (base == null)
				continue;
			try {
				for (j in i...parts.length)
					base = Reflect.getProperty(base, parts[j]);
			} catch (e:Dynamic)
				base = null;
			if (base != null)
				return base;
		}
		return null;
	}

	function bindValue(name:String, v:Dynamic):Void {
		SSVMNative.setGlobalRef(vm, name, toRef(v));
	}

	public function run():Null<String> {
		var saved = active;
		active = this;
		var r = SSVMNative.run(vm, prog);
		active = saved;
		if (r != 0)
			return SSVMNative.lastError(vm).toString();
		return null;
	}

	public function result():Dynamic {
		var saved = active;
		active = this;
		var v = fromRef(SSVMNative.resultRef(vm));
		active = saved;
		return v;
	}

	public function isDeclared(name:String):Bool
		return declaredSet.exists(name);

	public function owns(name:String):Bool
		return vm != null && (declaredSet.exists(name) || (SSVMNative.hasGlobal(vm, name) != 0 && SSVMNative.isBuiltin(vm, name) == 0));

	public function getGlobal(name:String, liveScriptObjects:Bool = false):Dynamic {
		var saved = active;
		active = this;
		var ref = SSVMNative.getGlobalRef(vm, name);
		if (declaredSet.exists(name) && SSVMNative.refType(vm, ref) == 9) {
			SSVMNative.refFree(vm, ref);
			active = saved;
			return functionWrapper(name);
		}
		var v = fromRef(ref, 0, liveScriptObjects);
		active = saved;
		return v;
	}

	public function syncInto(map:Map<String, Dynamic>):Void {
		var saved = active;
		active = this;
		for (n in declared) {
			var ref = SSVMNative.getGlobalRef(vm, n);
			var t = SSVMNative.refType(vm, ref);
			if (t == 9) {
				SSVMNative.refFree(vm, ref);
				map.set(n, functionWrapper(n));
			} else if (t <= 4)
				map.set(n, fromRef(ref));
			else
				SSVMNative.refFree(vm, ref);
		}
		active = saved;
	}

	public function setGlobal(name:String, v:Dynamic):Void {
		var saved = active;
		active = this;
		SSVMNative.setGlobalRef(vm, name, toRef(v));
		active = saved;
	}

	public function removeGlobal(name:String):Void {
		SSVMNative.undefGlobal(vm, name);
		declaredSet.remove(name);
		declared.remove(name);
		fnCache.remove(name);
	}

	public function functionWrapper(name:String):Dynamic {
		var f = fnCache.get(name);
		if (f == null) {
			var me = this;
			f = Reflect.makeVarArgs(function(args:Array<Dynamic>) return me.callGlobal(name, args));
			fnCache.set(name, f);
		}
		return f;
	}

	public function callGlobal(name:String, args:Array<Dynamic>):Dynamic {
		return owner == null
			|| owner.errorBoundaryDepth > 0 ? callGlobalInternal(name, args) : owner.withErrorBoundary(function() return callGlobalInternal(name, args));
	}

	function callGlobalInternal(name:String, args:Array<Dynamic>):Dynamic {
		if (vm == null)
			throw new Exception("Script is destroyed");
		var saved = active;
		active = this;
		try {
			var refs = [for (a in args) toRef(a)];
			var r = SSVMNative.callGlobal(vm, name, refs.length, refs.length > 0 ? Pointer.ofArray(refs).raw : null);
			if (r < 0)
				throwVMError();
			var res = fromRef(r);
			active = saved;
			return res;
		} catch (e) {
			active = saved;
			throw e;
		}
	}

	public function callRefValue(ref:Int, args:Array<Dynamic>):Dynamic {
		return owner == null
			|| owner.errorBoundaryDepth > 0 ? callRefInternal(ref, args) : owner.withErrorBoundary(function() return callRefInternal(ref, args));
	}

	function callRefInternal(ref:Int, args:Array<Dynamic>):Dynamic {
		if (vm == null)
			throw new Exception("Script is destroyed");
		var saved = active;
		active = this;
		try {
			var refs = [for (a in args) toRef(a)];
			var r = SSVMNative.callRef(vm, ref, refs.length, refs.length > 0 ? Pointer.ofArray(refs).raw : null);
			if (r < 0)
				throwVMError();
			var res = fromRef(r);
			active = saved;
			return res;
		} catch (e) {
			active = saved;
			throw e;
		}
	}

	public function nativeHas(ref:Int, name:String):Bool {
		if (vm == null || ref < 0)
			throw new Exception("Native script instance is no longer active");
		for (i in 0...SSVMNative.objectLen(vm, ref))
			if (SSVMNative.objectKey(vm, ref, i).toString() == name)
				return true;
		return false;
	}

	public function nativeGet(ref:Int, name:String, raw:Bool):Dynamic {
		if (vm == null || ref < 0)
			throw new Exception("Native script instance is no longer active");
		var saved = active;
		active = this;
		try {
			var r = SSVMNative.objectGet(vm, ref, name, raw ? 1 : 0);
			if (r < 0)
				throw new Exception(SSVMNative.lastError(vm).toString());
			var result = fromRef(r);
			active = saved;
			return result;
		} catch (e:Dynamic) {
			active = saved;
			throw e;
		}
	}

	public function nativeSet(ref:Int, name:String, value:Dynamic, raw:Bool):Void {
		if (vm == null || ref < 0)
			throw new Exception("Native script instance is no longer active");
		var saved = active;
		active = this;
		try {
			var r = SSVMNative.objectSet(vm, ref, name, toRef(value), raw ? 1 : 0);
			if (r < 0)
				throw new Exception(SSVMNative.lastError(vm).toString());
			active = saved;
		} catch (e:Dynamic) {
			active = saved;
			throw e;
		}
	}

	function throwVMError():Void {
		var msg = SSVMNative.lastError(vm).toString();
		var er = SSVMNative.errorRef(vm);
		if (er >= 0) {
			var v:Dynamic = fromRef(er);
			if (v != null && !Std.isOfType(v, String))
				throw v;
		}
		throw new Exception(msg);
	}

	static function toRef(v:Dynamic):Int {
		var vm = active.vm;
		if (Std.isOfType(v, NativeHost))
			return SSVMNative.refHost(vm, register((cast v : NativeHost).value));
		if (Std.isOfType(v, NativeInstance)) {
			var handle = (cast v : NativeInstance).__ss_binding.self;
			if (Std.isOfType(handle, VMObject)) {
				var object:VMObject = cast handle;
				if (object.backend == active && object.ref >= 0)
					return SSVMNative.refDup(vm, object.ref);
			}
		}
		if (Std.isOfType(v, VMObject)) {
			var object:VMObject = cast v;
			if (object.ref < 0 || object.backend.vm == null)
				throw new Exception("Script object belongs to a destroyed VM");
			return object.backend == active ? SSVMNative.refDup(vm, object.ref) : SSVMNative.refHost(vm, register(v));
		}
		switch (Type.typeof(v)) {
			case TNull:
				return SSVMNative.refNull(vm);
			case TInt:
				return SSVMNative.refInt(vm, v);
			case TFloat:
				return SSVMNative.refFloat(vm, v);
			case TBool:
				return SSVMNative.refBool(vm, v ? 1 : 0);
			default:
				if (Std.isOfType(v, String)) {
					var s:String = v;
					return SSVMNative.refString(vm, ConstCharStar.fromString(s));
				}
				return SSVMNative.refHost(vm, register(v));
		}
	}

	static function fromRef(ref:Int, depth:Int = 0, liveScriptObjects:Bool = true):Dynamic {
		var r = conv(ref, depth, liveScriptObjects);
		SSVMNative.refFree(active.vm, ref);
		return r;
	}

	static function conv(ref:Int, depth:Int, liveScriptObjects:Bool):Dynamic {
		var b = active;
		var vm = b.vm;
		if (depth > 64)
			return null;
		switch (SSVMNative.refType(vm, ref)) {
			case 0:
				return null;
			case 1:
				return SSVMNative.refGetBool(vm, ref) != 0;
			case 2:
				return SSVMNative.refGetInt(vm, ref);
			case 3:
				return SSVMNative.refGetFloat(vm, ref);
			case 4:
				return SSVMNative.refGetString(vm, ref).toString();
			case 5:
				var n = SSVMNative.arrayLen(vm, ref);
				var a:Array<Dynamic> = [];
				for (i in 0...n) {
					var e = SSVMNative.arrayGet(vm, ref, i);
					a.push(fromRef(e, depth + 1, liveScriptObjects));
				}
				return a;
			case 6:
				var live = false;
				for (marker in ["__ss_name", "__ss_class", "__ss_enum"]) {
					var r = SSVMNative.objectGet(vm, ref, marker, 1);
					if (SSVMNative.refType(vm, r) == 4)
						live = true;
					SSVMNative.refFree(vm, r);
				}
				var key = SSVMNative.objectGet(vm, ref, "__ss_nativeKey", 1);
				var nativeObject = SSVMNative.refType(vm, key) == 4 && SSVMNative.refGetString(vm, key).toString() != "";
				SSVMNative.refFree(vm, key);
				if (nativeObject || (live && liveScriptObjects)) {
					var host = SSVMNative.objectGet(vm, ref, "__ss_host", 1);
					if (SSVMNative.refType(vm, host) == 8) {
						var value = objs[SSVMNative.refHostId(vm, host)];
						SSVMNative.refFree(vm, host);
						return value;
					}
					SSVMNative.refFree(vm, host);
					var object = new VMObject(b, SSVMNative.refDup(vm, ref));
					cpp.vm.Gc.setFinalizer(object, Callable.fromStaticFunction(VMObject.finalize));
					return object;
				}
				var o:Dynamic = {};
				for (i in 0...SSVMNative.objectLen(vm, ref)) {
					var k = SSVMNative.objectKey(vm, ref, i).toString();
					var e = SSVMNative.objectVal(vm, ref, i);
					Reflect.setField(o, k, fromRef(e, depth + 1, liveScriptObjects));
				}
				return o;
			case 7:
				var keys:Array<Dynamic> = [];
				var vals:Array<Dynamic> = [];
				for (i in 0...SSVMNative.mapRawLen(vm, ref)) {
					var kr = SSVMNative.mapKey(vm, ref, i);
					if (kr < 0)
						continue;
					var vr = SSVMNative.mapVal(vm, ref, i);
					keys.push(fromRef(kr, depth + 1, liveScriptObjects));
					vals.push(fromRef(vr, depth + 1, liveScriptObjects));
				}
				var m:Dynamic;
				if (keys.length > 0 && Std.isOfType(keys[0], Int)) {
					var im = new Map<Int, Dynamic>();
					for (i in 0...keys.length)
						im.set(keys[i], vals[i]);
					m = im;
				} else if (keys.length > 0 && !Std.isOfType(keys[0], String)) {
					var om = new Map<{}, Dynamic>();
					for (i in 0...keys.length)
						om.set(keys[i], vals[i]);
					m = om;
				} else {
					var sm = new Map<String, Dynamic>();
					for (i in 0...keys.length)
						sm.set(keys[i], vals[i]);
					m = sm;
				}
				return m;
			case 8:
				return objs[SSVMNative.refHostId(vm, ref)];
			case 9:
				var f = new VMFunc(b, SSVMNative.refDup(vm, ref));
				cpp.vm.Gc.setFinalizer(f, Callable.fromStaticFunction(VMFunc.finalize));
				return Reflect.makeVarArgs(f.invoke);
			default:
				return SSVMNative.refGetString(vm, ref).toString();
		}
	}

	static function fail(e:Dynamic):Int {
		SSVMNative.setHostError(active.vm, toRef(e));
		return -1;
	}

	static function args(n:Int, p:RawPointer<Int>):Array<Dynamic> {
		var ids:Array<Int> = [];
		for (i in 0...n)
			ids.push(untyped __cpp__("{0}[{1}]", p, i));
		return [for (id in ids) fromRef(id)];
	}

	static function cbGet(id:Int, name:ConstCharStar):Int {
		try
			return toRef(NativeTypes.read(objs[id], name.toString()))
		catch (e:Dynamic)
			return fail(e);
	}

	static function cbSet(id:Int, name:ConstCharStar, valRef:Int):Int {
		try {
			var v = fromRef(valRef);
			NativeTypes.write(objs[id], name.toString(), v);
			return 0;
		} catch (e:Dynamic)
			return fail(e);
	}

	static function cbCall(id:Int, n:Int, p:RawPointer<Int>):Int {
		try {
			var a = args(n, p);
			return toRef(Reflect.callMethod(null, objs[id], a));
		} catch (e:Dynamic)
			return fail(e);
	}

	static function iterOf(o:Dynamic, kv:Bool):Dynamic {
		if (Std.isOfType(o, Array))
			return kv ? (o : Array<Dynamic>).keyValueIterator() : (o : Array<Dynamic>).iterator();
		if (Std.isOfType(o, haxe.Constraints.IMap)) {
			var m:haxe.Constraints.IMap<Dynamic, Dynamic> = o;
			return kv ? m.keyValueIterator() : m.iterator();
		}
		var f:Dynamic = Reflect.field(o, kv ? "keyValueIterator" : "iterator");
		if (f == null && kv)
			f = Reflect.field(o, "iterator");
		if (f != null)
			return Reflect.callMethod(o, f, []);
		return o;
	}

	static function cbMethod(id:Int, name:ConstCharStar, n:Int, p:RawPointer<Int>):Int {
		try {
			var a = args(n, p);
			var o = objs[id];
			var nm = name.toString();
			if (nm == "__ss_match_enum")
				return toRef(matchEnum(o, a[0], a[1]));
			if (nm == "iterator" || nm == "keyValueIterator")
				return toRef(iterOf(o, nm == "keyValueIterator"));
			var f:Dynamic = NativeTypes.special(o) ? NativeTypes.read(o, nm) : Reflect.field(o, nm);
			if (f == null)
				f = Reflect.getProperty(o, nm);
			if (f == null) {
				var d:Dynamic = o;
				if (nm == "hasNext")
					return toRef(d.hasNext());
				if (nm == "next")
					return toRef(d.next());
				throw new Exception("Object has no method '" + nm + "'");
			}
			return toRef(Reflect.callMethod(o, f, a));
		} catch (e:Dynamic)
			return fail(e);
	}

	static function matchEnum(value:Dynamic, pattern:String, arity:Int):Dynamic {
		var separator = pattern.indexOf("|");
		var qualifier = pattern.substr(0, separator);
		var tag = pattern.substr(separator + 1);
		var params:Array<Dynamic>;
		if (Reflect.isEnumValue(value)) {
			if (Type.enumConstructor(value) != tag)
				return null;
			if (qualifier != "") {
				var expected = fromRef(SSVMNative.getGlobalRef(active.vm, qualifier));
				if (expected == null)
					expected = resolveImport(qualifier);
				if (Type.getEnum(value) != expected)
					return null;
			}
			params = Type.enumParameters(value);
		} else {
			var enumName = NativeTypes.read(value, "__ss_enum");
			if (enumName == null)
				return false;
			if ((qualifier != "" && qualifier != enumName) || NativeTypes.read(value, "tag") != tag)
				return null;
			params = NativeTypes.read(value, "params");
		}
		return params != null && params.length == arity ? params : null;
	}

	static function cbNew(id:Int, n:Int, p:RawPointer<Int>):Int {
		try {
			var a = args(n, p);
			var type:Dynamic = objs[id];
			if (Std.isOfType(type, hscript.native.NativeDescriptor)) {
				var descriptor:hscript.native.NativeDescriptor = cast type;
				if (descriptor.isInterface)
					throw new Exception("Cannot instantiate interface: " + descriptor.name);
				type = descriptor.nativeType;
			}
			if (NativeTypes.read(type, "__ss_interface") == true)
				throw new Exception("Cannot instantiate interface");
			var factory = NativeTypes.read(type, "__ss_create");
			if (factory != null)
				return toRef(Reflect.callMethod(null, factory, a));
			return toRef(Type.createInstance(cast type, a));
		} catch (e:Dynamic)
			return fail(e);
	}

	static function cbGetIdx(id:Int, idxRef:Int):Int {
		try {
			var idx:Dynamic = fromRef(idxRef);
			var o:Dynamic = objs[id];
			if (Std.isOfType(o, Array))
				return toRef((o : Array<Dynamic>)[idx]);
			if (Std.isOfType(o, haxe.Constraints.IMap))
				return toRef((o : haxe.Constraints.IMap<Dynamic, Dynamic>).get(idx));
			return toRef(Reflect.getProperty(o, Std.string(idx)));
		} catch (e:Dynamic)
			return fail(e);
	}

	static function cbSetIdx(id:Int, idxRef:Int, valRef:Int):Int {
		try {
			var idx:Dynamic = fromRef(idxRef);
			var v:Dynamic = fromRef(valRef);
			var o:Dynamic = objs[id];
			if (Std.isOfType(o, Array))
				(o : Array<Dynamic>)
			[idx] = v;
		else if (Std.isOfType(o, haxe.Constraints.IMap))
			(o : haxe.Constraints.IMap<Dynamic, Dynamic>).set(idx, v);
		else
			Reflect.setProperty(o, Std.string(idx), v);
			return 0;
		} catch (e:Dynamic)
			return fail(e);
	}

	static function cbEquals(a:Int, b:Int):Int
		return objs[a] == objs[b] ? 1 : 0;

	static function cbToStr(id:Int):ConstCharStar {
		strHold = try Std.string(objs[id]) catch (e:Dynamic) "<error>";
		return ConstCharStar.fromString(strHold);
	}

	static function cbRelease(id:Int):Void {
		if (id >= 0 && id < objs.length) {
			objs[id] = null;
			freeIds.push(id);
		}
	}

	static function cbPrint(origin:ConstCharStar, line:Int, n:Int, strs:RawPointer<ConstCharStar>):Void {
		var parts:Array<String> = [];
		for (i in 0...n) {
			var cs:ConstCharStar = untyped __cpp__("{0}[{1}]", strs, i);
			parts.push(cs.toString());
		}
		var first = parts.length > 0 ? parts.shift() : "";
		var inf:haxe.PosInfos = {
			fileName: origin.toString(),
			lineNumber: line,
			className: "",
			methodName: ""
		};
		if (parts.length > 0)
			inf.customParams = parts;
		haxe.Log.trace(first, inf);
	}

	static function cbIsType(id:Int, name:ConstCharStar):Int {
		try {
			var c:Dynamic = null;
			var ref = SSVMNative.getGlobalRef(active.vm, name);
			if (SSVMNative.refType(active.vm, ref) == 8) {
				var local = objs[SSVMNative.refHostId(active.vm, ref)];
				if (Std.isOfType(local, hscript.native.NativeDescriptor))
					c = (cast local : hscript.native.NativeDescriptor).nativeType;
				else if (NativeTypes.scriptName(local) != null) {
					SSVMNative.refFree(active.vm, ref);
					return NativeTypes.scriptMatches(objs[id], name.toString()) ? 1 : 0;
				}
			}
			SSVMNative.refFree(active.vm, ref);
			if (c == null)
				c = NativeTypes.resolve(name.toString());
			if (c == null)
				c = Type.resolveClass(name.toString());
			if (c == null)
				c = Type.resolveEnum(name.toString());
			return c != null && Std.isOfType(objs[id], c) ? 1 : 0;
		} catch (e:Dynamic)
			return 0;
	}
}

typedef SSVMBackend = SSVMBackendImpl;
#end
