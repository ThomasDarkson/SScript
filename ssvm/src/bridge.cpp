#include "internal.hpp"

using namespace ssvm;

int VM::Impl::newRef(Value v) {
    if (!freeRefs.empty()) {
        int r = freeRefs.back();
        freeRefs.pop_back();
        refs[(size_t)r] = v;
        return r;
    }
    refs.push_back(v);
    return (int)refs.size() - 1;
}

Value VM::Impl::takeRef(int r) {
    if (r < 0 || (size_t)r >= refs.size()) return Value();
    Value v = refs[(size_t)r];
    refs[(size_t)r] = Value();
    freeRefs.push_back(r);
    return v;
}

void VM::Impl::freeRef(int r) { takeRef(r); }

Value VM::Impl::hostResult(int r) {
    if (r < 0) {
        Value e = hostError;
        hostError = Value();
        hasHostError = false;
        throw Thrown{e, std::string(), false};
    }
    return takeRef(r);
}

Value VM::Impl::makeHost(int id) {
    HostObj* h = alloc<HostObj>(64);
    h->id = id;
    h->cb = &hcb;
    return Value::Object(h);
}

static inline int hid(const Value& h) { return ((HostObj*)h.o)->id; }

namespace {
struct ArgRefs {
    int small[8];
    std::vector<int> big;
    int* p;
    ArgRefs(VM::Impl& I, Value* args, int argc) {
        p = small;
        if (argc > 8) { big.resize((size_t)argc); p = big.data(); }
        for (int i = 0; i < argc; i++) p[i] = I.newRef(args[i]);
    }
};
}  // namespace

Value VM::Impl::hostGet(Value h, StrObj* name) {
    if (!hcb.get) fail("No host bridge available");
    return hostResult(hcb.get(hid(h), name->s.c_str()));
}

void VM::Impl::hostSet(Value h, StrObj* name, Value v) {
    if (!hcb.set) fail("No host bridge available");
    int r = hcb.set(hid(h), name->s.c_str(), newRef(v));
    if (r < 0) hostResult(r);
}

Value VM::Impl::hostCall(Value h, Value* args, int argc) {
    if (!hcb.call) fail("No host bridge available");
    ArgRefs a(*this, args, argc);
    return hostResult(hcb.call(hid(h), argc, a.p));
}

Value VM::Impl::hostMethod(Value h, const std::string& name, Value* args, int argc) {
    if (!hcb.method) fail("No host bridge available");
    ArgRefs a(*this, args, argc);
    return hostResult(hcb.method(hid(h), name.c_str(), argc, a.p));
}

Value VM::Impl::hostGetIdx(Value h, Value idx) {
    if (!hcb.getIdx) fail("No host bridge available");
    return hostResult(hcb.getIdx(hid(h), newRef(idx)));
}

void VM::Impl::hostSetIdx(Value h, Value idx, Value v) {
    if (!hcb.setIdx) fail("No host bridge available");
    int ri = newRef(idx), rv = newRef(v);
    int r = hcb.setIdx(hid(h), ri, rv);
    if (r < 0) hostResult(r);
}

Value VM::Impl::hostNew(Value cls, Value* args, int argc) {
    if (!hcb.construct) fail("No host bridge available");
    ArgRefs a(*this, args, argc);
    return hostResult(hcb.construct(hid(cls), argc, a.p));
}

void VM::Impl::traceOut(const std::string& origin, int line, Value* args, int argc) {
    std::vector<std::string> strs;
    for (int i = 0; i < argc; i++) strs.push_back(toStr(args[i]));
    if (hcb.print) {
        std::vector<const char*> ptrs;
        for (auto& s : strs) ptrs.push_back(s.c_str());
        hcb.print(origin.c_str(), line, argc, ptrs.data());
        return;
    }
    std::string s;
    for (int i = 0; i < argc; i++) { if (i) s += ","; s += strs[(size_t)i]; }
    printer(origin + ":" + std::to_string(line) + ": " + s);
}

namespace {
VM::Impl& I_(ssvm_vm* v) { return *v->vm.impl(); }
Program* prog(ssvm_vm* v, int id) { return (id >= 0 && (size_t)id < v->programs.size()) ? v->programs[(size_t)id].get() : nullptr; }
const char* keep(ssvm_vm* v, const std::string& s) { v->str = s; return v->str.c_str(); }
}  // namespace

