/*
 * Copyright (C)2008-2017 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package hscriptBase;
import hscriptBase.Expr;

#if macro
import haxe.macro.Context;
import haxe.macro.TypeTools;
#end

using StringTools;

@:access(hscriptBase.Interp)
class Tools {
	static final thisName:String = 'hscriptBase.Tools';

	static final keys:Map<String, Bool> = [
		"import" => true, "package" => true, "if" => true, "var" => true, "for" => true, "while" => true, "final" => true, "do" => true,
		"as" => true, "using" => true, "break" => true, "continue" => true, "public" => true, "private" => true, "static" => true,
		"overload" => true, "override" => true, "class" => true, "function" => true, "else" => true, "try" => true, "catch" => true,
		"abstract" => true, "case" => true, "switch" => true, "untyped" => true, "cast" => true, "typedef" => true, "dynamic" => true,
		"default" => true, "enum" => true, "extern" => true, "extends" => true, "implements" => true, "in" => true, "macro" => true,
		"new" => true, "null" => true, "return" => true, "throw" => true, "from" => true, "to" => true, "super" => true, "is" => true,
		"true" => true, "false" => true
	];
	
	public static function resolve( clOrEnum : String ) {
		var cl:Dynamic = Type.resolveClass(clOrEnum);
		if( cl == null ) cl = Type.resolveEnum(clOrEnum);
		return cl;
	}

	public static function ctToType( ct : CType ):String {
		var ctToType:(ct:CType)->String = function(ct)
		{
			return switch (cast(ct, CType)){
				case CTPath(path, params): switch path[0]{
					case 'Null': return ctToType(params[0]);
				} path[0];
				case CTFun(_,_)|CTParent(_):"Function";
				case CTAnon(fields): "Anon";
				default: null;
			}
		};
		return ctToType(ct);
	}

	public static function getType( v , ?fn = false) {
		var getType:(s:Dynamic)->String = function(v){
			return switch(Type.typeof(v)) {
				case TNull: "null";
				case TInt: "Int";
				case TFloat: "Float";
				case TBool: "Bool";  
				case TClass(v): var name = Type.getClassName(v);
				if(fn)return name;
				if(name.contains('.'))
				{
					var split = name.split('.');
					name = split[split.length - 1];
				}
				name;
				case TFunction: "Function";
				default: var string = "" + Type.typeof(v) + ""; string.replace("T","");
			}
		};
		return getType(v);
	}

	public static inline function expr( e : Expr ) : ExprDef {
		return if (e == null) null else e.e;
	}

	public static function isClass(t:Dynamic):Bool
	{
		if( t == null )
			return false;

		var enumIs = Std.isOfType(t, Class);
		#if cpp
		if( enumIs )
			enumIs = !untyped __cpp__("(::hx::Class({0}))->__IsEnum()", t);
		#end
		return enumIs;
	}

	public static function isEnum(t:Dynamic):Bool
	{
		if( t == null )
			return false;

		var enumIs = Std.isOfType(t, Enum);
		#if cpp
		if( enumIs )
			enumIs = untyped __cpp__("(::hx::Class({0}))->__IsEnum()", t);
		#end
		return enumIs;
	}

	public static function classOrEnum(t:Dynamic):String
	{
		if (isClass(t))
			return "class";
		if (isEnum(t))
			return "enum";

		return "object";
	}

	public static function isClassOrEnum(t:Dynamic):Bool
	{
		return isClass(t) || isEnum(t);
	}

	#if (!DISABLED_MACRO_SUPERLATIVE && !python)
    macro static function build() 
    {
        Context.onGenerate(function(types) 
        {
            var names = [], self = TypeTools.getClass(Context.getType(thisName));
                
            for (t in types)
                switch t 
                {
                    case TInst(_.get() => c, _):
                        var name: Array<String> = c.pack.copy();
                        name.push(c.name);
                        names.push(Context.makeExpr(name.join("."), c.pos));
                    default:
                }

            self.meta.remove('classes');
            self.meta.add('classes', names, self.pos);
        });
        return macro cast haxe.rtti.Meta.getType($p{thisName.split('.')});
    }

    #if !macro
    static final allClassesAvailable:Map<String, Class<Dynamic>> = {
        function returnMap()
        {
            var r:Array<String> = build().classes;
            var map = new Map<String, Class<Dynamic>>();

            for (i in r) 
            {
                if (i.indexOf('_Impl_') == -1) // Private class
                {
                    var c = Type.resolveClass(i);
                    if (c != null)
                        map[i] = c;
                }
            }
			
            return map;
        }
        returnMap();
    }
	#end
    #end
}
