#pragma once

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <ctime>
#include <deque>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <regex>

#include "ssvm.hpp"

namespace ssvm {

inline int32_t toInt32(double d) {
    if (d >= -2147483648.0 && d <= 2147483647.0) return (int32_t)d;
    if (!(d == d) || d > 1.7e308 || d < -1.7e308) return 0;
    double m = std::fmod(std::trunc(d), 4294967296.0);
    if (m < 0) m += 4294967296.0;
    return (int32_t)(uint32_t)(uint64_t)m;
}

enum class K : uint8_t { String, Array, Map, Object, Closure, Native, Box, Iter, Bound, StrBuf, Regex, Host };

struct Obj {
    K kind;
    bool mark = false;
    bool perm = false;
    Obj* next = nullptr;
    explicit Obj(K k) : kind(k) {}
};

struct StrObj : Obj {
    std::string s;
    uint32_t hash = 0;
    int sym = -1;
    StrObj() : Obj(K::String) {}
};

struct ArrObj : Obj {
    std::vector<Value> v;
    ArrObj() : Obj(K::Array) {}
};

struct KeyHash { size_t operator()(const Value& v) const; };
struct KeyEq { bool operator()(const Value& a, const Value& b) const; };
struct MapEnt { Value k, v; bool alive; };

struct MapObj : Obj {
    std::unordered_map<Value, uint32_t, KeyHash, KeyEq> idx;
    std::vector<MapEnt> ents;
    uint32_t live = 0;
    MapObj() : Obj(K::Map) {}
};

struct Field { StrObj* k; Value v; };
struct ObjObj : Obj {
    std::vector<Field> f;
    ObjObj() : Obj(K::Object) {}
};

struct Proto;
struct BoxObj : Obj {
    Value v;
    BoxObj() : Obj(K::Box) {}
};

struct ClosureObj : Obj {
    Proto* p = nullptr;
    BoxObj** ups = nullptr;
    int nups = 0;
    ClosureObj() : Obj(K::Closure) {}
};

struct NativeObj : Obj {
    NativeFn fn;
    std::string name;
    NativeObj() : Obj(K::Native) {}
};

enum IterType : int { IT_ARRAY, IT_MAPKEYS, IT_MAPVALS, IT_MAPKV, IT_RANGE, IT_STRING, IT_CUSTOM, IT_HOST };
struct IterObj : Obj {
    int type = IT_ARRAY;
    Value a;
    int32_t i = 0;
    int32_t n = 0;
    Value b;
    IterObj() : Obj(K::Iter) {}
};

struct BoundObj : Obj {
    Value self;
    int sym = 0;
    BoundObj() : Obj(K::Bound) {}
};

struct BufObj : Obj {
    std::string s;
    BufObj() : Obj(K::StrBuf) {}
};

struct HostCb;
struct HostObj : Obj {
    int id = 0;
    HostCb* cb = nullptr;
    HostObj() : Obj(K::Host) {}
};

struct RegexObj : Obj {
    std::regex re;
    std::string src, flags;
    bool global = false;
    std::string subject;
    std::smatch m;
    bool matched = false;
    RegexObj() : Obj(K::Regex) {}
};

#define SSVM_OPS(X) \
    X(NOP) X(NULL_) X(TRUE_) X(FALSE_) X(INT) X(CONST) X(POP) X(DUP) X(DUP2) X(SWAP) \
    X(LOCAL) X(SETLOCAL) X(SETLOCALP) X(BOXGET) X(BOXSET) X(BOXSETP) X(BOXNEW) X(BOXPARAMS) \
    X(UPGET) X(UPSET) X(UPSETP) X(GGET) X(GSET) X(GSETP) X(GDEF) \
    X(ADD) X(SUB) X(MUL) X(DIV) X(MOD) X(BAND) X(BOR) X(BXOR) X(SHL) X(SHR) X(USHR) \
    X(EQ) X(NE) X(LT) X(LE) X(GT) X(GE) X(NOT) X(NEG) X(BNOT) \
    X(JMP) X(JMPF) X(JMPT) X(JMPNN) X(JMPNULL) \
    X(GETF) X(SETF) X(GETI) X(SETI) X(CALL) X(CALLM) X(RET) X(ARR) X(ARRAPP) X(MAP) X(OBJ) \
    X(CLOSURE) X(NEW) X(CONCAT) X(RANGE) \
    X(ITER) X(ITERNEXT) X(ITERNEXT2) X(RANGENEXT) X(TRY) X(ENDTRY) X(THROW) X(ISTYPE) X(TOBOOL) \
    X(INCL) X(BOXINC) X(LOOP) X(ADDI) \
    X(JFLT) X(JFLE) X(JFGT) X(JFGE) X(JFEQ) X(JFNE) X(JFLTI) X(JFLEI) X(JFGTI) X(JFGEI) X(JFEQI) X(JFNEI) \
    X(CAST)

enum Op : uint8_t {
#define X(n) OP_##n,
    SSVM_OPS(X)
#undef X
    OP__COUNT
};

struct Ins {
    uint8_t op;
    uint8_t x;
    uint16_t b;
    int32_t a;
};

struct UpDesc { bool fromLocal; int idx; };

struct Proto {
    std::string name, origin;
    int nparams = 0, minArgs = 0, nlocals = 0, entry = 0;
    std::vector<Ins> code;
    std::vector<int> lines;
    std::vector<Value> consts;
    std::vector<Proto*> protos;
    std::vector<UpDesc> ups;
    std::vector<std::vector<StrObj*>> keyLists;
    std::vector<std::string> paramNames;
    int lineAt(const Ins* pc) const {
        long i = (long)(pc - code.data());
        if (i < 0) i = 0;
        if (i >= (long)lines.size()) i = (long)lines.size() - 1;
        return i >= 0 ? lines[(size_t)i] : 0;
    }
};

struct Program {
    Proto* main = nullptr;
    std::vector<std::string> needs;
    std::vector<std::string> declared;
    std::string unsupported;
    std::vector<std::pair<std::string, std::string>> imports;
};

enum class N : uint8_t {
    Int, Float, Str, Interp, Ident, Var, Vars, Block, Field, Binop, Unop, Assign, Call,
    If, While, DoWhile, For, Coalesce, SafeNav, Break, Continue, Func, Return, Index,
    Array, MapLit, New, Throw, Try, Object, Ternary, Switch, Nop, Import, Is, Regex, Cast
};

struct Node;
struct Param { std::string name; Node* def = nullptr; bool opt = false; };
struct CatchC { std::string var, type; Node* body = nullptr; };
struct CaseC { std::vector<Node*> values; Node* guard = nullptr; Node* body = nullptr; };

struct Node {
    N k;
    int line = 0;
    std::string s, s2;
    int64_t iv = 0;
    double fv = 0;
    bool flag = false;
    bool paren = false;
    std::vector<std::string> names;
    Node *a = nullptr, *b = nullptr, *c = nullptr;
    std::vector<Node*> list;
    std::vector<Param> params;
    std::vector<CatchC> catches;
    std::vector<CaseC> cases;
    explicit Node(N kind, int ln) : k(kind), line(ln) {}
};

struct Ast {
    std::deque<Node> nodes;
    Node* root = nullptr;
    Node* mk(N k, int line) { nodes.emplace_back(k, line); return &nodes.back(); }
};

void parseProgram(const std::string& src, const std::string& origin, Ast& ast, int startLine = 1);

struct Frame {
    Proto* p;
    ClosureObj* cl;
    Value* base;
    const Ins* pc;
};

struct Handler {
    int nf;
    const Ins* pc;
    Value* sp;
};

struct NativeErr { std::string msg; };
struct Thrown {
    Value v;
    std::string pos;
    bool native;
    Thrown() : native(false) {}
    Thrown(Value v_, std::string p_, bool n_) : v(v_), pos(std::move(p_)), native(n_) {}
};

#define SSVM_SYMS(X) \
    X(length) X(push) X(pop) X(shift) X(unshift) X(insert) X(remove) X(indexOf) X(lastIndexOf) \
    X(contains) X(join) X(concat) X(slice) X(splice) X(reverse) X(sort) X(map) X(filter) X(iterator) \
    X(keyValueIterator) X(copy) X(resize) X(toString) X(charAt) X(charCodeAt) X(split) X(substr) \
    X(substring) X(toLowerCase) X(toUpperCase) X(trim) X(ltrim) X(rtrim) X(startsWith) X(endsWith) \
    X(replace) X(lpad) X(rpad) X(set) X(get) X(exists) X(keys) X(clear) X(hasNext) X(next) X(add) \
    X(addChar) X(addSub) X(iter) X(fill) X(match) X(matched) X(matchedLeft) X(matchedRight) X(matchedPos) \
    X(matchSub) X(__name) X(size) X(isEmpty) X(call) X(apply) X(bind) X(toInt) X(toFloat) X(keyAt) \
    X(removeAt) X(first) X(last) X(count) X(sum) X(min) X(max) X(find) X(findIndex) X(some) X(every) \
    X(flatten) X(fromCharCode) X(compare) X(sortBy) X(pad) X(repeat) X(isSpace) X(hex)

enum Sym : int {
#define X(n) S_##n,
    SSVM_SYMS(X)
#undef X
    S__COUNT
};

struct HostCb {
    int (*get)(int, const char*) = nullptr;
    int (*set)(int, const char*, int) = nullptr;
    int (*call)(int, int, int*) = nullptr;
    int (*method)(int, const char*, int, int*) = nullptr;
    int (*construct)(int, int, int*) = nullptr;
    int (*getIdx)(int, int) = nullptr;
    int (*setIdx)(int, int, int) = nullptr;
    int (*iter)(int, int) = nullptr;
    int (*equals)(int, int) = nullptr;
    const char* (*toStr)(int) = nullptr;
    void (*release)(int) = nullptr;
    void (*print)(const char*, int, int, const char**) = nullptr;
    int (*isType)(int, const char*) = nullptr;
};

struct VM::Impl {
    VM* vm = nullptr;

