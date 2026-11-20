package hscript.backend;

import haxe.ds.Map;

class MultiMap<V:Dynamic> {
	private var data:Map<String, Array<V>>;

	public function new() {
		data = new Map<String, Array<V>>();
	}

	public function push(key:String, value:V):Void {
		if (!data.exists(key)) {
			data.set(key, [value]);
		} else {
			data.get(key).push(value);
		}
	}

	public function get(key:String):Array<V> {
		return data.exists(key) ? data.get(key) : [];
	}

	public function remove(key:String):Bool {
		return data.remove(key);
	}
}
