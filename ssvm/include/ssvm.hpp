#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace ssvm {

struct Obj;
class VM;

enum class Type : uint8_t { Undef, Null, Bool, Int, Float, Obj };

struct Value {
    Type t;
    union {
        bool b;
        int32_t i;
        double d;
        Obj* o;
    };

    Value() : t(Type::Null), d(0) {}
    static Value Null() { return Value(); }
    static Value Bool(bool v) { Value r; r.t = Type::Bool; r.d = 0; r.b = v; return r; }
    static Value Int(int32_t v) { Value r; r.t = Type::Int; r.d = 0; r.i = v; return r; }
    static Value Float(double v) { Value r; r.t = Type::Float; r.d = v; return r; }
    static Value Object(Obj* p) { Value r; r.t = Type::Obj; r.o = p; return r; }

    bool isNull() const { return t == Type::Null; }
    bool isBool() const { return t == Type::Bool; }
    bool isInt() const { return t == Type::Int; }
    bool isFloat() const { return t == Type::Float; }
    bool isNumber() const { return t == Type::Int || t == Type::Float; }
    bool isObj() const { return t == Type::Obj; }
    double asNumber() const { return t == Type::Int ? (double)i : d; }
};

class Error : public std::runtime_error {
public:
    explicit Error(const std::string& m) : std::runtime_error(m) {}
};

using NativeFn = std::function<Value(VM& vm, Value* args, int argc)>;

struct Program;
struct ProgramDeleter { void operator()(Program*) const; };
using ProgramPtr = std::unique_ptr<Program, ProgramDeleter>;

class VM {
public:
    VM();
    ~VM();
    VM(const VM&) = delete;
    VM& operator=(const VM&) = delete;

    ProgramPtr compile(const std::string& source, const std::string& origin = "SScript");
    Value run(Program* program);
    Value eval(const std::string& source, const std::string& origin = "SScript");
    Value evalFile(const std::string& path);

    bool  has(const std::string& name) const;
    Value get(const std::string& name) const;
    void  set(const std::string& name, Value v);
    void  def(const std::string& name, NativeFn fn);

    Value call(const std::string& fnName, const std::vector<Value>& args = {});
    Value callValue(Value fn, const std::vector<Value>& args = {});
    Value callValue(Value fn, const Value* args, int argc);

    Value       str(const std::string& s);
    std::string toString(Value v);
    Value       newArray();
    void        arrayPush(Value arr, Value v);
    int         arrayLength(Value arr);
    Value       arrayGet(Value arr, int idx);
    Value       newObject();
    void        setField(Value obj, const std::string& name, Value v);
    Value       getField(Value obj, const std::string& name);
    bool        isString(Value v) const;
    bool        isArray(Value v) const;
    bool        isFunction(Value v) const;
    std::string stringValue(Value v) const;

    void pin(Value v);
    void unpin(Value v);

    [[noreturn]] void error(const std::string& message);

    void setPrintHandler(std::function<void(const std::string&)> h);
    void setTickLimit(uint64_t ticks);
    void setTimeLimitMs(double ms);
    void collectGarbage();

    struct Impl;
    Impl* impl() { return impl_; }
private:
    Impl* impl_;
};

}  // namespace ssvm