    HostCb hcb;
    std::vector<Value> refs;
    std::vector<int> freeRefs;
    Value hostError;
    bool hasHostError = false;
    bool hxcppStyle = false;
    std::unordered_set<std::string> builtinNames;
    int  newRef(Value v);
    Value takeRef(int r);
    void freeRef(int r);
    Value hostResult(int ref);
    Value hostGet(Value h, StrObj* name);
    void  hostSet(Value h, StrObj* name, Value v);
    Value hostCall(Value h, Value* args, int argc);
    Value hostMethod(Value h, const std::string& name, Value* args, int argc);
    Value hostGetIdx(Value h, Value idx);
    void  hostSetIdx(Value h, Value idx, Value v);
    Value hostNew(Value cls, Value* args, int argc);
    Value makeHost(int id);
    void  traceOut(const std::string& origin, int line, Value* args, int argc);


    std::unordered_map<std::string, StrObj*> symtab;
    std::vector<StrObj*> syms;

    std::vector<Value> globals;
    std::vector<std::string> globalNames;
    std::unordered_map<std::string, int> globalIndex;
    std::unordered_set<std::string> finalGlobals;

    std::unordered_set<std::string> selfFields;
    int selfSlot = -1;

    Obj* objects = nullptr;
    size_t bytes = 0;
    size_t nextGC = 8u << 20;
    bool gcWant = false;
    std::vector<Obj*> permObjs;
    std::vector<Value> pinned;
    std::vector<Obj*> gray;

