package hscript.native;

class NativeRuntimeWriter {
	var strings:Array<String> = [""];
	var types:Array<String> = [""];
	var name:String;
	var base:String;
	var interfaces:Array<String>;
	var specs:Map<String, Dynamic>;
	var cls:Int;

	function sid(s:String):Int {
		var i = strings.indexOf(s);
		if (i < 0) {
			i = strings.length;
			strings.push(s);
		}
		return i;
	}

	function tid(s:String):Int {
		var i = types.indexOf(s);
		if (i < 0) {
			i = types.length;
			types.push(s);
		}
		return i;
	}

	function e(op:String, ?tail:String = ""):String
		return "0 1 " + op + " " + tail + "\n";

	function str(s:String):String
		return e("s", Std.string(sid(s)));

	function variable(id:Int):String
		return e("VAR", Std.string(id));

	function block(items:Array<String>):String
		return e("BLOCK", Std.string(items.length)) + items.join("");

	function field():String
		return e("FTHISINST", cls + " " + sid("__ss_binding"));

	function callBinding(method:String, args:Array<String>):String
		return e("CALLMEMBER", tid("hscript.native.NativeBinding") + " " + sid(method) + " " + args.length) + field() + args.join("");

	function array(items:Array<String>):String
		return e("ADEF", tid("Array.Any") + " " + items.length) + items.join("");

	function element(id:Int, index:Int):String
		return e("ARRAYI", Std.string(tid("Array.Any"))) + variable(id) + e("i", Std.string(index));

	function nativeCall(method:String, args:String):String
		return e("CALLSTATIC", tid("hscript.native.NativeRuntime") + " " + sid("superCall") + " 4")
			+ e("THIS")
			+ str(base)
			+ str(method)
			+ args;

	function ret(type:String, value:String):String
		return type == "void" ? block([value, e("RETURN")]) : e("RETVAL", Std.string(tid(type))) + value;

	function fn(method:String, returnType:String, args:Array<Dynamic>, body:String, isCtor:Bool = false):String {
		var out = "FUNCTION "
			+ (isCtor ? "1" : "0")
			+ " 0 "
			+ sid(method)
			+ " "
			+ tid(isCtor ? name : returnType)
			+ " "
			+ args.length
			+ " ";
		for (i in 0...args.length)
			out += sid("a" + i) + " 0 " + tid(args[i].type) + " ";
		out += "\n" + e("FUN", tid(isCtor ? "void" : returnType) + " " + args.length);
		for (i in 0...args.length)
			out += sid("a" + i) + " " + (i + 1) + " 0 " + tid(args[i].type) + " 0\n";
		return out + body;
	}

	public function new(name:String, base:String, interfaces:Array<String>, specs:Map<String, Dynamic>) {
		this.name = name;
		this.base = base;
		this.interfaces = interfaces;
		this.specs = specs;
		cls = tid(name);
	}

	public function emit():String {
		var fields:Array<String> = [],
			methods:Map<String, Dynamic> = [],
			properties:Map<String, Dynamic> = [];
		var b = base == "" ? null : specs.get(base),
			baseType = base == "" ? 0 : tid(base);
		fields.push("VAR 0 N N 0 " + sid("__ss_binding") + " " + tid("hscript.native.NativeBinding") + " 0\n");
		var ctorBody = [e("SET") + field() + variable(1), callBinding("attach", [e("THIS")])];
		if (b != null) {
			var args:Array<Dynamic> = b.ctor.args;
			ctorBody.push(e("CALLSUPERNEW", baseType + " " + args.length) + [for (i in 0...args.length) element(2, i)].join(""));
			var list:Array<Dynamic> = b.methods;
			for (m in list)
				methods.set(m.name, m);
		}
		fields.push(fn("new", "void", [{type: "hscript.native.NativeBinding"}, {type: "Array.Any"}], block(ctorBody), true));
		for (i in interfaces) {
			var s = specs.get(i),
				list:Array<Dynamic> = s.methods,
				props:Array<Dynamic> = s.properties;
			for (m in list)
				if (!methods.exists(m.name))
					methods.set(m.name, m);
			for (p in props)
				if (b == null || !Reflect.hasField(b.fields, p.name))
					properties.set(p.name, p);
		}
		for (p in properties) {
			fields.push("VAR 0 " + (["get", "default"].indexOf(p.get) >= 0 ? "V" : "n") + " " + (["set", "default"].indexOf(p.set) >= 0 ? "V" : "n") + " 1 "
				+ sid(p.name) + " " + tid(p.type) + " 0\n");
			if (p.get == "default") {
				if (methods.exists("get_" + p.name))
					throw "Native interface data field conflicts with accessor method: " + p.name;

				fields.push(fn("get_" + p.name, "Dynamic", [], ret("Dynamic", callBinding("readField", [str(p.name)]))));
			}
			if (p.set == "default") {
				if (methods.exists("set_" + p.name))
					throw "Native interface data field conflicts with accessor method: " + p.name;
				var value = (p.type == "bool" ? e("CASTBOOL") : "") + variable(1);
				fields.push(fn("set_" + p.name, "Dynamic", [{type: p.type}], ret("Dynamic", callBinding("writeField", [str(p.name), value]))));
			}
		}
		for (m in methods) {
			if (m.sealed)
				continue;
			var args:Array<Dynamic> = m.args, values = [
				for (i in 0...args.length)
					(args[i].type == "bool" ? e("CASTBOOL") : "") + variable(i + 1)
			];
			var callback = ret(m.ret, callBinding("invoke", [str(m.name), array(values)]));
			var fallback = m.base ? ret(m.ret, nativeCall(m.name, array(values))) : e("THROW") + str("Missing script implementation: " + m.name);
			var body = e("IFELSE") + callBinding("has", [str(m.name)]) + callback + fallback;
			fields.push(fn(m.name, m.ret, args, body));
		}
		var superExpr = e("CALLSTATIC", tid("hscript.native.NativeRuntime") + " " + sid("superCall") + " 4")
			+ e("THIS")
			+ str(base)
			+ variable(1)
			+ variable(2);
		fields.push(fn("sscriptSuperCall", "Dynamic", [{type: "String"}, {type: "Array.Any"}], ret("Dynamic", superExpr)));
		var impl = [tid("hscript.native.NativeInstance")];
		for (i in interfaces)
			impl.push(tid(i));
		var body = "CLASS " + cls + " " + baseType + " " + impl.length + " " + impl.join(" ") + "\n" + fields.length + "\n" + fields.join("")
			+ "NOMAIN\nRESOURCES 0\n";
		function table(values:Array<String>):String
			return values.length + "\n" + [for (v in values) haxe.io.Bytes.ofString(v).length + " " + v + "\n"].join("");
		return "CPPIA\n" + table(strings) + table(types) + "1\n" + body;
	}
}
