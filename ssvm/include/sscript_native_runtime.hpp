#ifndef SSCRIPT_NATIVE_RUNTIME_HPP
#define SSCRIPT_NATIVE_RUNTIME_HPP
#ifndef HXCPP_H
#include <hxcpp.h>
#endif
#include <hx/Scriptable.h>
hx::CppiaLoadedModule sscript_native_load(String code,Array<String> methods);
Dynamic sscript_native_super(Dynamic host,String base,String name,Array<Dynamic> args);
String sscript_native_signature(String type,String name);
#endif
