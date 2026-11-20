#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include "internal.hpp"

namespace ssvm {

static const int STACK_VALUES = 1024 * 1024;
static const int MAX_FRAMES = 100000;
static const int STACK_MARGIN = 4096;
static const int TICK_QUANTUM = 1024;
static const int MAX_EXEC_DEPTH = 150;


static inline bool ssvmOv_add(int32_t a, int32_t b, int32_t* r) { int64_t x = (int64_t)a + (int64_t)b; *r = (int32_t)x; return x != (int64_t)*r; }
static inline bool ssvmOv_sub(int32_t a, int32_t b, int32_t* r) { int64_t x = (int64_t)a - (int64_t)b; *r = (int32_t)x; return x != (int64_t)*r; }
static inline bool ssvmOv_mul(int32_t a, int32_t b, int32_t* r) { int64_t x = (int64_t)a * (int64_t)b; *r = (int32_t)x; return x != (int64_t)*r; }

struct Abort { std::string msg; };

static double nowMs() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

static inline bool isNum(const Value& v) { return v.t == Type::Int || v.t == Type::Float; }
static inline StrObj* asStr(const Value& v) { return (StrObj*)v.o; }
static inline bool isStrV(const Value& v) { return v.t == Type::Obj && v.o->kind == K::String; }

static bool valuesEqual(const Value& a, const Value& b) {
    if (a.t == Type::Int && b.t == Type::Int) return a.i == b.i;
    if (isNum(a) && isNum(b)) return a.asNumber() == b.asNumber();
    bool an = (a.t == Type::Null || a.t == Type::Undef), bn = (b.t == Type::Null || b.t == Type::Undef);
    if (an || bn) return an && bn;
    if (a.t == Type::Bool && b.t == Type::Bool) return a.b == b.b;
    if (a.t == Type::Obj && b.t == Type::Obj) {
        if (a.o == b.o) return true;
        if (a.o->kind == K::String && b.o->kind == K::String) return asStr(a)->s == asStr(b)->s;
        if (a.o->kind == K::Host && b.o->kind == K::Host) {
            HostObj* ha = (HostObj*)a.o;
            HostObj* hb = (HostObj*)b.o;
            if (ha->cb && ha->cb->equals) return ha->cb->equals(ha->id, hb->id) != 0;
        }
    }
    return false;
}

size_t KeyHash::operator()(const Value& v) const {
    switch (v.t) {
        case Type::Int: return std::hash<int64_t>()(v.i);
        case Type::Float: {
            double d = v.d;
            if (d == std::floor(d) && std::fabs(d) < 2e9) return std::hash<int64_t>()((int64_t)d);
            return std::hash<double>()(d);
        }
        case Type::Bool: return v.b ? 1 : 2;
        case Type::Obj:
            if (v.o->kind == K::String) {
                StrObj* s = (StrObj*)v.o;
                if (!s->hash) {
                    uint32_t h = 2166136261u;
                    for (unsigned char c : s->s) { h ^= c; h *= 16777619u; }
                    s->hash = h ? h : 1;
                }
                return s->hash;
            }
            return std::hash<void*>()(v.o);
        default: return 0;
    }
}
bool KeyEq::operator()(const Value& a, const Value& b) const { return valuesEqual(a, b); }

std::string VM::Impl::fmtFloat(double d) {
    if (std::isnan(d)) return "NaN";
    if (std::isinf(d)) return d > 0 ? "Infinity" : "-Infinity";
    char buf[64];
    snprintf(buf, sizeof buf, "%.15g", d);
    return buf;
}

bool VM::Impl::truthy(Value v) const {
    switch (v.t) {
        case Type::Bool: return v.b;
        case Type::Int: return v.i != 0;
        case Type::Float: return v.d != 0;
        case Type::Obj: return true;
        default: return false;
    }
}

bool VM::Impl::equals(Value a, Value b) { return valuesEqual(a, b); }

std::string VM::Impl::toStr(Value v, int depth) {
    switch (v.t) {
        case Type::Undef: case Type::Null: return "null";
        case Type::Bool: return v.b ? "true" : "false";
        case Type::Int: return std::to_string(v.i);
        case Type::Float: return fmtFloat(v.d);
        case Type::Obj: break;
    }
    if (depth > 12) return "...";
    switch (v.o->kind) {
        case K::String: return asStr(v)->s;
        case K::Array: {
            ArrObj* a = (ArrObj*)v.o;
            std::string s = "[";
            for (size_t i = 0; i < a->v.size(); i++) {
                if (i) s += ",";
                s += toStr(a->v[i], depth + 1);
            }
            return s + "]";
        }
        case K::Map: {
            MapObj* m = (MapObj*)v.o;
            std::string s = "{";
            bool first = true;
            for (auto& e : m->ents) {
                if (!e.alive) continue;
                if (!first) s += ", ";
                first = false;
                s += toStr(e.k, depth + 1) + " => " + toStr(e.v, depth + 1);
            }
            return s + "}";
        }
        case K::Object: {
            ObjObj* o = (ObjObj*)v.o;
            for (auto& f : o->f) {
                if (f.k->sym == S_toString && f.v.t == Type::Obj && (f.v.o->kind == K::Closure || f.v.o->kind == K::Native)) {
                    Value r = callClosureOrNative(f.v, nullptr, 0);
                    return toStr(r, depth + 1);
                }
            }
            std::string s = hxcppStyle ? "[" : "{";
            bool first = true;
            for (auto& f : o->f) {
                if (f.k->sym == S___name) continue;
                if (!first) s += ", ";
                first = false;
                s += f.k->s + (hxcppStyle ? " => " : ": ") + toStr(f.v, depth + 1);
            }
            return s + (hxcppStyle ? "]" : "}");
        }
        case K::Closure: case K::Native: case K::Bound: return "<function>";
        case K::Host: {
            HostObj* h = (HostObj*)v.o;
            if (hcb.toStr) { const char* c = hcb.toStr(h->id); return c ? c : "null"; }
            return "<host>";
        }
        case K::Box: return toStr(((BoxObj*)v.o)->v, depth + 1);
        case K::Iter: return "<iterator>";
        case K::StrBuf: return ((BufObj*)v.o)->s;
        case K::Regex: { RegexObj* r = (RegexObj*)v.o; return "~/" + r->src + "/" + r->flags; }
    }
    return "?";
}

StrObj* VM::Impl::newStr(const std::string& s) {
    StrObj* o = alloc<StrObj>(s.size());
    o->s = s;
    return o;
}
StrObj* VM::Impl::newStr(std::string&& s) {
    size_t n = s.size();
    StrObj* o = alloc<StrObj>(n);
    o->s = std::move(s);
    return o;
}
StrObj* VM::Impl::intern(const std::string& s) {
    auto it = symtab.find(s);
    if (it != symtab.end()) return it->second;
    StrObj* o = new StrObj();
    o->s = s;
    o->perm = true;
    o->sym = (int)syms.size();
    syms.push_back(o);
    symtab.emplace(s, o);
    return o;
}
StrObj* VM::Impl::permStr(const std::string& s) { return intern(s); }

NativeObj* VM::Impl::newNative(const std::string& name, NativeFn fn) {
    NativeObj* n = alloc<NativeObj>(64);
    n->name = name;
    n->fn = std::move(fn);
    return n;
}

int VM::Impl::globalSlot(const std::string& name) {
    auto it = globalIndex.find(name);
    if (it != globalIndex.end()) return it->second;
    int idx = (int)globals.size();
    Value u;
    u.t = Type::Undef;
    globals.push_back(u);
    globalNames.push_back(name);
    globalIndex.emplace(name, idx);
    return idx;
}

void VM::Impl::freeObj(Obj* o) {
    switch (o->kind) {
        case K::String: delete (StrObj*)o; break;
        case K::Array: delete (ArrObj*)o; break;
        case K::Map: delete (MapObj*)o; break;
        case K::Object: delete (ObjObj*)o; break;
        case K::Closure: { ClosureObj* c = (ClosureObj*)o; delete[] c->ups; delete c; break; }
        case K::Native: delete (NativeObj*)o; break;
        case K::Box: delete (BoxObj*)o; break;
        case K::Iter: delete (IterObj*)o; break;
        case K::Bound: delete (BoundObj*)o; break;
        case K::StrBuf: delete (BufObj*)o; break;
        case K::Regex: delete (RegexObj*)o; break;
        case K::Host: { HostObj* h = (HostObj*)o; if (hcb.release) hcb.release(h->id); delete h; break; }
    }
}

void VM::Impl::markObj(Obj* o) {
    if (o->mark || o->perm) return;
    o->mark = true;
    gray.push_back(o);
}
void VM::Impl::markValue(const Value& v) {
    if (v.t == Type::Obj) markObj(v.o);
}

void VM::Impl::drain() {
    while (!gray.empty()) {
        Obj* o = gray.back();
        gray.pop_back();
        switch (o->kind) {
            case K::String: case K::Native: case K::StrBuf: case K::Regex: case K::Host: break;
            case K::Array: for (auto& v : ((ArrObj*)o)->v) markValue(v); break;
            case K::Map: for (auto& e : ((MapObj*)o)->ents) if (e.alive) { markValue(e.k); markValue(e.v); } break;
            case K::Object: for (auto& f : ((ObjObj*)o)->f) markValue(f.v); break;
            case K::Closure: { ClosureObj* c = (ClosureObj*)o; for (int i = 0; i < c->nups; i++) if (c->ups[i]) markObj(c->ups[i]); break; }
            case K::Box: markValue(((BoxObj*)o)->v); break;
            case K::Iter: markValue(((IterObj*)o)->a); markValue(((IterObj*)o)->b); break;
            case K::Bound: markValue(((BoundObj*)o)->self); break;
        }
    }
}

static size_t objSize(Obj* o) {
    switch (o->kind) {
        case K::String: return sizeof(StrObj) + ((StrObj*)o)->s.capacity();
        case K::Array: return sizeof(ArrObj) + ((ArrObj*)o)->v.capacity() * sizeof(Value);
        case K::Map: return sizeof(MapObj) + ((MapObj*)o)->ents.capacity() * (sizeof(MapEnt) + 24);
        case K::Object: return sizeof(ObjObj) + ((ObjObj*)o)->f.capacity() * sizeof(Field);
        case K::Closure: return sizeof(ClosureObj) + ((ClosureObj*)o)->nups * sizeof(void*);
        case K::StrBuf: return sizeof(BufObj) + ((BufObj*)o)->s.capacity();
        case K::Regex: return sizeof(RegexObj) + 256;
        case K::Native: return sizeof(NativeObj) + 64;
        case K::Box: return sizeof(BoxObj);
        case K::Iter: return sizeof(IterObj);
        case K::Bound: return sizeof(BoundObj);
        case K::Host: return sizeof(HostObj) + 64;
    }
    return 32;
}

void VM::Impl::collect() {
    gray.clear();
    for (Value* p = stack; p < sp; ++p) markValue(*p);
    for (auto& g : globals) markValue(g);
    for (auto& p : pinned) markValue(p);
    markValue(tmpResult);
    markValue(hostError);
    markValue(errVal);
    for (auto& r : refs) markValue(r);
    drain();
    Obj** link = &objects;
    size_t live = 0;
    while (*link) {
        Obj* o = *link;
        if (!o->mark) {
            *link = o->next;
            freeObj(o);
        } else {
            o->mark = false;
            live += objSize(o);
            link = &o->next;
        }
    }
    bytes = live;
    nextGC = std::max<size_t>(8u << 20, live * 2);
    gcWant = false;
}

VM::Impl::~Impl() {
    Obj* o = objects;
    while (o) { Obj* n = o->next; freeObj(o); o = n; }
    for (StrObj* s : syms) delete s;
    free(stack);
    free(frames);
}

bool VM::Impl::mapGet(MapObj* m, const Value& k, Value& out) {
    auto it = m->idx.find(k);
    if (it == m->idx.end()) return false;
    out = m->ents[it->second].v;
    return true;
}
void VM::Impl::mapSet(MapObj* m, const Value& k, const Value& v) {
    auto it = m->idx.find(k);
    if (it != m->idx.end()) { m->ents[it->second].v = v; return; }
    if (m->ents.size() > 32 && (size_t)m->live * 2 < m->ents.size()) {
        std::vector<MapEnt> ne;
        ne.reserve(m->live + 8);
        for (auto& e : m->ents) if (e.alive) ne.push_back(e);
        m->ents.swap(ne);
        m->idx.clear();
        for (uint32_t i = 0; i < m->ents.size(); i++) m->idx[m->ents[i].k] = i;
    }
    m->ents.push_back({k, v, true});
    m->idx.emplace(k, (uint32_t)m->ents.size() - 1);
    m->live++;
    noteGrowth(64);
}
bool VM::Impl::mapRemove(MapObj* m, const Value& k) {
    auto it = m->idx.find(k);
    if (it == m->idx.end()) return false;
    MapEnt& e = m->ents[it->second];
    e.alive = false;
    e.v = Value();
    m->idx.erase(it);
    m->live--;
    return true;
}

Value VM::Impl::objGet(ObjObj* o, StrObj* k) {
    for (auto& f : o->f) if (f.k == k) return f.v;
    return Value();
}
void VM::Impl::objSet(ObjObj* o, StrObj* k, Value v) {
    if (k->s == "__ss_access" || k->s == "__ss_parent" || k->s == "__ss_receiver") o->scriptedAccess = true;
    for (auto& f : o->f) if (f.k == k) { f.v = v; return; }
    o->f.push_back({k, v});
    noteGrowth(sizeof(Field));
}

Value VM::Impl::scriptRawGet(ObjObj* o,StrObj* name) {
    for(auto& f:o->f)if(f.k==name)return f.v;
    Value binding=objGet(o,intern("__ss_binding")),arg=Value::Object(name);
    if(binding.t==Type::Obj && binding.o->kind==K::Host && truthy(hostMethod(binding,"hasField",&arg,1)))return hostMethod(binding,"readBase",&arg,1);
    return Value();
}
void VM::Impl::scriptRawSet(ObjObj* o,StrObj* name,Value v) {
    for(auto& f:o->f)if(f.k==name){objSet(o,name,v);return;}
    Value binding=objGet(o,intern("__ss_binding")),arg=Value::Object(name);
    if(binding.t==Type::Obj && binding.o->kind==K::Host && truthy(hostMethod(binding,"hasField",&arg,1))) {
        Value args[]={arg,v};hostMethod(binding,"writeBase",args,2);return;
    }
    objSet(o,name,v);
}

Value VM::Impl::getField(Value obj, StrObj* name, int sym) {
    if(name->s.compare(0,10,"__ss_read_")==0)name=intern("__ss_raw_"+name->s.substr(10));
    else if(name->s.compare(0,11,"__ss_write_")==0)name=intern(name->s.substr(11));
    if (obj.t == Type::Obj) {
        switch (obj.o->kind) {
            case K::Object: {
                ObjObj* o = (ObjObj*)obj.o;
                if (o->scriptedAccess) {
                    Value receiver=objGet(o,intern("__ss_receiver")),fields=objGet(o,intern("__ss_superfields"));
                    if(receiver.t==Type::Obj && receiver.o->kind==K::Object && fields.t==Type::Obj && fields.o->kind==K::Object) {
                        Value prop=objGet((ObjObj*)fields.o,name);
                        if(prop.t==Type::Obj && prop.o->kind==K::Object) {
                            Value mode=objGet((ObjObj*)prop.o,intern("get"));
                            if(!isStrV(mode))fail("Invalid super property metadata");
                            if(asStr(mode)->s=="get")return callClosureOrNative(objGet(o,intern("get_"+name->s)),nullptr,0);
                            if(asStr(mode)->s=="never")fail("Cannot read property '"+name->s+"'");
                            return scriptRawGet((ObjObj*)receiver.o,name);
                        }
                    }
                    if (name->s.compare(0,9,"__ss_raw_")==0) return scriptRawGet(o,intern(name->s.substr(9)));
                    Value access=objGet(o,intern("__ss_access"));
                    if(access.t==Type::Obj && access.o->kind==K::Object) {
                        Value prop=objGet((ObjObj*)access.o,name);
                        if(prop.t==Type::Obj && prop.o->kind==K::Object) {
                            Value mode=objGet((ObjObj*)prop.o,intern("get"));
                            if(mode.t==Type::Obj && mode.o->kind==K::String) {
                                std::string m=asStr(mode)->s;
                                if(m=="get") return callClosureOrNative(objGet(o,intern("get_"+name->s)),nullptr,0);
                                if(m=="null" || m=="never") fail("Cannot read property '"+name->s+"'");
                            }
                        }
                    }
                }
                for (auto& f : o->f) if (f.k == name) return f.v;
                Value parent=objGet(o,intern("__ss_parent"));
                if(parent.t==Type::Obj && (parent.o->kind==K::Object||parent.o->kind==K::Host))return getField(parent,name,sym);
                Value host=objGet(o,intern("__ss_host"));if(host.t==Type::Obj && host.o->kind==K::Host)return hostGet(host,name);
                return Value();
            }
            case K::Array:
                if (sym == S_length) return Value::Int((int32_t)((ArrObj*)obj.o)->v.size());
                break;
            case K::String:
                if (sym == S_length) return Value::Int((int32_t)asStr(obj)->s.size());
                break;
            case K::Map:
                if (sym == S_length || sym == S_size) return Value::Int((int32_t)((MapObj*)obj.o)->live);
                break;
            case K::StrBuf:
                if (sym == S_length) return Value::Int((int32_t)((BufObj*)obj.o)->s.size());
                break;
            case K::Regex: case K::Iter: break;
            case K::Host: return hostGet(obj, name);
            default: fail("Cannot access field '" + name->s + "' of a function value");
        }
        if (sym >= 0 && sym < S__COUNT) {
            BoundObj* b = alloc<BoundObj>();
            b->self = obj;
            b->sym = sym;
            return Value::Object(b);
        }
        fail("Type has no field '" + name->s + "'");
    }
    if (obj.t == Type::Null || obj.t == Type::Undef) fail("Null Object Reference (accessing field '" + name->s + "')");
    fail("Cannot access field '" + name->s + "' of " + std::string(obj.t == Type::Int ? "Int" : obj.t == Type::Float ? "Float" : "Bool"));
}

void VM::Impl::setField(Value obj, StrObj* name, Value v) {
    if(name->s.compare(0,11,"__ss_write_")==0)name=intern("__ss_raw_"+name->s.substr(11));
    else if(name->s.compare(0,10,"__ss_read_")==0)name=intern(name->s.substr(10));
    if (obj.t == Type::Obj && obj.o->kind == K::Object) {
        ObjObj* o=(ObjObj*)obj.o;
        if(o->scriptedAccess) {
            Value receiver=objGet(o,intern("__ss_receiver")),fields=objGet(o,intern("__ss_superfields"));
            if(receiver.t==Type::Obj && receiver.o->kind==K::Object && fields.t==Type::Obj && fields.o->kind==K::Object) {
                Value prop=objGet((ObjObj*)fields.o,name);
                if(prop.t==Type::Obj && prop.o->kind==K::Object) {
                    Value mode=objGet((ObjObj*)prop.o,intern("set"));
                    if(!isStrV(mode))fail("Invalid super property metadata");
                    if(asStr(mode)->s=="set"){callClosureOrNative(objGet(o,intern("set_"+name->s)),&v,1);return;}
                    if(asStr(mode)->s=="never")fail("Cannot write property '"+name->s+"'");
                    scriptRawSet((ObjObj*)receiver.o,name,v);return;
                }
            }
            if(name->s.compare(0,9,"__ss_raw_")==0) {scriptRawSet(o,intern(name->s.substr(9)),v);return;}
            Value access=objGet(o,intern("__ss_access"));
            if(access.t==Type::Obj && access.o->kind==K::Object) {
                Value prop=objGet((ObjObj*)access.o,name);
                if(prop.t==Type::Obj && prop.o->kind==K::Object) {
                    Value mode=objGet((ObjObj*)prop.o,intern("set"));
                    if(mode.t==Type::Obj && mode.o->kind==K::String) {
                        std::string m=asStr(mode)->s;
                        if(m=="set") {callClosureOrNative(objGet(o,intern("set_"+name->s)),&v,1);return;}
                        if(m=="null" || m=="never") fail("Cannot write property '"+name->s+"'");
                    }
                }
            }
        }
        Value parent=objGet(o,intern("__ss_parent"));
        bool own=false;for(auto& f:o->f)if(f.k==name){own=true;break;}
        if(!own && name->s.compare(0,5,"__ss_")!=0 && parent.t==Type::Obj && (parent.o->kind==K::Object||parent.o->kind==K::Host)){setField(parent,name,v);return;}
        scriptRawSet(o,name,v);return;
    }
    if (obj.t == Type::Obj && obj.o->kind == K::Host) { hostSet(obj, name, v); return; }
    if (obj.t == Type::Null) fail("Null Object Reference (setting field '" + name->s + "')");
    fail("Cannot set field '" + name->s + "' on this value");
}

static inline bool toIndex(const Value& idx, int64_t& out) {
    if (idx.t == Type::Int) { out = idx.i; return true; }
    if (idx.t == Type::Float && idx.d == std::floor(idx.d) && std::fabs(idx.d) < 2e9) { out = (int64_t)idx.d; return true; }
    return false;
}

Value VM::Impl::getIndex(Value obj, Value idx) {
    if (obj.t == Type::Obj) {
        switch (obj.o->kind) {
            case K::Array: {
                int64_t i;
                if (!toIndex(idx, i)) fail("Array index must be an Int");
                ArrObj* a = (ArrObj*)obj.o;
                if (i < 0 || i >= (int64_t)a->v.size()) return Value();
                return a->v[(size_t)i];
            }
            case K::Map: {
                Value out;
                mapGet((MapObj*)obj.o, idx, out);
                return out;
            }
            case K::Object:
                if (isStrV(idx)) return getField(obj, intern(asStr(idx)->s), intern(asStr(idx)->s)->sym);
                break;
            case K::String: {
                int64_t i;
                if (!toIndex(idx, i)) fail("String index must be an Int");
                StrObj* s = asStr(obj);
                if (i < 0 || i >= (int64_t)s->s.size()) return Value();
                return strv(std::string(1, s->s[(size_t)i]));
            }
            case K::Host: return hostGetIdx(obj, idx);
            default: break;
        }
        fail("Value cannot be indexed");
    }
    if (obj.t == Type::Null) fail("Null Object Reference (indexing)");
    fail("Value cannot be indexed");
}

void VM::Impl::setIndex(Value obj, Value idx, Value v) {
    if (obj.t == Type::Obj) {
        switch (obj.o->kind) {
            case K::Array: {
                int64_t i;
                if (!toIndex(idx, i)) fail("Array index must be an Int");
                ArrObj* a = (ArrObj*)obj.o;
                if (i < 0) fail("Negative array index");
                if (i >= (int64_t)a->v.size()) {
                    if (i > 100000000) fail("Array index too large");
                    noteGrowth(((size_t)i + 1 - a->v.size()) * sizeof(Value));
                    a->v.resize((size_t)i + 1);
                }
                a->v[(size_t)i] = v;
                return;
            }
            case K::Map: mapSet((MapObj*)obj.o, idx, v); return;
            case K::Object:
                if (isStrV(idx)) { setField(obj, intern(asStr(idx)->s), v); return; }
                break;
            case K::Host: hostSetIdx(obj, idx, v); return;
            default: break;
        }
        fail("Value cannot be indexed for assignment");
    }
    if (obj.t == Type::Null) fail("Null Object Reference (indexing)");
    fail("Value cannot be indexed for assignment");
}

Value VM::Impl::makeIterator(Value src, bool kv) {
    if (src.t != Type::Obj) {
        if (src.t == Type::Null) fail("Null Object Reference (iterating)");
        fail("Value is not iterable");
    }
    switch (src.o->kind) {
        case K::Iter: return src;
        case K::Array: { IterObj* it = newIter(IT_ARRAY); it->a = src; return Value::Object(it); }
        case K::Map: { IterObj* it = newIter(IT_MAPVALS); it->a = src; return Value::Object(it); }
        case K::String: { IterObj* it = newIter(IT_STRING); it->a = src; return Value::Object(it); }
        case K::Object: {
            ObjObj* o = (ObjObj*)src.o;
            Value f = objGet(o, syms[S_iterator]);
            if (f.t == Type::Obj && (f.o->kind == K::Closure || f.o->kind == K::Native)) {
                Value r = callClosureOrNative(f, nullptr, 0);
                return makeIterator(r);
            }
            Value hn = objGet(o, syms[S_hasNext]);
            Value nx = objGet(o, syms[S_next]);
            if (hn.t == Type::Obj && nx.t == Type::Obj) { IterObj* it = newIter(IT_CUSTOM); it->a = src; return Value::Object(it); }
            fail("Object is not iterable");
        }
        case K::Host: {
            Value it = hostMethod(src, kv ? "keyValueIterator" : "iterator", nullptr, 0);
            if (it.t == Type::Obj && it.o->kind == K::Host) {
                IterObj* io = newIter(IT_HOST);
                io->a = it;
                return Value::Object(io);
            }
            return makeIterator(it, false);
        }
        default: break;
    }
    fail("Value is not iterable");
}

static void skipDead(MapObj* m, int32_t& i) {
    while ((size_t)i < m->ents.size() && !m->ents[(size_t)i].alive) i++;
}

bool VM::Impl::iterNext(IterObj* it, Value& out) {
    switch (it->type) {
        case IT_ARRAY: {
            ArrObj* a = (ArrObj*)it->a.o;
            if ((size_t)it->i < a->v.size()) { out = a->v[(size_t)it->i++]; return true; }
            return false;
        }
        case IT_MAPKEYS: case IT_MAPVALS: case IT_MAPKV: {
            MapObj* m = (MapObj*)it->a.o;
            skipDead(m, it->i);
            if ((size_t)it->i >= m->ents.size()) return false;
            MapEnt& e = m->ents[(size_t)it->i++];
            out = (it->type == IT_MAPKEYS) ? e.k : e.v;
            return true;
        }
        case IT_RANGE:
            if (it->i < it->n) { out = Value::Int(it->i++); return true; }
            return false;
        case IT_STRING: {
            StrObj* s = asStr(it->a);
            if ((size_t)it->i < s->s.size()) { out = strv(std::string(1, s->s[(size_t)it->i++])); return true; }
            return false;
        }
        case IT_CUSTOM: {
            ObjObj* o = (ObjObj*)it->a.o;
            Value hn = objGet(o, syms[S_hasNext]);
            Value r = callClosureOrNative(hn, nullptr, 0);
            if (!truthy(r)) return false;
            out = callClosureOrNative(objGet(o, syms[S_next]), nullptr, 0);
            return true;
        }
        case IT_HOST: {
            Value r = hostMethod(it->a, "hasNext", nullptr, 0);
            if (!truthy(r)) return false;
            out = hostMethod(it->a, "next", nullptr, 0);
            return true;
        }
    }
    return false;
}

bool VM::Impl::iterNext2(IterObj* it, Value& k, Value& v) {
    switch (it->type) {
        case IT_MAPKEYS: case IT_MAPVALS: case IT_MAPKV: {
            MapObj* m = (MapObj*)it->a.o;
            skipDead(m, it->i);
            if ((size_t)it->i >= m->ents.size()) return false;
            MapEnt& e = m->ents[(size_t)it->i++];
            k = e.k;
            v = e.v;
            return true;
        }
        case IT_ARRAY: {
            int32_t idx = it->i;
            if (!iterNext(it, v)) return false;
            k = Value::Int(idx);
            return true;
        }
        case IT_HOST: {
            Value e;
            if (!iterNext(it, e)) return false;
            if (e.t == Type::Obj && e.o->kind == K::Host) {
                k = hostGet(e, intern("key"));
                v = hostGet(e, intern("value"));
            } else if (e.t == Type::Obj && e.o->kind == K::Object) {
                k = objGet((ObjObj*)e.o, intern("key"));
                v = objGet((ObjObj*)e.o, intern("value"));
            } else {
                k = Value::Int(it->i++);
                v = e;
            }
            return true;
        }
        default: {
            int32_t idx = it->i;
            if (!iterNext(it, v)) return false;
            k = Value::Int(idx);
            return true;
        }
    }
}

std::string VM::Impl::currentPos() {
    if (nf <= 0) return "SScript:0";
    Frame& f = frames[nf - 1];
    return f.p->origin + ":" + std::to_string(f.p->lineAt(f.pc - 1));
}

void VM::Impl::slowTick(int consumed) {
    ticks += (uint64_t)consumed;
    if (tickLimit && ticks > tickLimit) throw Abort{currentPos() + ": Script exceeded its tick limit (possible infinite loop)"};
    if (timeLimitMs > 0 && nowMs() - startTime > timeLimitMs) throw Abort{currentPos() + ": Script exceeded its time limit"};
    if (bytes > nextGC) collect();
}

Value VM::Impl::callClosureOrNative(Value fn, const Value* args, int argc) {
    if (execDepth >= MAX_EXEC_DEPTH) fail("Stack overflow");
    if (sp + argc + 16 > stackEnd - STACK_MARGIN) fail("Stack overflow");
    Value* s0 = sp;
    *sp++ = fn;
    for (int i = 0; i < argc; i++) *sp++ = args[i];
    Value result;
    if (fn.t != Type::Obj) { sp = s0; fail("Cannot call a non-function value"); }
    switch (fn.o->kind) {
        case K::Closure: {
            ClosureObj* c = (ClosureObj*)fn.o;
            Proto* p = c->p;
            if (argc < p->minArgs) { sp = s0; fail("Not enough arguments, expected " + p->paramNames[(size_t)(p->minArgs - 1)]); }
            if (argc > p->nparams) { sp = s0; fail("Too many arguments"); }
            Value* nb = s0 + 1;
            for (int k = argc; k < p->nlocals; k++) nb[k] = Value();
            if (nb + p->nlocals + STACK_MARGIN > stackEnd || nf >= maxFrames) { sp = s0; fail("Stack overflow"); }
            int entryNf = nf;
            frames[nf++] = Frame{p, c, nb, p->code.data() + p->entry};
            sp = nb + p->nlocals;
            execDepth++;
            try {
                result = execute(entryNf);
            } catch (...) {
                execDepth--;
                sp = s0;
                throw;
            }
            execDepth--;
            break;
        }
        case K::Native: {
            NativeObj* nat = (NativeObj*)fn.o;
            execDepth++;
            try { result = nat->fn(*vm, s0 + 1, argc); } catch (...) { execDepth--; sp = s0; throw; }
            execDepth--;
            break;
        }
        case K::Bound: {
            BoundObj* b = (BoundObj*)fn.o;
            execDepth++;
            try { result = callMethodByName(b->self, b->sym, s0 + 1, argc); } catch (...) { execDepth--; sp = s0; throw; }
            execDepth--;
            break;
        }
        case K::Host: {
            execDepth++;
            try { result = hostCall(fn, s0 + 1, argc); } catch (...) { execDepth--; sp = s0; throw; }
            execDepth--;
            break;
        }
        default: sp = s0; fail("Cannot call a non-function value");
    }
    sp = s0;
    return result;
}

#if (defined(__GNUC__) || defined(__clang__)) && !defined(SSVM_NO_COMPUTED_GOTO)
#define SSVM_COMPUTED_GOTO 1
#endif

#define SYNC() do { this->sp = sp; fr->pc = pc; } while (0)
#define FAILX(...) do { SYNC(); fail(__VA_ARGS__); } while (0)
#define LOAD_FRAME() do { fr = &frames[nf - 1]; base = fr->base; cl = fr->cl; code = fr->p->code.data(); consts = fr->p->consts.data(); pc = fr->pc; } while (0)

#ifdef SSVM_COMPUTED_GOTO
#define CASE(n) L_##n:
#define NEXT() do { ins = pc++; goto *tbl[ins->op]; } while (0)
#define DISPATCH_BEGIN NEXT();
#define DISPATCH_END
#else
#define CASE(n) case OP_##n:
#define NEXT() continue
#define DISPATCH_BEGIN for (;;) { ins = pc++; switch (ins->op) {
#define DISPATCH_END default: fail("Invalid opcode"); } }
#endif

static std::string typeName(const Value& v) {
    switch (v.t) {
        case Type::Int: return "Int";
        case Type::Float: return "Float";
        case Type::Bool: return "Bool";
        case Type::Null: case Type::Undef: return "null";
        case Type::Obj:
            switch (v.o->kind) {
                case K::String: return "String";
                case K::Array: return "Array";
                case K::Map: return "Map";
                case K::Object: return "Object";
                case K::Host: return "Object";
                default: return "Function";
            }
    }
    return "?";
}

Value VM::Impl::concatN(Value* start, int n) {
    std::string s;
    for (int i = 0; i < n; i++) {
        const Value& v = start[i];
        if (isStrV(v)) s += asStr(v)->s;
        else s += toStr(v);
    }
    return Value::Object(newStr(std::move(s)));
}

Value VM::Impl::addSlow(Value a, Value b) {
    if (isStrV(a) || isStrV(b)) {
        std::string s;
        const std::string* pa = isStrV(a) ? &asStr(a)->s : nullptr;
        std::string ta, tb;
        if (!pa) { ta = toStr(a); pa = &ta; }
        const std::string* pb = isStrV(b) ? &asStr(b)->s : nullptr;
        if (!pb) { tb = toStr(b); pb = &tb; }
        s.reserve(pa->size() + pb->size());
        s += *pa;
        s += *pb;
        return Value::Object(newStr(std::move(s)));
    }
    fail("Invalid operation: " + typeName(a) + " + " + typeName(b));
}

Value VM::Impl::runLoop(int entryNf) {
#ifdef SSVM_COMPUTED_GOTO
    static const void* const tbl[] = {
#define X(n) &&L_##n,
        SSVM_OPS(X)
#undef X
    };
#endif
    Frame* fr = nullptr;
    Value* base = nullptr;
    ClosureObj* cl = nullptr;
    const Ins* code = nullptr;
    Value* consts = nullptr;
    const Ins* pc = nullptr;
    const Ins* ins = nullptr;
    Value* sp = this->sp;
    int budget = TICK_QUANTUM;

    LOAD_FRAME();
    ins = pc;
    (void)ins;
    DISPATCH_BEGIN

    CASE(NOP) { NEXT(); }
    CASE(NULL_) { *sp++ = Value(); NEXT(); }
    CASE(TRUE_) { *sp++ = Value::Bool(true); NEXT(); }
    CASE(FALSE_) { *sp++ = Value::Bool(false); NEXT(); }
    CASE(INT) { *sp++ = Value::Int(ins->a); NEXT(); }
    CASE(CONST) { *sp++ = consts[ins->a]; NEXT(); }
    CASE(POP) { --sp; NEXT(); }
    CASE(DUP) { sp[0] = sp[-1]; sp++; NEXT(); }
    CASE(DUP2) { sp[0] = sp[-2]; sp[1] = sp[-1]; sp += 2; NEXT(); }
    CASE(SWAP) { Value t = sp[-1]; sp[-1] = sp[-2]; sp[-2] = t; NEXT(); }

    CASE(LOCAL) { *sp++ = base[ins->a]; NEXT(); }
    CASE(SETLOCAL) { base[ins->a] = sp[-1]; NEXT(); }
    CASE(SETLOCALP) { base[ins->a] = *--sp; NEXT(); }
    CASE(BOXGET) { *sp++ = ((BoxObj*)base[ins->a].o)->v; NEXT(); }
    CASE(BOXSET) { ((BoxObj*)base[ins->a].o)->v = sp[-1]; NEXT(); }
    CASE(BOXSETP) { ((BoxObj*)base[ins->a].o)->v = *--sp; NEXT(); }
    CASE(BOXNEW) {
        BoxObj* b = alloc<BoxObj>();
        b->v = *--sp;
        base[ins->a] = Value::Object(b);
        NEXT();
    }
    CASE(BOXPARAMS) {
        uint32_t mask = (uint32_t)ins->a;
        for (int s = 0; s < 32; s++) {
            if (mask & (1u << s)) {
                BoxObj* b = alloc<BoxObj>();
                b->v = base[s];
                base[s] = Value::Object(b);
            }
        }
        NEXT();
    }
    CASE(UPGET) { *sp++ = cl->ups[ins->a]->v; NEXT(); }
    CASE(UPSET) { cl->ups[ins->a]->v = sp[-1]; NEXT(); }
    CASE(UPSETP) { cl->ups[ins->a]->v = *--sp; NEXT(); }
    CASE(GGET) {
        const Value& g = globals[(size_t)ins->a];
        if (g.t == Type::Undef) FAILX("Unknown variable " + globalNames[(size_t)ins->a]);
        *sp++ = g;
        NEXT();
    }
    CASE(GSET) {
        Value& g = globals[(size_t)ins->a];
        if (g.t == Type::Undef) FAILX("Unknown variable " + globalNames[(size_t)ins->a]);
        g = sp[-1];
        NEXT();
    }
    CASE(GSETP) {
        Value& g = globals[(size_t)ins->a];
        if (g.t == Type::Undef) FAILX("Unknown variable " + globalNames[(size_t)ins->a]);
        g = *--sp;
        NEXT();
    }
    CASE(GDEF) { globals[(size_t)ins->a] = *--sp; NEXT(); }

    CASE(ADD) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        if (a.t == Type::Int && b.t == Type::Int) { int32_t r; if (ssvmOv_add(a.i, b.i, &r)) a = Value::Float((double)a.i + (double)b.i); else a.i = r; --sp; NEXT(); }
        if (isNum(a) && isNum(b)) { a = Value::Float(a.asNumber() + b.asNumber()); --sp; NEXT(); }
        SYNC();
        a = addSlow(a, b);
        --sp;
        NEXT();
                FAILX("Invalid operation: " + typeName(a) + " + " + typeName(b));
    }
    CASE(SUB) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        if (a.t == Type::Int && b.t == Type::Int) { int32_t r; if (ssvmOv_sub(a.i, b.i, &r)) a = Value::Float((double)a.i - (double)b.i); else a.i = r; --sp; NEXT(); }
        if (isNum(a) && isNum(b)) { a = Value::Float(a.asNumber() - b.asNumber()); --sp; NEXT(); }
        FAILX("Invalid operation: " + typeName(a) + " - " + typeName(b));
    }
    CASE(MUL) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        if (a.t == Type::Int && b.t == Type::Int) { int32_t r; if (ssvmOv_mul(a.i, b.i, &r)) a = Value::Float((double)a.i * (double)b.i); else a.i = r; --sp; NEXT(); }
        if (isNum(a) && isNum(b)) { a = Value::Float(a.asNumber() * b.asNumber()); --sp; NEXT(); }
        FAILX("Invalid operation: " + typeName(a) + " * " + typeName(b));
    }
    CASE(DIV) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        if (isNum(a) && isNum(b)) { a = Value::Float(a.asNumber() / b.asNumber()); --sp; NEXT(); }
        FAILX("Invalid operation: " + typeName(a) + " / " + typeName(b));
    }
    CASE(MOD) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        if (a.t == Type::Int && b.t == Type::Int) {
            if (b.i == 0) a = Value::Float(std::nan(""));
            else if (b.i == -1) a = Value::Int(0);
            else a.i = a.i % b.i;
            --sp;
            NEXT();
        }
        if (isNum(a) && isNum(b)) { a = Value::Float(std::fmod(a.asNumber(), b.asNumber())); --sp; NEXT(); }
        FAILX("Invalid operation: " + typeName(a) + " % " + typeName(b));
    }