    std::vector<std::unique_ptr<Proto>> protoPool;

    Value* stack = nullptr;
    Value* stackEnd = nullptr;
    Value* sp = nullptr;
    Frame* frames = nullptr;
    int nf = 0;
    int maxFrames = 0;
    std::vector<Handler> handlers;
    int execDepth = 0;

    uint64_t tickLimit = 0, ticks = 0;
    double timeLimitMs = 0;
    double startTime = 0;

    std::function<void(const std::string&)> printer;
    std::unordered_map<std::string, NativeFn> classes;

    Value tmpResult;

    std::string errMsg;
    Value errVal;
    bool errHasVal = false;
    bool guardedCall(Value fn, const Value* args, int argc, Value& out);

    template <class T> T* alloc(size_t extra = 0) {
        T* o = new T();
        o->next = objects;
        objects = o;
        bytes += sizeof(T) + extra;
        if (bytes > nextGC) gcWant = true;
        return o;
    }
    void noteGrowth(size_t n) { bytes += n; if (bytes > nextGC) gcWant = true; }
    StrObj* newStr(const std::string& s);
    StrObj* newStr(std::string&& s);
    StrObj* intern(const std::string& s);
    StrObj* permStr(const std::string& s);
    Value strv(const std::string& s) { return Value::Object(newStr(s)); }
    ArrObj* newArr() { return alloc<ArrObj>(); }
    ObjObj* newObj() { return alloc<ObjObj>(); }
    MapObj* newMap() { return alloc<MapObj>(); }
    IterObj* newIter(int type) { IterObj* i = alloc<IterObj>(); i->type = type; return i; }
    NativeObj* newNative(const std::string& name, NativeFn fn);
    void freeObj(Obj* o);
    void collect();
    void markValue(const Value& v);
    void markObj(Obj* o);
    void drain();

