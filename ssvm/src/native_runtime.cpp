#include <hxcpp.h>
#include "sscript_native_runtime.hpp"
#include "Cppia.h"

namespace hx {extern const char **sgNativeNameSlots;extern int sgNativeNameSlotCount;}

hx::CppiaLoadedModule sscript_native_load(String code,Array<String> methods) {
                                                                                        
                                                              
    static std::vector<std::string> names;
    static std::vector<const char *> slots;
    if(names.empty())for(int i=0;i<hx::sgNativeNameSlotCount;i++)names.push_back(hx::sgNativeNameSlots[i]?hx::sgNativeNameSlots[i]:"");
    for(int m=0;m<methods->length;m++) {
        std::string raw=methods[m].utf8_str();
        for(size_t i=2;i<names.size();i++)if(names[i]=="_hx_"+raw)names[i]=raw;
    }
    slots.resize(names.size());
    for(size_t i=0;i<names.size();i++)slots[i]=i<2?0:names[i].c_str();
    if(!slots.empty())hx::ScriptableRegisterNameSlots(&slots[0],(int)slots.size());
    return __scriptable_cppia_from_string(code);
}

String sscript_native_signature(String type,String name) {
    hx::HaxeNativeClass::link();
    const char *sig=0;
    if(hx::HaxeNativeClass *cls=hx::HaxeNativeClass::findClass(type.utf8_str()))
        sig=name==String("new")?cls->construct.signature:cls->findFunction(name.utf8_str()).signature;
    else if(hx::HaxeNativeInterface *iface=hx::HaxeNativeInterface::findInterface(type.utf8_str()))
        sig=iface->findFunction(name.utf8_str()).signature;
    return sig?String(sig):String();
}

Dynamic sscript_native_super(Dynamic host,String base,String name,Array<Dynamic> args) {
    hx::HaxeNativeClass *cls=hx::HaxeNativeClass::findClass(base.utf8_str());
    if(!cls)hx::Throw(String("Native class has no hxcpp scripting support: ")+base);
    hx::ScriptNamedFunction fn=cls->findFunction(name.utf8_str());
    if(!fn.signature || !fn.superExecute)hx::Throw(String("Native super method is unavailable: ")+base+String(".")+name);
    hx::CppiaCtx *ctx=hx::CppiaCtx::getCurrent();
    hx::AutoStack stack(ctx);
    ctx->pushObject(host);
    for(int i=1;fn.signature[i];i++) {
        Dynamic v=i-1<args->length?args[i-1]:Dynamic();
        switch(fn.signature[i]) {
            case hx::sigBool:ctx->pushInt((bool)v);break;
            case hx::sigInt:ctx->pushInt((int)v);break;
            case hx::sigFloat:ctx->pushFloat((double)v);break;
            case hx::sigString:ctx->pushString((String)v);break;
            case hx::sigObject:ctx->pushObject(v);break;
            default:hx::Throw(String("Unsupported native argument ABI"));
        }
    }
    fn.superExecute(ctx);
    switch(fn.signature[0]) {
        case hx::sigVoid:return null();
        case hx::sigBool:return (bool)ctx->getInt(0);
        case hx::sigInt:return ctx->getInt(0);
        case hx::sigFloat:return ctx->getFloat(0);
        case hx::sigString:return ctx->getString(0);
        case hx::sigObject:return ctx->getObject(0);
        default:hx::Throw(String("Unsupported native return ABI"));return null();
    }
}