#define BITOP(NAME, EXPR)                                                                   \
    CASE(NAME) {                                                                    \
        Value& a = sp[-2];                                                          \
        Value& b = sp[-1];                                                          \
        if (a.t != Type::Int || b.t != Type::Int) {                                 \
            if (!(isNum(a) && isNum(b))) FAILX("Invalid operation: " + typeName(a) + " bitwise " + typeName(b)); \
        }                                                                           \
        int32_t x = a.t == Type::Int ? a.i : toInt32(a.d);                        \
        int32_t y = b.t == Type::Int ? b.i : toInt32(b.d);                        \
        (void)x; (void)y;                                                           \
        a = Value::Int(EXPR);                                                       \
        --sp;                                                                       \
        NEXT();                                                                     \
    }
    BITOP(BAND, x & y)
    BITOP(BOR, x | y)
    BITOP(BXOR, x ^ y)
    BITOP(SHL, (int32_t)((uint32_t)x << (y & 31)))
    BITOP(SHR, x >> (y & 31))
    BITOP(USHR, (int32_t)((uint32_t)x >> (y & 31)))
#undef BITOP

    CASE(EQ) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        bool r = (a.t == Type::Int && b.t == Type::Int) ? (a.i == b.i) : valuesEqual(a, b);
        --sp;
        sp[-1] = Value::Bool(r);
        NEXT();
    }
    CASE(NE) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        bool r = (a.t == Type::Int && b.t == Type::Int) ? (a.i != b.i) : !valuesEqual(a, b);
        --sp;
        sp[-1] = Value::Bool(r);
        NEXT();
    }