    int globalSlot(const std::string& name);

    [[noreturn]] void fail(const std::string& msg) { throw NativeErr{msg}; }

    Value execute(int entryNf);
    Value runLoop(int entryNf);
    Value addSlow(Value a, Value b);
    Value concatN(Value* start, int n);
    Value callClosureOrNative(Value fn, const Value* args, int argc);
    Value callMethodByName(Value self, int sym, Value* args, int argc);
    Value callMethodRaw(Value self, int sym, Value* args, int argc);
    void  slowTick(int consumed);
    std::string currentPos();

    Value getField(Value obj, StrObj* name, int sym);
    void  setField(Value obj, StrObj* name, Value v);
    Value getIndex(Value obj, Value idx);
    void  setIndex(Value obj, Value idx, Value v);
    Value objGet(ObjObj* o, StrObj* k);
    void  objSet(ObjObj* o, StrObj* k, Value v);
    bool  mapGet(MapObj* m, const Value& k, Value& out);
    void  mapSet(MapObj* m, const Value& k, const Value& v);
    bool  mapRemove(MapObj* m, const Value& k);
    Value makeIterator(Value src, bool kv = false);
    bool  iterNext(IterObj* it, Value& out);
    bool  iterNext2(IterObj* it, Value& k, Value& v);
    Value construct(const std::string& cls, Value* args, int argc);
    bool  isOfType(Value v, const std::string& type);

    std::string toStr(Value v, int depth = 0);
    bool        truthy(Value v) const;
    bool        equals(Value a, Value b);
    static std::string fmtFloat(double d);

    void installBuiltins();
    void defGlobalObj(const std::string& name, ObjObj* o);

    ~Impl();
};

Proto* compileProgram(VM::Impl& vm, Ast& ast, const std::string& origin, Program* info = nullptr);

}  // namespace ssvm

struct ssvm_vm {
    ssvm::VM vm;
    std::string error;
    std::string str;
    ssvm::Value result;
    std::vector<ssvm::ProgramPtr> programs;
};
