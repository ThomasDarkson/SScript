package hscript;

import hscriptBase.Parser;
import hscriptBase.Expr;
import hscript.native.NativeTypes;
import hscript.native.NativeHandle;

private typedef Entry = {name:String, source:String, owner:SScript, value:Dynamic, valid:Void->Bool};
typedef SharedLoad = {source:String, expr:Expr, declarations:Array<{name:String, source:String}>};

private typedef WaitingContext = {
	owner:SScript,
	epoch:Int,
	used:Map<String, Bool>,
	local:Map<String, Bool>,
	selected:Map<String, Entry>,
	ready:Bool,
	root:Map<String, Dynamic>
};

@:access(hscriptBase.Parser)
@:access(hscript.SScript)
@:access(hscriptBase.Interp)
class SharedTypes {
	static var entries:Array<Entry> = [];
	static var namespaces:Map<SScript, Array<String>> = [];
	static var waiting:Map<SScript, WaitingContext> = [];

	public static function hasDefinitions(owner:SScript):Bool {
		for (e in entries)
			if (e.owner == owner && e.valid())
				return true;
		return false;
	}

	public static function unloadAll():Void {
		var owners:Map<SScript, Bool> = [];
		for (e in entries)
			owners.set(e.owner, true);
		for (owner in owners.keys())
			owner.unload();
	}

	public static function remove(owner:SScript):Void {
		waiting.remove(owner);
		entries = entries.filter(function(e) return e.owner != owner);
		var names = namespaces.get(owner);
		if (names != null && owner.interp != null)
			for (n in names)
				owner.interp.variables.remove(n);
		namespaces.remove(owner);
		if (owner.interp != null)
			owner.interp.finalVariables.remove("__ssShared");
	}

	static function names(source:String):{used:Map<String, Bool>, local:Map<String, Bool>} {
		var p = new Parser();
		p.initParser("shared types");
		p.input = source;
		var used:Map<String, Bool> = [], local:Map<String, Bool> = [], depth = 0, declare = false;
		while (true)
			switch (p.token()) {
				case TEof:
					return {used: used, local: local};
				case TBrOpen:
					depth++;
					declare = false;
				case TBrClose:
					depth--;
					declare = false;
				case TId(n):
					used.set(n, true);
					if (declare) {
						local.set(n, true);
						declare = false;
					} else if (depth == 0 && ["class", "interface", "enum"].indexOf(n) >= 0)
						declare = true;
				default:
					declare = false;
			}
	}

	public static function prepare(owner:SScript, source:String, allowed:Bool, ?origin:String):SharedLoad {
		var selected:Map<String, Entry> = [], available:Map<String, Entry> = [], prefix = "";
		var tokens = names(source);
		if (allowed) {
			for (e in entries)
				if (e.valid())
					available.set(e.name, e);
			function include(name:String):Void {
				if (selected.exists(name) || tokens.local.exists(name))
					return;
				var e = available.get(name);
				if (e == null)
					return;
				selected.set(name, e);
				var refs = names(e.source);
				for (n in refs.used.keys())
					if (n != name)
						include(n);
			}
			for (n in tokens.used.keys())
				include(n);

			for (e in entries)
				if (selected.get(e.name) == e)
					prefix += "shared" + e.source + "\n";
		}
		namespaces.set(owner, [for (n in tokens.local.keys()) n].concat([for (n in selected.keys()) n]));
		if (allowed)
			waiting.set(owner, {
				owner: owner,
				epoch: owner.interp.nativeLifetime,
				used: tokens.used,
				local: tokens.local,
				selected: selected,
				ready: false,
				root: null
			});
		owner.interp.finalVariables.set("__ssShared", new SharedAPI(selected));
		var text = NativeTypes.source(prefix + source, allowed);
		var parser = owner.parser;
		var expr = parser.parseString(text, origin == null ? owner.toString() : origin);
		return {source: text, expr: expr, declarations: allowed ? parser.typeSources.copy() : []};
	}

	public static function publish(owner:SScript, load:SharedLoad):Void {
		var context = waiting.get(owner);
		if (context != null) {
			context.ready = true;
			context.root = owner.interp.locals;

			var i = entries.length;
			while (i > 0)
				bindLate(context, entries[--i]);
		}
		var epoch = owner.interp.nativeLifetime;
		var valid = function() return !owner._destroyed && owner.interp != null && owner.interp.nativeLifetime == epoch;
		for (d in load.declarations) {
			var value:Dynamic;
			#if cpp
			value = owner.vmBackend != null ? owner.vmBackend.getGlobal(d.name, true) : owner.get(d.name);
			#else
			value = owner.get(d.name);
			#end
			if (value != null && NativeTypes.scriptName(value) == d.name) {
				var entry:Entry = {
					name: d.name,
					source: d.source,
					owner: owner,
					value: value,
					valid: valid
				};
				entries.push(entry);
				for (context in waiting)
					bindLate(context, entry);
			}
		}
	}

	static function bindLate(context:WaitingContext, entry:Entry):Void {
		var owner = context.owner, name = entry.name;
		if (!entry.valid())
			return;
		if (!context.ready
			|| owner._destroyed
			|| owner.interp == null
			|| owner.hscriptSandboxed
			|| owner.interp.nativeLifetime != context.epoch)
			return;
		if (!context.used.exists(name) || context.local.exists(name) || context.selected.exists(name))
			return;

		if (owner.interp.finalVariables.exists(name)
			|| owner.interp.variables.exists(name)
			|| (context.root != null && context.root.exists(name)))
			return;
		#if cpp
		if (owner.vmBackend != null && owner.vmBackend.owns(name))
			return;
		#end
		var value = new SharedType(entry);
		#if cpp
		if (owner.vmBackend != null)
			owner.vmBackend.setGlobal(name, value);
		#end
		owner.interp.variables.set(name, value);
		context.selected.set(name, entry);
		var names = namespaces.get(owner);
		if (names != null && names.indexOf(name) < 0)
			names.push(name);
	}
}

@:keep
private class SharedAPI {
	var types:Map<String, Entry>;

	public function new(types:Map<String, Entry>)
		this.types = types;

	public function type(name:String):Dynamic {
		var e = types.get(name);
		if (e == null || !e.valid())
			throw "Shared script type is no longer active: " + name;
		return new SharedType(e);
	}
}

@:keep
private class SharedType implements NativeHandle {
	var entry:Entry;
	var handle:NativeHandle;

	public function new(entry:Entry) {
		this.entry = entry;
		handle = NativeTypes.handle(entry.value);
	}

	function check():Void {
		if (!entry.valid())
			throw "Shared script type is no longer active: " + entry.name;
	}

	function guarded(value:Dynamic):Dynamic {
		if (!Reflect.isFunction(value))
			return value;
		return Reflect.makeVarArgs(function(args) {
			check();
			return Reflect.callMethod(null, value, args);
		});
	}

	public function has(name:String):Bool {
		check();
		return handle.has(name);
	}

	public function rawGet(name:String):Dynamic {
		check();
		return guarded(handle.rawGet(name));
	}

	public function read(name:String):Dynamic {
		check();
		return guarded(handle.read(name));
	}

	public function rawSet(name:String, value:Dynamic):Void {
		check();
		handle.rawSet(name, value);
	}

	public function write(name:String, value:Dynamic):Void {
		check();
		handle.write(name, value);
	}

	public function release():Void {}
}