#define CMPOP(NAME, OPR, SYMBOL)                                                            \
    CASE(NAME) {                                                                    \
        Value& a = sp[-2];                                                          \
        Value& b = sp[-1];                                                          \
        bool r;                                                                     \
        if (a.t == Type::Int && b.t == Type::Int) r = a.i OPR b.i;                  \
        else if (isNum(a) && isNum(b)) r = a.asNumber() OPR b.asNumber();           \
        else if (isStrV(a) && isStrV(b)) r = asStr(a)->s.compare(asStr(b)->s) OPR 0;\
        else FAILX("Invalid comparison: " + typeName(a) + " " SYMBOL " " + typeName(b)); \
        --sp;                                                                       \
        sp[-1] = Value::Bool(r);                                                    \
        NEXT();                                                                     \
    }
    CMPOP(LT, <, "<")
    CMPOP(LE, <=, "<=")
    CMPOP(GT, >, ">")
    CMPOP(GE, >=, ">=")
#undef CMPOP
    CASE(NOT) { sp[-1] = Value::Bool(!truthy(sp[-1])); NEXT(); }
    CASE(NEG) {
        Value& a = sp[-1];
        if (a.t == Type::Int) { if (a.i == INT32_MIN) a = Value::Float(-(double)a.i); else a.i = -a.i; }
        else if (a.t == Type::Float) a.d = -a.d;
        else FAILX("Invalid operation: -" + typeName(a));
        NEXT();
    }
    CASE(BNOT) {
        Value& a = sp[-1];
        if (a.t == Type::Int) a.i = ~a.i;
        else if (a.t == Type::Float) a = Value::Int(~toInt32(a.d));
        else FAILX("Invalid operation: ~" + typeName(a));
        NEXT();
    }
    CASE(TOBOOL) { sp[-1] = Value::Bool(truthy(sp[-1])); NEXT(); }

    CASE(JMP) { pc = code + ins->a; NEXT(); }
    CASE(LOOP) {
        pc = code + ins->a;
        if (--budget <= 0 || gcWant) { SYNC(); slowTick(TICK_QUANTUM - (budget > 0 ? budget : 0)); budget = TICK_QUANTUM; }
        NEXT();
    }
    CASE(JMPF) {
        Value v = *--sp;
        bool t = (v.t == Type::Bool) ? v.b : truthy(v);
        if (!t) pc = code + ins->a;
        NEXT();
    }
    CASE(JMPT) {
        Value v = *--sp;
        bool t = (v.t == Type::Bool) ? v.b : truthy(v);
        if (t) pc = code + ins->a;
        NEXT();
    }
    CASE(JMPNN) {
        if (sp[-1].t != Type::Null) pc = code + ins->a;
        else --sp;
        NEXT();
    }
    CASE(JMPNULL) {
        if (sp[-1].t == Type::Null) pc = code + ins->a;
        NEXT();
    }

    CASE(GETF) {
        StrObj* name = syms[(size_t)ins->a];
        Value& o = sp[-1];
        if (o.t == Type::Obj) {
            K kd = o.o->kind;
            if (kd == K::Object && !((ObjObj*)o.o)->scriptedAccess) {
                ObjObj* ob = (ObjObj*)o.o;
                Value r;
                size_t n = ob->f.size(), h = ins->x;
                if (h < n && ob->f[h].k == name) r = ob->f[h].v;
                else {
                    for (size_t i = 0; i < n; i++) if (ob->f[i].k == name) { r = ob->f[i].v; if (i < 255) const_cast<Ins*>(ins)->x = (uint8_t)i; break; }
                }
                o = r;
                NEXT();
            }
            if (ins->a == S_length) {
                if (kd == K::Array) { o = Value::Int((int32_t)((ArrObj*)o.o)->v.size()); NEXT(); }
                if (kd == K::String) { o = Value::Int((int32_t)asStr(o)->s.size()); NEXT(); }
            }
        }
        SYNC();
        o = getField(o, name, ins->a);
        NEXT();
    }
    CASE(SETF) {
        Value v = sp[-1];
        Value o = sp[-2];
        SYNC();
        setField(o, syms[(size_t)ins->a], v);
        sp[-2] = v;
        --sp;
        NEXT();
    }
    CASE(GETI) {
        Value& o = sp[-2];
        Value& i = sp[-1];
        if (o.t == Type::Obj && o.o->kind == K::Array && i.t == Type::Int) {
            ArrObj* a = (ArrObj*)o.o;
            Value r;
            if ((uint32_t)i.i < a->v.size()) r = a->v[(size_t)i.i];
            --sp;
            sp[-1] = r;
            NEXT();
        }
        SYNC();
        Value r = getIndex(o, i);
        --sp;
        sp[-1] = r;
        NEXT();
    }
    CASE(SETI) {
        Value v = sp[-1];
        Value i = sp[-2];
        Value o = sp[-3];
        if (o.t == Type::Obj && o.o->kind == K::Array && i.t == Type::Int) {
            ArrObj* a = (ArrObj*)o.o;
            if ((uint32_t)i.i < a->v.size()) {
                a->v[(size_t)i.i] = v;
                sp -= 2;
                sp[-1] = v;
                NEXT();
            }
        }
        SYNC();
        setIndex(o, i, v);
        sp -= 2;
        sp[-1] = v;
        NEXT();
    }

    CASE(CALLM) {
        int argc = ins->b;
        Value* recv = sp - argc - 1;
        if (recv->t == Type::Obj) {
            K kd = recv->o->kind;
            if (kd == K::Object) {
                ObjObj* ob = (ObjObj*)recv->o;
                StrObj* name = syms[(size_t)ins->a];
                if(ob->scriptedAccess) {
                    SYNC();Value f=getField(*recv,name,ins->a);*recv=f;goto do_call;
                }
                Value f;
                bool found = false;
                size_t n = ob->f.size(), h = ins->x;
                if (h < n && ob->f[h].k == name) { f = ob->f[h].v; found = true; }
                else {
                    for (size_t i = 0; i < n; i++) if (ob->f[i].k == name) { f = ob->f[i].v; found = true; if (i < 255) const_cast<Ins*>(ins)->x = (uint8_t)i; break; }
                }
                if (!found || f.t != Type::Obj) FAILX("Object has no method '" + name->s + "'");
                *recv = f;
                goto do_call;
            }
            if (kd == K::Array) {
                ArrObj* ar = (ArrObj*)recv->o;
                if (ins->a == S_push && argc == 1) {
                    size_t cb = ar->v.capacity();
                    ar->v.push_back(recv[1]);
                    if (ar->v.capacity() > cb) noteGrowth((ar->v.capacity() - cb) * sizeof(Value));
                    *recv = Value::Int((int32_t)ar->v.size());
                    sp = recv + 1;
                    NEXT();
                }
                if (ins->a == S_pop && argc == 0) {
                    Value r;
                    if (!ar->v.empty()) { r = ar->v.back(); ar->v.pop_back(); }
                    *recv = r;
                    sp = recv + 1;
                    NEXT();
                }
            } else if (kd == K::String) {
                if (ins->a == S_charCodeAt && argc == 1 && recv[1].t == Type::Int) {
                    const std::string& str = asStr(*recv)->s;
                    Value r;
                    if ((uint32_t)recv[1].i < str.size()) r = Value::Int((unsigned char)str[(size_t)recv[1].i]);
                    *recv = r;
                    sp = recv + 1;
                    NEXT();
                }
            } else if (kd == K::Map) {
                MapObj* mp = (MapObj*)recv->o;
                if (ins->a == S_get && argc == 1) {
                    Value out;
                    mapGet(mp, recv[1], out);
                    *recv = out;
                    sp = recv + 1;
                    NEXT();
                }
                if (ins->a == S_exists && argc == 1) {
                    Value out;
                    *recv = Value::Bool(mapGet(mp, recv[1], out));
                    sp = recv + 1;
                    NEXT();
                }
            }
            SYNC();
            Value r = callMethodByName(*recv, ins->a, recv + 1, argc);
            sp = recv;
            *sp++ = r;
            NEXT();
        }
        if (recv->t == Type::Null) FAILX("Null Object Reference (calling '" + syms[(size_t)ins->a]->s + "')");
        FAILX("Cannot call method '" + syms[(size_t)ins->a]->s + "' on " + typeName(*recv));
    }
    CASE(CALL) {
        goto do_call;
    }
    do_call:
    {
        int argc = ins->b;
        Value* fv = sp - argc - 1;
        if (fv->t != Type::Obj) FAILX("Cannot call a non-function value (" + typeName(*fv) + ")");
        switch (fv->o->kind) {
            case K::Closure: {
                ClosureObj* c = (ClosureObj*)fv->o;
                Proto* p = c->p;
                if (argc != p->nparams) {
                    if (argc < p->minArgs) FAILX("Not enough arguments, expected " + p->paramNames[(size_t)(p->minArgs - 1)]);
                    if (argc > p->nparams) FAILX("Too many arguments");
                }
                Value* nb = fv + 1;
                for (int k = argc; k < p->nlocals; k++) nb[k] = Value();
                if (nb + p->nlocals + STACK_MARGIN > stackEnd || nf >= maxFrames) FAILX("Stack overflow");
                fr->pc = pc;
                frames[nf++] = Frame{p, c, nb, p->code.data() + p->entry};
                sp = nb + p->nlocals;
                LOAD_FRAME();
                if (--budget <= 0 || gcWant) { SYNC(); slowTick(TICK_QUANTUM - (budget > 0 ? budget : 0)); budget = TICK_QUANTUM; }
                NEXT();
            }
            case K::Native: {
                NativeObj* nat = (NativeObj*)fv->o;
                SYNC();
                Value r = nat->fn(*vm, fv + 1, argc);
                sp = fv;
                *sp++ = r;
                NEXT();
            }
            case K::Bound: {
                BoundObj* bo = (BoundObj*)fv->o;
                SYNC();
                Value r = callMethodByName(bo->self, bo->sym, fv + 1, argc);
                sp = fv;
                *sp++ = r;
                NEXT();
            }
            case K::Host: {
                SYNC();
                Value r = hostCall(*fv, fv + 1, argc);
                sp = fv;
                *sp++ = r;
                NEXT();
            }
            default: FAILX("Cannot call a non-function value (" + typeName(*fv) + ")");
        }
    }
    CASE(RET) {
        Value r = sp[-1];
        Value* nb = base;
        while (!handlers.empty() && handlers.back().nf >= nf) handlers.pop_back();
        nf--;
        sp = nb - 1;
        *sp++ = r;
        if (nf <= entryNf) { SYNC(); return r; }
        LOAD_FRAME();
        NEXT();
    }

    CASE(ARR) {
        int n = ins->a;
        ArrObj* a = newArr();
        a->v.assign(sp - n, sp);
        noteGrowth((size_t)n * sizeof(Value));
        sp -= n;
        *sp++ = Value::Object(a);
        NEXT();
    }
    CASE(ARRAPP) {
        int n = ins->a;
        ArrObj* a = (ArrObj*)sp[-n - 1].o;
        a->v.insert(a->v.end(), sp - n, sp);
        noteGrowth((size_t)n * sizeof(Value));
        sp -= n;
        NEXT();
    }
    CASE(MAP) {
        int n = ins->a;
        MapObj* m = newMap();
        Value* start = sp - 2 * n;
        for (int i = 0; i < n; i++) mapSet(m, start[2 * i], start[2 * i + 1]);
        sp = start;
        *sp++ = Value::Object(m);
        NEXT();
    }
    CASE(OBJ) {
        int n = ins->b;
        const std::vector<StrObj*>& keys = fr->p->keyLists[(size_t)ins->a];
        ObjObj* o = newObj();
        o->f.reserve((size_t)n);
        Value* start = sp - n;
        for (int i = 0; i < n; i++) objSet(o, keys[(size_t)i], start[i]);
        sp = start;
        *sp++ = Value::Object(o);
        NEXT();
    }
    CASE(CLOSURE) {
        Proto* p = fr->p->protos[(size_t)ins->a];
        ClosureObj* c = alloc<ClosureObj>((size_t)p->ups.size() * sizeof(void*));
        c->p = p;
        c->nups = (int)p->ups.size();
        c->ups = c->nups ? new BoxObj*[(size_t)c->nups] : nullptr;
        for (int i = 0; i < c->nups; i++) {
            const UpDesc& u = p->ups[(size_t)i];
            if (u.fromLocal) {
                Value& slot = base[u.idx];
                if (slot.t != Type::Obj || slot.o->kind != K::Box) FAILX("Internal error: captured variable is not boxed");
                c->ups[i] = (BoxObj*)slot.o;
            } else {
                c->ups[i] = cl->ups[u.idx];
            }
        }
        *sp++ = Value::Object(c);
        NEXT();
    }
    CASE(NEW) {
        int argc = ins->b;
        SYNC();
        Value r = construct(asStr(consts[ins->a])->s, sp - argc, argc);
        sp -= argc;
        *sp++ = r;
        NEXT();
    }
    CASE(CONCAT) {
        int n = ins->a;
        SYNC();
        Value r = concatN(sp - n, n);
        sp -= n;
        *sp++ = r;
        NEXT();
    }
    CASE(RANGE) {
        Value& a = sp[-2];
        Value& b = sp[-1];
        if (a.t != Type::Int || b.t != Type::Int) FAILX("Range bounds must be Int");
        IterObj* it = newIter(IT_RANGE);
        it->i = a.i;
        it->n = b.i;
        --sp;
        sp[-1] = Value::Object(it);
        NEXT();
    }

    CASE(ITER) {
        SYNC();
        sp[-1] = makeIterator(sp[-1], ins->b != 0);
        NEXT();
    }
    CASE(ITERNEXT) {
        IterObj* it = (IterObj*)sp[-1].o;
        if (it->type == IT_ARRAY) {
            ArrObj* a = (ArrObj*)it->a.o;
            if ((size_t)it->i < a->v.size()) { *sp++ = a->v[(size_t)it->i++]; NEXT(); }
            pc = code + ins->a;
            NEXT();
        }
        SYNC();
        Value out;
        if (iterNext(it, out)) *sp++ = out;
        else pc = code + ins->a;
        NEXT();
    }
    CASE(ITERNEXT2) {
        IterObj* it = (IterObj*)sp[-1].o;
        SYNC();
        Value k, v;
        if (iterNext2(it, k, v)) { sp[0] = k; sp[1] = v; sp += 2; }
        else pc = code + ins->a;
        NEXT();
    }
    CASE(RANGENEXT) {
        Value& cur = sp[-2];
        Value& end = sp[-1];
        if (cur.t != Type::Int || end.t != Type::Int) FAILX("Range bounds must be Int");
        if (cur.i < end.i) {
            int32_t c = cur.i;
            cur.i = c + 1;
            if (ins->b) { base[ins->b - 1] = Value::Int(c); pc++; }
            else *sp++ = Value::Int(c);
        } else {
            pc = code + ins->a;
        }
        NEXT();
    }

    CASE(TRY) { handlers.push_back(Handler{nf, code + ins->a, sp}); NEXT(); }
    CASE(ENDTRY) { handlers.pop_back(); NEXT(); }
    CASE(THROW) { Value v = sp[-1]; SYNC(); throw Thrown{v, std::string(), false}; }
    CASE(ENUMCHECK) {
        Value v=sp[-1], result=Value::Bool(false);
        std::string spec=asStr(consts[ins->a])->s;
        size_t sep=spec.find('|');
        if(v.t==Type::Obj && v.o->kind==K::Object) {
            ObjObj* o=(ObjObj*)v.o;
            Value type=objGet(o,intern("__ss_enum")),tag=objGet(o,intern("tag")),params=objGet(o,intern("params"));
            if(type.t==Type::Obj && type.o->kind==K::String) result=Value();
            bool ok=type.t==Type::Obj && type.o->kind==K::String && tag.t==Type::Obj && tag.o->kind==K::String &&
               params.t==Type::Obj && params.o->kind==K::Array &&
               (sep==0 || asStr(type)->s==spec.substr(0,sep)) && asStr(tag)->s==spec.substr(sep+1) &&
               ((ArrObj*)params.o)->v.size()==ins->b;
            if(ok) result=params;
        } else if(v.t==Type::Obj && v.o->kind==K::Host && hcb.method) {
            SYNC();
            Value args[]={consts[ins->a],Value::Int(ins->b)};
            result=hostMethod(v,"__ss_match_enum",args,2);
        }
        sp[-1]=result;NEXT();
    }
    CASE(ISTYPE) {
        const std::string& tn = asStr(consts[ins->a])->s;
        bool r = isOfType(sp[-1], tn);
        if (ins->b) *sp++ = Value::Bool(r);
        else sp[-1] = Value::Bool(r);
        NEXT();
    }