extern "C" {

void ssvm_set_callbacks(ssvm_vm* v,
                        int (*get)(int, const char*), int (*set)(int, const char*, int),
                        int (*call)(int, int, int*), int (*method)(int, const char*, int, int*),
                        int (*construct)(int, int, int*), int (*getIdx)(int, int),
                        int (*setIdx)(int, int, int), int (*equals)(int, int),
                        const char* (*toStr)(int), void (*release)(int),
                        void (*print)(const char*, int, int, const char**), int (*isType)(int, const char*)) {
    I_(v).hxcppStyle = true;
    HostCb& c = I_(v).hcb;
    c.get = get; c.set = set; c.call = call; c.method = method; c.construct = construct;
    c.getIdx = getIdx; c.setIdx = setIdx; c.equals = equals; c.toStr = toStr; c.release = release;
    c.print = print; c.isType = isType;
}

int ssvm_compile(ssvm_vm* v, const char* source, const char* origin) {
    try {
        Ast ast;
        std::string org = origin ? origin : "SScript";
        parseProgram(source ? source : "", org, ast);
        Program* p = new Program();
        v->programs.emplace_back(p);
        p->main = compileProgram(I_(v), ast, org, p);
        v->error.clear();
        return (int)v->programs.size() - 1;
    } catch (std::exception& e) {
        v->error = e.what();
        return -1;
    }
}
const char* ssvm_program_unsupported(ssvm_vm* v, int id) { Program* p = prog(v, id); return keep(v, p ? p->unsupported : std::string("no such program")); }
int ssvm_program_need_count(ssvm_vm* v, int id) { Program* p = prog(v, id); return p ? (int)p->needs.size() : 0; }
const char* ssvm_program_need(ssvm_vm* v, int id, int i) { Program* p = prog(v, id); return keep(v, p ? p->needs[(size_t)i] : std::string()); }
int ssvm_program_declared_count(ssvm_vm* v, int id) { Program* p = prog(v, id); return p ? (int)p->declared.size() : 0; }
const char* ssvm_program_declared(ssvm_vm* v, int id, int i) { Program* p = prog(v, id); return keep(v, p ? p->declared[(size_t)i] : std::string()); }
int ssvm_program_import_count(ssvm_vm* v, int id) { Program* p = prog(v, id); return p ? (int)p->imports.size() : 0; }
const char* ssvm_program_import_name(ssvm_vm* v, int id, int i) { Program* p = prog(v, id); return keep(v, p ? p->imports[(size_t)i].first : std::string()); }
const char* ssvm_program_import_path(ssvm_vm* v, int id, int i) { Program* p = prog(v, id); return keep(v, p ? p->imports[(size_t)i].second : std::string()); }

int ssvm_run(ssvm_vm* v, int id) {
    Program* p = prog(v, id);
    VM::Impl& I = I_(v);
    if (!p) { v->error = "no such program"; return 1; }
    ClosureObj* c = I.alloc<ClosureObj>();
    c->p = p->main;
    Value out;
    if (I.guardedCall(Value::Object(c), nullptr, 0, out)) { v->error.clear(); return 0; }
    v->error = I.errMsg;
    return 1;
}

int ssvm_has_global(ssvm_vm* v, const char* n) { return v->vm.has(n) ? 1 : 0; }
int ssvm_global_is_builtin(ssvm_vm* v, const char* n) { return I_(v).builtinNames.count(n) ? 1 : 0; }
void ssvm_undef_global(ssvm_vm* v, const char* n) {
    VM::Impl& I = I_(v);
    auto it = I.globalIndex.find(n);
    if (it != I.globalIndex.end()) { Value u; u.t = Type::Undef; I.globals[(size_t)it->second] = u; }
}
int ssvm_result_ref(ssvm_vm* v) { return I_(v).newRef(I_(v).tmpResult); }
int ssvm_get_global_ref(ssvm_vm* v, const char* n) { return I_(v).newRef(v->vm.get(n)); }
void ssvm_set_global_ref(ssvm_vm* v, const char* n, int ref) {
    VM::Impl& I = I_(v);
    int slot = I.globalSlot(n);
    I.globals[(size_t)slot] = I.takeRef(ref);
}

static int ensureSelfSlot(VM::Impl& I) {
    if (I.selfSlot < 0) I.selfSlot = I.globalSlot(std::string("\x01self"));
    return I.selfSlot;
}
void ssvm_self_clear(ssvm_vm* v) {
    VM::Impl& I = I_(v);
    I.selfFields.clear();
    if (I.selfSlot >= 0) { Value u; u.t = Type::Undef; I.globals[(size_t)I.selfSlot] = u; }
    I.selfSlot = -1;
}
void ssvm_self_field(ssvm_vm* v, const char* name) {
    VM::Impl& I = I_(v);
    ensureSelfSlot(I);
    I.selfFields.insert(name ? name : "");
}
void ssvm_self_bind(ssvm_vm* v, int ref) {
    VM::Impl& I = I_(v);
    int slot = ensureSelfSlot(I);
    I.globals[(size_t)slot] = I.takeRef(ref);
}
int ssvm_self_active(ssvm_vm* v) { return I_(v).selfSlot >= 0 && !I_(v).selfFields.empty() ? 1 : 0; }

static int callCommon(ssvm_vm* v, Value fn, int argc, const int* args) {
    VM::Impl& I = I_(v);
    std::vector<Value> av;
    av.reserve((size_t)argc);
    for (int i = 0; i < argc; i++) av.push_back(I.takeRef(args[i]));
    size_t pinBase = I.pinned.size();
    for (auto& a : av) I.pinned.push_back(a);
    Value out;
    bool ok = I.guardedCall(fn, av.data(), argc, out);
    I.pinned.resize(pinBase);
    if (ok) { v->error.clear(); return I.newRef(out); }
    v->error = I.errMsg;
    return -1;
}
int ssvm_call_global(ssvm_vm* v, const char* name, int argc, const int* args) {
    if (!v->vm.has(name)) {
        for (int i = 0; i < argc; i++) I_(v).freeRef(args[i]);
        v->error = std::string("Unknown function ") + name;
        I_(v).errHasVal = false;
        return -1;
    }
    return callCommon(v, v->vm.get(name), argc, args);
}
int ssvm_call_ref(ssvm_vm* v, int fnRef, int argc, const int* args) {
    VM::Impl& I = I_(v);
    Value fn = (fnRef >= 0 && (size_t)fnRef < I.refs.size()) ? I.refs[(size_t)fnRef] : Value();
    return callCommon(v, fn, argc, args);
}
int ssvm_error_ref(ssvm_vm* v) {
    VM::Impl& I = I_(v);
    return I.errHasVal ? I.newRef(I.errVal) : -1;
}
void ssvm_set_host_error(ssvm_vm* v, int ref) {
    VM::Impl& I = I_(v);
    I.hostError = I.takeRef(ref);
    I.hasHostError = true;
}

int ssvm_ref_null(ssvm_vm* v) { return I_(v).newRef(Value()); }
int ssvm_ref_bool(ssvm_vm* v, int b) { return I_(v).newRef(Value::Bool(b != 0)); }
int ssvm_ref_int(ssvm_vm* v, int i) { return I_(v).newRef(Value::Int(i)); }
int ssvm_ref_float(ssvm_vm* v, double d) { return I_(v).newRef(Value::Float(d)); }
int ssvm_ref_string(ssvm_vm* v, const char* s) { VM::Impl& I = I_(v); return I.newRef(I.strv(s ? s : "")); }
int ssvm_ref_host(ssvm_vm* v, int id) { VM::Impl& I = I_(v); return I.newRef(I.makeHost(id)); }
int ssvm_ref_dup(ssvm_vm* v, int ref) {
    VM::Impl& I = I_(v);
    Value x = (ref >= 0 && (size_t)ref < I.refs.size()) ? I.refs[(size_t)ref] : Value();
    return I.newRef(x);
}
void ssvm_ref_free(ssvm_vm* v, int ref) { I_(v).freeRef(ref); }

static Value refVal(ssvm_vm* v, int ref) {
    VM::Impl& I = I_(v);
    return (ref >= 0 && (size_t)ref < I.refs.size()) ? I.refs[(size_t)ref] : Value();
}

int ssvm_ref_type(ssvm_vm* v, int ref) {
    Value x = refVal(v, ref);
    switch (x.t) {
        case Type::Undef: case Type::Null: return 0;
        case Type::Bool: return 1;
        case Type::Int: return 2;
        case Type::Float: return 3;
        case Type::Obj: break;
    }
    switch (x.o->kind) {
        case K::String: return 4;
        case K::Array: return 5;
        case K::Object: return 6;
        case K::Map: return 7;
        case K::Host: return 8;
        case K::Closure: case K::Native: case K::Bound: return 9;
        default: return 10;
    }
}
int ssvm_ref_get_int(ssvm_vm* v, int ref) { Value x = refVal(v, ref); return x.isInt() ? x.i : x.isFloat() ? toInt32(x.d) : 0; }
double ssvm_ref_get_float(ssvm_vm* v, int ref) { Value x = refVal(v, ref); return x.isNumber() ? x.asNumber() : 0; }
int ssvm_ref_get_bool(ssvm_vm* v, int ref) { Value x = refVal(v, ref); return x.isBool() && x.b ? 1 : 0; }
const char* ssvm_ref_get_string(ssvm_vm* v, int ref) { return keep(v, I_(v).toStr(refVal(v, ref))); }
int ssvm_ref_host_id(ssvm_vm* v, int ref) { Value x = refVal(v, ref); return (x.t == Type::Obj && x.o->kind == K::Host) ? ((HostObj*)x.o)->id : -1; }

int ssvm_ref_array_len(ssvm_vm* v, int ref) { Value x = refVal(v, ref); return (x.t == Type::Obj && x.o->kind == K::Array) ? (int)((ArrObj*)x.o)->v.size() : 0; }
int ssvm_ref_array_get(ssvm_vm* v, int ref, int i) {
    Value x = refVal(v, ref);
    if (x.t != Type::Obj || x.o->kind != K::Array || i < 0 || (size_t)i >= ((ArrObj*)x.o)->v.size()) return I_(v).newRef(Value());
    return I_(v).newRef(((ArrObj*)x.o)->v[(size_t)i]);
}
int ssvm_ref_object_len(ssvm_vm* v, int ref) {
    Value x = refVal(v, ref);
    return (x.t == Type::Obj && x.o->kind == K::Object) ? (int)((ObjObj*)x.o)->f.size() : 0;
}
const char* ssvm_ref_object_key(ssvm_vm* v, int ref, int i) {
    Value x = refVal(v, ref);
    if (x.t != Type::Obj || x.o->kind != K::Object || i < 0 || (size_t)i >= ((ObjObj*)x.o)->f.size()) return keep(v, "");
    return keep(v, ((ObjObj*)x.o)->f[(size_t)i].k->s);
}
int ssvm_ref_object_val(ssvm_vm* v, int ref, int i) {
    Value x = refVal(v, ref);
    if (x.t != Type::Obj || x.o->kind != K::Object || i < 0 || (size_t)i >= ((ObjObj*)x.o)->f.size()) return I_(v).newRef(Value());
    return I_(v).newRef(((ObjObj*)x.o)->f[(size_t)i].v);
}
int ssvm_ref_map_raw_len(ssvm_vm* v, int ref) { Value x = refVal(v, ref); return (x.t == Type::Obj && x.o->kind == K::Map) ? (int)((MapObj*)x.o)->ents.size() : 0; }
int ssvm_ref_map_key(ssvm_vm* v, int ref, int i) {
    Value x = refVal(v, ref);
    if (x.t != Type::Obj || x.o->kind != K::Map || i < 0 || (size_t)i >= ((MapObj*)x.o)->ents.size()) return -1;
    MapEnt& e = ((MapObj*)x.o)->ents[(size_t)i];
    return e.alive ? I_(v).newRef(e.k) : -1;
}
int ssvm_ref_map_val(ssvm_vm* v, int ref, int i) {
    Value x = refVal(v, ref);
    if (x.t != Type::Obj || x.o->kind != K::Map || i < 0 || (size_t)i >= ((MapObj*)x.o)->ents.size()) return -1;
    MapEnt& e = ((MapObj*)x.o)->ents[(size_t)i];
    return e.alive ? I_(v).newRef(e.v) : -1;
}

}  // extern "C"