extern "C" {
typedef struct ssvm_vm ssvm_vm;

ssvm_vm*    ssvm_create(void);
void        ssvm_destroy(ssvm_vm*);
int         ssvm_eval(ssvm_vm*, const char* source, const char* origin);
const char* ssvm_last_error(ssvm_vm*);

void        ssvm_set_int(ssvm_vm*, const char* name, int value);
void        ssvm_set_float(ssvm_vm*, const char* name, double value);
void        ssvm_set_bool(ssvm_vm*, const char* name, int value);
void        ssvm_set_string(ssvm_vm*, const char* name, const char* value);
void        ssvm_set_null(ssvm_vm*, const char* name);

int         ssvm_has(ssvm_vm*, const char* name);
int         ssvm_get_int(ssvm_vm*, const char* name, int fallback);
double      ssvm_get_float(ssvm_vm*, const char* name, double fallback);
int         ssvm_get_bool(ssvm_vm*, const char* name, int fallback);
const char* ssvm_get_string(ssvm_vm*, const char* name);

int         ssvm_call(ssvm_vm*, const char* fn, int argc, const char* types, const double* nums, const char* const* strs);
const char* ssvm_result_string(ssvm_vm*);
double      ssvm_result_number(ssvm_vm*);

void        ssvm_set_tick_limit(ssvm_vm*, unsigned long long ticks);
void        ssvm_set_time_limit_ms(ssvm_vm*, double ms);

void ssvm_set_callbacks(ssvm_vm*,
    int (*get)(int, const char*), int (*set)(int, const char*, int),
    int (*call)(int, int, int*), int (*method)(int, const char*, int, int*),
    int (*construct)(int, int, int*), int (*getIdx)(int, int), int (*setIdx)(int, int, int),
    int (*equals)(int, int), const char* (*toStr)(int), void (*release)(int),
    void (*print)(const char*, int, int, const char**), int (*isType)(int, const char*));
int         ssvm_compile(ssvm_vm*, const char* source, const char* origin);
const char* ssvm_program_unsupported(ssvm_vm*, int prog);
int         ssvm_program_need_count(ssvm_vm*, int prog);
const char* ssvm_program_need(ssvm_vm*, int prog, int i);
int         ssvm_program_declared_count(ssvm_vm*, int prog);
const char* ssvm_program_declared(ssvm_vm*, int prog, int i);
int         ssvm_program_import_count(ssvm_vm*, int prog);
const char* ssvm_program_import_name(ssvm_vm*, int prog, int i);
const char* ssvm_program_import_path(ssvm_vm*, int prog, int i);
int         ssvm_run(ssvm_vm*, int prog);
int         ssvm_result_ref(ssvm_vm*);
int         ssvm_has_global(ssvm_vm*, const char*);
int         ssvm_global_is_builtin(ssvm_vm*, const char*);
void        ssvm_undef_global(ssvm_vm*, const char*);
int         ssvm_get_global_ref(ssvm_vm*, const char*);
void        ssvm_set_global_ref(ssvm_vm*, const char*, int ref);
void        ssvm_self_clear(ssvm_vm*);
void        ssvm_self_field(ssvm_vm*, const char* name);
void        ssvm_self_bind(ssvm_vm*, int ref);
int         ssvm_self_active(ssvm_vm*);
int         ssvm_call_global(ssvm_vm*, const char* name, int argc, const int* args);
int         ssvm_call_ref(ssvm_vm*, int fnRef, int argc, const int* args);
int         ssvm_error_ref(ssvm_vm*);
void        ssvm_set_host_error(ssvm_vm*, int ref);
int         ssvm_ref_null(ssvm_vm*);
int         ssvm_ref_bool(ssvm_vm*, int);
int         ssvm_ref_int(ssvm_vm*, int);
int         ssvm_ref_float(ssvm_vm*, double);
int         ssvm_ref_string(ssvm_vm*, const char*);
int         ssvm_ref_host(ssvm_vm*, int id);
int         ssvm_ref_dup(ssvm_vm*, int ref);
void        ssvm_ref_free(ssvm_vm*, int ref);
int         ssvm_ref_type(ssvm_vm*, int ref);
int         ssvm_ref_get_int(ssvm_vm*, int ref);
double      ssvm_ref_get_float(ssvm_vm*, int ref);
int         ssvm_ref_get_bool(ssvm_vm*, int ref);
const char* ssvm_ref_get_string(ssvm_vm*, int ref);
int         ssvm_ref_host_id(ssvm_vm*, int ref);
int         ssvm_ref_array_len(ssvm_vm*, int ref);
int         ssvm_ref_array_get(ssvm_vm*, int ref, int i);
int         ssvm_ref_object_len(ssvm_vm*, int ref);
const char* ssvm_ref_object_key(ssvm_vm*, int ref, int i);
int         ssvm_ref_object_val(ssvm_vm*, int ref, int i);
int         ssvm_ref_map_raw_len(ssvm_vm*, int ref);
int         ssvm_ref_map_key(ssvm_vm*, int ref, int i);
int         ssvm_ref_map_val(ssvm_vm*, int ref, int i);
}