CASE(ADDI) {
        Value& a = sp[-1];
        int d = (int16_t)ins->b;
        if (a.t == Type::Int) { int32_t r; if (ssvmOv_add(a.i, (int32_t)d, &r)) a = Value::Float((double)a.i + d); else a.i = r; NEXT(); }
        if (a.t == Type::Float) { a.d += d; NEXT(); }
        SYNC();
        a = addSlow(a, Value::Int(d));
        NEXT();
    }
#define JFCMP(NAME, OPR, SYMBOL)                                                            \
    CASE(NAME) {                                                                            \
        Value& a = sp[-2];                                                                  \
        Value& b = sp[-1];                                                                  \
        bool r;                                                                             \
        if (a.t == Type::Int && b.t == Type::Int) r = a.i OPR b.i;                          \
        else if (isNum(a) && isNum(b)) r = a.asNumber() OPR b.asNumber();                   \
        else if (isStrV(a) && isStrV(b)) r = asStr(a)->s.compare(asStr(b)->s) OPR 0;        \
        else FAILX("Invalid comparison: " + typeName(a) + " " SYMBOL " " + typeName(b));    \
        sp -= 2;                                                                            \
        if (!r) pc = code + ins->a;                                                         \
        NEXT();                                                                             \
    }                                                                                       \
    CASE(NAME##I) {                                                                         \
        Value& a = sp[-1];                                                                  \
        int32_t imm = (int16_t)ins->b;                                                      \
        bool r;                                                                             \
        if (a.t == Type::Int) r = a.i OPR imm;                                              \
        else if (a.t == Type::Float) r = a.d OPR (double)imm;                               \
        else FAILX("Invalid comparison: " + typeName(a) + " " SYMBOL " Int");               \
        --sp;                                                                               \
        if (!r) pc = code + ins->a;                                                         \
        NEXT();                                                                             \
    }
    JFCMP(JFLT, <, "<")
    JFCMP(JFLE, <=, "<=")
    JFCMP(JFGT, >, ">")
    JFCMP(JFGE, >=, ">=")
