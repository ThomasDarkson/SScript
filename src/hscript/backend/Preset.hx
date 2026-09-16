package hscript.backend;

import haxe.ds.ArraySort;
import hscriptBase.Tools;

enum PresetMode
{
    NONE;
    MINI;
    REGULAR;
    #if (!DISABLED_MACRO_SUPERLATIVE && !python)
    FULL;
    #end
}

@:access(hscript.backend.PresetClasses)
@:access(hscript.SScript)
class Preset
{
    static function preset(script:SScript)
    {
        if (script == null || script._destroyed)
            return;

        var hArray = switch script.presetMode {
            case MINI: PresetClasses.miniHaxe;
            case REGULAR: PresetClasses.regularHaxe;
            #if (!DISABLED_MACRO_SUPERLATIVE && !python)
            case FULL: PresetClasses.fullHaxe;
            #end
            default: [];
        }

        for (i in hArray.copy()) {
            script.setClass(i);
        }
    }
}

class PresetClasses 
{
    static var miniHaxe:Array<Class<Dynamic>> = [
        Date, DateTools, EReg, Math, Reflect, Std, StringTools, Type,
        #if sys Sys, sys.io.File, sys.FileSystem #end
    ];

    static var regularHaxe:Array<Class<Dynamic>> = {
        var array = miniHaxe.copy();
        var array2:Array<Class<Dynamic>> = [List, StringBuf, Xml,
            haxe.Http, haxe.Json, haxe.Log, haxe.Serializer, haxe.Unserializer, haxe.Timer,
            #if sys haxe.SysTools, sys.io.Process, sys.io.FileInput, sys.io.FileOutput #end
        ];

        for (i in array2)
            array.push(i);

        array;
    }

    #if (!DISABLED_MACRO_SUPERLATIVE && !python)
    static var fullHaxe:Array<Class<Dynamic>> = byMap();

    static function byMap():Array<Class<Dynamic>> {
        var classes:Array<Class<Dynamic>> = [];
        @:privateAccess for (i => k in Tools.allClassesAvailable) {
            classes.push(k);
        }

        ArraySort.sort(classes, function(a:Class<Dynamic>, b:Class<Dynamic>):Int {
            var a = Type.getClassName(a).toUpperCase();
            var b = Type.getClassName(b).toUpperCase();

            if (a < b)
                return -1;
            else if (a > b)
                return 1;
            else
                return 0;
        });
        return classes;
    }
    #end
}