package hscript.backend;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

class SSVMBuild
{
	public static macro function build():Array<Field>
	{
		#if macro
		var fields = Context.getBuildFields();
		if (!Context.defined("cpp"))
			return fields;

		var file = Context.resolvePath("hscript/backend/SSVMBuild.hx");
		file = sys.FileSystem.fullPath(file).split("\\").join("/");
		var parts = file.split("/");
		parts.pop(); // SSVMBuild.hx
		parts.pop(); // backend
		parts.pop(); // hscript
		parts.pop(); // src
		var dir = parts.join("/") + "/ssvm";

		if (!sys.FileSystem.exists(dir + "/include/ssvm.hpp")) {
			Context.warning('SSVM sources not found at "$dir"', Context.currentPos());
			return null;
		}

		var xml = '
<set name="SSVM_DIR" value="$dir"/>
<files id="haxe">
	<compilerflag value="-I$dir/include"/>
</files>
<files id="ssvm">
	<compilerflag value="-I$dir/include"/>
	<compilerflag value="-std=c++11" if="gcc"/>
	<file name="$dir/src/parser.cpp"/>
	<file name="$dir/src/compiler.cpp"/>
	<file name="$dir/src/vm.cpp"/>
	<file name="$dir/src/builtins.cpp"/>
	<file name="$dir/src/bridge.cpp"/>
</files>
<target id="haxe">
	<files id="ssvm"/>
</target>';

		Context.getLocalClass().get().meta.add(":buildXml", [macro $v{xml}], Context.currentPos());
		return fields;
		#else
		return null;
		#end
	}
}