#undef JFCMP
    CASE(JFEQ) {
        bool r = valuesEqual(sp[-2], sp[-1]);
        sp -= 2;
        if (!r) pc = code + ins->a;
        NEXT();
    }
    CASE(JFNE) {
        bool r = !valuesEqual(sp[-2], sp[-1]);
        sp -= 2;
        if (!r) pc = code + ins->a;
        NEXT();
    }
    CASE(JFEQI) {
        Value& a = sp[-1];
        int32_t imm = (int16_t)ins->b;
        bool r = a.t == Type::Int ? a.i == imm : valuesEqual(a, Value::Int(imm));
        --sp;
        if (!r) pc = code + ins->a;
        NEXT();
    }
    CASE(JFNEI) {
        Value& a = sp[-1];
        int32_t imm = (int16_t)ins->b;
        bool r = a.t == Type::Int ? a.i != imm : !valuesEqual(a, Value::Int(imm));
        --sp;
        if (!r) pc = code + ins->a;
        NEXT();
    }

        CASE(INCL) {
        Value& v = base[ins->a];
        int d = (int16_t)ins->b;
        if (v.t == Type::Int) { int32_t r; if (ssvmOv_add(v.i, (int32_t)d, &r)) v = Value::Float((double)v.i + d); else v.i = r; }
        else if (v.t == Type::Float) v.d += d;
        else FAILX("Invalid operation: " + typeName(v) + " + Int");
        NEXT();
    }
    CASE(BOXINC) {
        Value& v = ((BoxObj*)base[ins->a].o)->v;
        int d = (int16_t)ins->b;
        if (v.t == Type::Int) { int32_t r; if (ssvmOv_add(v.i, (int32_t)d, &r)) v = Value::Float((double)v.i + d); else v.i = r; }
        else if (v.t == Type::Float) v.d += d;
        else FAILX("Invalid operation: " + typeName(v) + " + Int");
        NEXT();
    }

    CASE(CAST) {
        Value& v = sp[-1];
        if (v.t == Type::Null || v.t == Type::Undef) NEXT();
        switch (ins->b) {
            case 6: {
                std::string type=asStr(consts[ins->a])->s;
                if(isOfType(v,type))NEXT();
                FAILX("Cannot cast "+typeName(v)+" to "+type);
            }
            case 1: if (isStrV(v)) NEXT(); FAILX("Cannot cast " + typeName(v) + " to String");
            case 2: if (v.t == Type::Bool) NEXT(); FAILX("Cannot cast " + typeName(v) + " to Bool");
            case 3:
                if (v.t == Type::Int) NEXT();
                if (v.t == Type::Float) { v = Value::Int(toInt32(v.d)); NEXT(); }
                FAILX("Cannot cast " + typeName(v) + " to Int");
            case 4:
                if (v.t == Type::Float) NEXT();
                if (v.t == Type::Int) { v = Value::Float((double)v.i); NEXT(); }
                FAILX("Cannot cast " + typeName(v) + " to Float");
            default:
                if (v.t == Type::Obj && v.o->kind == K::Array) NEXT();
                if (v.t == Type::Obj && v.o->kind == K::Host && isOfType(v, "Array")) NEXT();
                FAILX("Cannot cast " + typeName(v) + " to Array");
        }
    }

    DISPATCH_END
}

Value VM::Impl::execute(int entryNf) {
    Thrown pending;
    for (;;) {
        try {
            return runLoop(entryNf);
        } catch (NativeErr& e) {
            std::string pos = currentPos();
            pending.v = strv(pos + ": " + e.msg);
            pending.pos = pos;
            pending.native = true;
        } catch (Thrown& t) {
            pending = t;
            if (pending.pos.empty()) pending.pos = currentPos();
        } catch (Error& e) {
            std::string pos = currentPos();
            pending.v = strv(pos + ": " + e.what());
            pending.pos = pos;
            pending.native = true;
        } catch (std::bad_alloc&) {
            pending.v = strv("Out of memory");
            pending.pos = currentPos();
            pending.native = true;
        } catch (std::regex_error& e) {
            std::string pos = currentPos();
            pending.v = strv(pos + ": Invalid regular expression: " + e.what());
            pending.pos = pos;
            pending.native = true;
        }
        if (!handlers.empty() && handlers.back().nf > entryNf) {
            Handler h = handlers.back();
            handlers.pop_back();
            nf = h.nf;
            frames[nf - 1].pc = h.pc;
            sp = h.sp;
            *sp++ = pending.v;
            continue;
        }
        nf = entryNf;
        throw pending;
    }
}

VM::VM() {
    impl_ = new Impl();
    Impl& I = *impl_;
    I.vm = this;
    I.stack = (Value*)malloc(sizeof(Value) * (size_t)STACK_VALUES);
    I.stackEnd = I.stack + STACK_VALUES;
    I.sp = I.stack;
    I.frames = (Frame*)malloc(sizeof(Frame) * (size_t)MAX_FRAMES);
    I.maxFrames = MAX_FRAMES - 1;
    I.nf = 0;
    static const char* symNames[] = {
#define X(n) #n,
        SSVM_SYMS(X)
#undef X
    };
    for (int i = 0; i < S__COUNT; i++) I.intern(symNames[i]);
    I.printer = [](const std::string& s) { fwrite(s.data(), 1, s.size(), stdout); fputc('\n', stdout); };
    I.installBuiltins();
}

VM::~VM() { delete impl_; }

void ProgramDeleter::operator()(Program* p) const { delete p; }

static void resetAfterError(VM::Impl& I) {
    if (I.execDepth == 0) {
        I.nf = 0;
        I.sp = I.stack;
        I.handlers.clear();
    }
}

static std::string thrownMessage(VM::Impl& I, const Thrown& t) {
    if (t.native) return I.toStr(t.v);
    std::string s;
    try { s = I.toStr(t.v); } catch (...) { s = "<error>"; }
    return t.pos + ": " + s;
}

ProgramPtr VM::compile(const std::string& source, const std::string& origin) {
    Ast ast;
    parseProgram(source, origin, ast);
    Proto* main = compileProgram(*impl_, ast, origin);
    Program* p = new Program();
    p->main = main;
    return ProgramPtr(p);
}

Value VM::run(Program* program) {
    Impl& I = *impl_;
    ClosureObj* c = I.alloc<ClosureObj>();
    c->p = program->main;
    Value fn = Value::Object(c);
    if (I.execDepth == 0) {
        I.startTime = nowMs();
        I.ticks = 0;
    }
    try {
        Value r = I.callClosureOrNative(fn, nullptr, 0);
        I.tmpResult = r;
        return r;
    } catch (Thrown& t) {
        std::string m = thrownMessage(I, t);
        resetAfterError(I);
        throw Error(m);
    } catch (NativeErr& e) {
        std::string m = I.currentPos() + ": " + e.msg;
        resetAfterError(I);
        throw Error(m);
    } catch (Abort& a) {
        resetAfterError(I);
        throw Error(a.msg);
    }
}

Value VM::eval(const std::string& source, const std::string& origin) {
    ProgramPtr p = compile(source, origin);
    return run(p.get());
}

Value VM::evalFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw Error("Cannot open file " + path);
    std::stringstream ss;
    ss << f.rdbuf();
    std::string src = ss.str();
    if (src.size() >= 3 && (unsigned char)src[0] == 0xEF && (unsigned char)src[1] == 0xBB && (unsigned char)src[2] == 0xBF) src.erase(0, 3);
    size_t slash = path.find_last_of("/\\");
    return eval(src, slash == std::string::npos ? path : path.substr(slash + 1));
}

bool VM::has(const std::string& name) const {
    auto it = impl_->globalIndex.find(name);
    return it != impl_->globalIndex.end() && impl_->globals[(size_t)it->second].t != Type::Undef;
}
Value VM::get(const std::string& name) const {
    auto it = impl_->globalIndex.find(name);
    if (it == impl_->globalIndex.end()) return Value();
    const Value& v = impl_->globals[(size_t)it->second];
    return v.t == Type::Undef ? Value() : v;
}
void VM::set(const std::string& name, Value v) {
    impl_->globals[(size_t)impl_->globalSlot(name)] = v;
}
void VM::def(const std::string& name, NativeFn fn) {
    set(name, Value::Object(impl_->newNative(name, std::move(fn))));
}

Value VM::call(const std::string& fnName, const std::vector<Value>& args) {
    if (!has(fnName)) throw Error("Unknown function " + fnName);
    return callValue(get(fnName), args.data(), (int)args.size());
}
Value VM::callValue(Value fn, const std::vector<Value>& args) { return callValue(fn, args.data(), (int)args.size()); }
Value VM::callValue(Value fn, const Value* args, int argc) {
    Impl& I = *impl_;
    if (I.execDepth == 0) {
        I.startTime = nowMs();
        I.ticks = 0;
    }
    try {
        Value r = I.callClosureOrNative(fn, args, argc);
        I.tmpResult = r;
        return r;
    } catch (Thrown& t) {
        std::string m = thrownMessage(I, t);
        resetAfterError(I);
        throw Error(m);
    } catch (NativeErr& e) {
        std::string m = e.msg;
        resetAfterError(I);
        throw Error(m);
    } catch (Abort& a) {
        resetAfterError(I);
        throw Error(a.msg);
    }
}

bool VM::Impl::guardedCall(Value fn, const Value* args, int argc, Value& out) {
    if (execDepth == 0) { startTime = nowMs(); ticks = 0; }
    errHasVal = false;
    errVal = Value();
    try {
        out = callClosureOrNative(fn, args, argc);
        tmpResult = out;
        return true;
    } catch (Thrown& t) {
        errMsg = thrownMessage(*this, t);
        errVal = t.v;
        errHasVal = true;
    } catch (NativeErr& e) {
        errMsg = e.msg;
    } catch (Abort& a) {
        errMsg = a.msg;
    } catch (Error& e) {
        errMsg = e.what();
    } catch (std::bad_alloc&) {
        errMsg = "Out of memory";
    } catch (std::exception& e) {
        errMsg = e.what();
    }
    resetAfterError(*this);
    return false;
}

Value VM::str(const std::string& s) { return impl_->strv(s); }
std::string VM::toString(Value v) { return impl_->toStr(v); }
Value VM::newArray() { return Value::Object(impl_->newArr()); }
void VM::arrayPush(Value arr, Value v) {
    if (!isArray(arr)) error("arrayPush: not an array");
    ((ArrObj*)arr.o)->v.push_back(v);
}
int VM::arrayLength(Value arr) { return isArray(arr) ? (int)((ArrObj*)arr.o)->v.size() : 0; }
Value VM::arrayGet(Value arr, int idx) {
    if (!isArray(arr)) return Value();
    ArrObj* a = (ArrObj*)arr.o;
    return (idx >= 0 && (size_t)idx < a->v.size()) ? a->v[(size_t)idx] : Value();
}
Value VM::newObject() { return Value::Object(impl_->newObj()); }
void VM::setField(Value obj, const std::string& name, Value v) { impl_->setField(obj, impl_->intern(name), v); }
Value VM::getField(Value obj, const std::string& name) {
    StrObj* s = impl_->intern(name);
    return impl_->getField(obj, s, s->sym);
}
bool VM::isString(Value v) const { return isStrV(v); }
bool VM::isArray(Value v) const { return v.t == Type::Obj && v.o->kind == K::Array; }
bool VM::isFunction(Value v) const {
    return v.t == Type::Obj && (v.o->kind == K::Closure || v.o->kind == K::Native || v.o->kind == K::Bound);
}
std::string VM::stringValue(Value v) const { return isStrV(v) ? asStr(v)->s : std::string(); }
void VM::pin(Value v) { impl_->pinned.push_back(v); }
void VM::unpin(Value v) {
    auto& p = impl_->pinned;
    for (size_t i = p.size(); i-- > 0;) {
        if (p[i].t == v.t && ((v.t == Type::Obj && p[i].o == v.o) || v.t != Type::Obj)) { p.erase(p.begin() + (long)i); return; }
    }
}
void VM::error(const std::string& message) { throw NativeErr{message}; }
void VM::setPrintHandler(std::function<void(const std::string&)> h) { impl_->printer = std::move(h); }
void VM::setTickLimit(uint64_t ticks) { impl_->tickLimit = ticks; }
void VM::setTimeLimitMs(double ms) { impl_->timeLimitMs = ms; }
void VM::collectGarbage() { impl_->collect(); }

}  // namespace ssvm

using namespace ssvm;

extern "C" {
ssvm_vm* ssvm_create(void) { return new ssvm_vm(); }
void ssvm_destroy(ssvm_vm* v) { delete v; }
int ssvm_eval(ssvm_vm* v, const char* source, const char* origin) {
    try {
        v->vm.eval(source ? source : "", origin ? origin : "SScript");
        v->error.clear();
        return 0;
    } catch (std::exception& e) {
        v->error = e.what();
        return 1;
    }
}
const char* ssvm_last_error(ssvm_vm* v) { return v->error.c_str(); }
void ssvm_set_int(ssvm_vm* v, const char* n, int x) { v->vm.set(n, Value::Int(x)); }
void ssvm_set_float(ssvm_vm* v, const char* n, double x) { v->vm.set(n, Value::Float(x)); }
void ssvm_set_bool(ssvm_vm* v, const char* n, int x) { v->vm.set(n, Value::Bool(x != 0)); }
void ssvm_set_string(ssvm_vm* v, const char* n, const char* s) { v->vm.set(n, v->vm.str(s ? s : "")); }
void ssvm_set_null(ssvm_vm* v, const char* n) { v->vm.set(n, Value()); }
int ssvm_has(ssvm_vm* v, const char* n) { return v->vm.has(n) ? 1 : 0; }
int ssvm_get_int(ssvm_vm* v, const char* n, int fb) {
    Value x = v->vm.get(n);
    return x.isInt() ? x.i : x.isFloat() ? toInt32(x.d) : fb;
}
double ssvm_get_float(ssvm_vm* v, const char* n, double fb) {
    Value x = v->vm.get(n);
    return x.isNumber() ? x.asNumber() : fb;
}
int ssvm_get_bool(ssvm_vm* v, const char* n, int fb) {
    Value x = v->vm.get(n);
    return x.isBool() ? (x.b ? 1 : 0) : fb;
}
const char* ssvm_get_string(ssvm_vm* v, const char* n) {
    v->str = v->vm.toString(v->vm.get(n));
    return v->str.c_str();
}
int ssvm_call(ssvm_vm* v, const char* fn, int argc, const char* types, const double* nums, const char* const* strs) {
    try {
        std::vector<Value> args;
        int ni = 0, si = 0;
        for (int i = 0; i < argc; i++) {
            switch (types[i]) {
                case 'b': args.push_back(Value::Bool(nums[ni++] != 0)); break;
                case 'i': args.push_back(Value::Int((int32_t)nums[ni++])); break;
                case 'f': args.push_back(Value::Float(nums[ni++])); break;
                case 's': args.push_back(v->vm.str(strs[si++])); break;
                default: args.push_back(Value()); break;
            }
        }
        v->result = v->vm.call(fn, args);
        v->str = v->vm.toString(v->result);
        v->error.clear();
        return 0;
    } catch (std::exception& e) {
        v->error = e.what();
        return 1;
    }
}
const char* ssvm_result_string(ssvm_vm* v) { return v->str.c_str(); }
double ssvm_result_number(ssvm_vm* v) { return v->result.isNumber() ? v->result.asNumber() : v->result.isBool() ? (v->result.b ? 1.0 : 0.0) : 0.0; }
void ssvm_set_tick_limit(ssvm_vm* v, unsigned long long t) { v->vm.setTickLimit(t); }
void ssvm_set_time_limit_ms(ssvm_vm* v, double ms) { v->vm.setTimeLimitMs(ms); }
}
