#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "internal.hpp"

namespace ssvm {

namespace {

inline bool isStr(const Value& v) { return v.t == Type::Obj && v.o->kind == K::String; }
inline StrObj* S(const Value& v) { return (StrObj*)v.o; }

struct Args {
    Value* a;
    int n;
    Value operator[](int i) const { return i < n ? a[i] : Value(); }
};

struct StackRoot {
    VM::Impl& I;
    explicit StackRoot(VM::Impl& impl, Value v) : I(impl) { *I.sp++ = v; }
    ~StackRoot() { I.sp--; }
};

int toInt(VM::Impl& I, const Value& v, const char* what) {
    if (v.t == Type::Int) return v.i;
    if (v.t == Type::Float) return toInt32(v.d);
    I.fail(std::string(what) + " expects a number");
}
int toIntOr(VM::Impl& I, const Value& v, int def, const char* what) {
    if (v.t == Type::Null) return def;
    return toInt(I, v, what);
}
const std::string& needStr(VM::Impl& I, const Value& v, const char* what) {
    if (!isStr(v)) I.fail(std::string(what) + " expects a String");
    return S(v)->s;
}
void needFn(VM::Impl& I, const Value& v, const char* what) {
    if (v.t != Type::Obj || (v.o->kind != K::Closure && v.o->kind != K::Native && v.o->kind != K::Bound))
        I.fail(std::string(what) + " expects a function");
}

double stampNow() {
    using namespace std::chrono;
    return duration<double>(system_clock::now().time_since_epoch()).count();
}

void mergeSort(VM::Impl& I, std::vector<Value>& v, const Value& cmp) {
    std::vector<Value> tmp(v.size());
    std::function<void(size_t, size_t)> rec = [&](size_t lo, size_t hi) {
        if (hi - lo < 2) return;
        size_t mid = (lo + hi) / 2;
        rec(lo, mid);
        rec(mid, hi);
        size_t i = lo, j = mid, k = lo;
        while (i < mid && j < hi) {
            Value args[2] = {v[j], v[i]};
            Value r = I.callClosureOrNative(cmp, args, 2);
            double c = r.t == Type::Int ? r.i : r.t == Type::Float ? r.d : 0;
            if (c < 0) tmp[k++] = v[j++];
            else tmp[k++] = v[i++];
        }
        while (i < mid) tmp[k++] = v[i++];
        while (j < hi) tmp[k++] = v[j++];
        for (size_t x = lo; x < hi; x++) v[x] = tmp[x];
    };
    rec(0, v.size());
}

int defaultCompare(VM::Impl& I, const Value& a, const Value& b) {
    if (a.t == Type::Int && b.t == Type::Int) return a.i < b.i ? -1 : a.i > b.i ? 1 : 0;
    if ((a.t == Type::Int || a.t == Type::Float) && (b.t == Type::Int || b.t == Type::Float)) {
        double x = a.asNumber(), y = b.asNumber();
        return x < y ? -1 : x > y ? 1 : 0;
    }
    if (isStr(a) && isStr(b)) { int c = S(a)->s.compare(S(b)->s); return c < 0 ? -1 : c > 0 ? 1 : 0; }
    std::string x = I.toStr(a), y = I.toStr(b);
    int c = x.compare(y);
    return c < 0 ? -1 : c > 0 ? 1 : 0;
}

std::string trimStr(const std::string& s, bool l, bool r) {
    size_t a = 0, b = s.size();
    auto sp = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; };
    if (l) while (a < b && sp(s[a])) a++;
    if (r) while (b > a && sp(s[b - 1])) b--;
    return s.substr(a, b - a);
}

Value arrayMethod(VM::Impl& I, ArrObj* arr, int sym, Args A) {
    std::vector<Value>& v = arr->v;
    Value self = Value::Object(arr);
    switch (sym) {
        case S_push: {
            for (int i = 0; i < A.n; i++) v.push_back(A.a[i]);
            return Value::Int((int32_t)v.size());
        }
        case S_pop: { if (v.empty()) return Value(); Value r = v.back(); v.pop_back(); return r; }
        case S_shift: { if (v.empty()) return Value(); Value r = v.front(); v.erase(v.begin()); return r; }
        case S_unshift: { v.insert(v.begin(), A[0]); return Value(); }
        case S_insert: {
            int pos = toInt(I, A[0], "insert");
            if (pos < 0) pos = std::max(0, (int)v.size() + pos);
            if ((size_t)pos > v.size()) pos = (int)v.size();
            v.insert(v.begin() + pos, A[1]);
            return Value();
        }
        case S_remove: {
            for (size_t i = 0; i < v.size(); i++) if (I.equals(v[i], A[0])) { v.erase(v.begin() + (long)i); return Value::Bool(true); }
            return Value::Bool(false);
        }
        case S_removeAt: {
            int i = toInt(I, A[0], "removeAt");
            if (i < 0 || (size_t)i >= v.size()) return Value();
            Value r = v[(size_t)i];
            v.erase(v.begin() + i);
            return r;
        }
        case S_indexOf: case S_lastIndexOf: {
            if (sym == S_indexOf) {
                int from = toIntOr(I, A[1], 0, "indexOf");
                if (from < 0) from = std::max(0, (int)v.size() + from);
                for (size_t i = (size_t)from; i < v.size(); i++) if (I.equals(v[i], A[0])) return Value::Int((int32_t)i);
            } else {
                int from = toIntOr(I, A[1], (int)v.size() - 1, "lastIndexOf");
                if (from >= (int)v.size()) from = (int)v.size() - 1;
                for (int i = from; i >= 0; i--) if (I.equals(v[(size_t)i], A[0])) return Value::Int(i);
            }
            return Value::Int(-1);
        }
        case S_contains: {
            for (auto& x : v) if (I.equals(x, A[0])) return Value::Bool(true);
            return Value::Bool(false);
        }
        case S_join: {
            std::string sep = isStr(A[0]) ? S(A[0])->s : (A.n == 0 ? "," : I.toStr(A[0]));
            std::string out;
            for (size_t i = 0; i < v.size(); i++) { if (i) out += sep; out += I.toStr(v[i]); }
            return I.strv(out);
        }
        case S_concat: {
            ArrObj* r = I.newArr();
            r->v = v;
            Value rv = Value::Object(r);
            if (A[0].t == Type::Obj && A[0].o->kind == K::Array) { auto& o = ((ArrObj*)A[0].o)->v; r->v.insert(r->v.end(), o.begin(), o.end()); }
            else I.fail("concat expects an Array");
            return rv;
        }
        case S_slice: {
            int n = (int)v.size();
            int a = toIntOr(I, A[0], 0, "slice"), b = toIntOr(I, A[1], n, "slice");
            if (a < 0) a = std::max(0, n + a);
            if (b < 0) b = std::max(0, n + b);
            if (b > n) b = n;
            ArrObj* r = I.newArr();
            if (a < b) r->v.assign(v.begin() + a, v.begin() + b);
            return Value::Object(r);
        }
        case S_splice: {
            int n = (int)v.size();
            int pos = toInt(I, A[0], "splice"), len = toInt(I, A[1], "splice");
            if (pos < 0) pos = std::max(0, n + pos);
            if (pos > n) pos = n;
            if (len < 0) len = 0;
            if (pos + len > n) len = n - pos;
            ArrObj* r = I.newArr();
            r->v.assign(v.begin() + pos, v.begin() + pos + len);
            v.erase(v.begin() + pos, v.begin() + pos + len);
            return Value::Object(r);
        }
        case S_reverse: std::reverse(v.begin(), v.end()); return Value();
        case S_sort: {
            if (A.n == 0 || A[0].t == Type::Null) {
                std::vector<Value> tmp = v;
                std::stable_sort(tmp.begin(), tmp.end(), [&](const Value& x, const Value& y) { return defaultCompare(I, x, y) < 0; });
                v = tmp;
            } else {
                needFn(I, A[0], "sort");
                std::vector<Value> tmp = v;
                ArrObj* hold = I.newArr();
                hold->v = tmp;
                StackRoot r(I, Value::Object(hold));
                mergeSort(I, hold->v, A[0]);
                v = hold->v;
            }
            return Value();
        }
        case S_copy: { ArrObj* r = I.newArr(); r->v = v; return Value::Object(r); }
        case S_resize: { int n = toInt(I, A[0], "resize"); if (n < 0) n = 0; v.resize((size_t)n); return Value(); }
        case S_fill: { for (auto& x : v) x = A[0]; return self; }
        case S_toString: return I.strv(I.toStr(self));
        case S_iterator: case S_keyValueIterator: {
            IterObj* it = I.newIter(IT_ARRAY);
            it->a = self;
            return Value::Object(it);
        }
        case S_map: case S_filter: case S_iter: case S_find: case S_findIndex: case S_some: case S_every: {
            needFn(I, A[0], "array callback");
            ArrObj* res = I.newArr();
            StackRoot r1(I, Value::Object(res));
            StackRoot r2(I, self);
            for (size_t i = 0; i < arr->v.size(); i++) {
                Value x = arr->v[i];
                Value cr = I.callClosureOrNative(A[0], &x, 1);
                switch (sym) {
                    case S_map: res->v.push_back(cr); break;
                    case S_filter: if (I.truthy(cr)) res->v.push_back(x); break;
                    case S_find: if (I.truthy(cr)) return x; break;
                    case S_findIndex: if (I.truthy(cr)) return Value::Int((int32_t)i); break;
                    case S_some: if (I.truthy(cr)) return Value::Bool(true); break;
                    case S_every: if (!I.truthy(cr)) return Value::Bool(false); break;
                    default: break;
                }
            }
            if (sym == S_find) return Value();
            if (sym == S_findIndex) return Value::Int(-1);
            if (sym == S_some) return Value::Bool(false);
            if (sym == S_every) return Value::Bool(true);
            if (sym == S_iter) return Value();
            return Value::Object(res);
        }
        case S_first: return v.empty() ? Value() : v.front();
        case S_last: return v.empty() ? Value() : v.back();
        default: break;
    }
    I.fail("Array has no method '" + I.syms[(size_t)sym]->s + "'");
}

Value stringMethod(VM::Impl& I, StrObj* so, int sym, Args A) {
    const std::string& s = so->s;
    switch (sym) {
        case S_charAt: {
            int i = toInt(I, A[0], "charAt");
            if (i < 0 || (size_t)i >= s.size()) return I.strv("");
            return I.strv(std::string(1, s[(size_t)i]));
        }
        case S_charCodeAt: {
            int i = toInt(I, A[0], "charCodeAt");
            if (i < 0 || (size_t)i >= s.size()) return Value();
            return Value::Int((unsigned char)s[(size_t)i]);
        }
        case S_indexOf: {
            int from = toIntOr(I, A[1], 0, "indexOf");
            if (from < 0) from = 0;
            size_t p = s.find(needStr(I, A[0], "indexOf"), (size_t)from);
            return Value::Int(p == std::string::npos ? -1 : (int32_t)p);
        }
        case S_lastIndexOf: {
            size_t from = A[1].t == Type::Null ? std::string::npos : (size_t)std::max(0, toInt(I, A[1], "lastIndexOf"));
            size_t p = s.rfind(needStr(I, A[0], "lastIndexOf"), from);
            return Value::Int(p == std::string::npos ? -1 : (int32_t)p);
        }
        case S_split: {
            const std::string& d = needStr(I, A[0], "split");
            ArrObj* r = I.newArr();
            Value rv = Value::Object(r);
            if (d.empty()) {
                for (char c : s) r->v.push_back(I.strv(std::string(1, c)));
                return rv;
            }
            size_t st = 0;
            for (;;) {
                size_t p = s.find(d, st);
                if (p == std::string::npos) { r->v.push_back(I.strv(s.substr(st))); break; }
                r->v.push_back(I.strv(s.substr(st, p - st)));
                st = p + d.size();
            }
            return rv;
        }
        case S_substr: {
            int n = (int)s.size();
            int pos = toInt(I, A[0], "substr");
            int len = toIntOr(I, A[1], n, "substr");
            if (pos < 0) pos = std::max(0, n + pos);
            if (pos > n || len <= 0) return I.strv("");
            if (pos + (long)len > n) len = n - pos;
            return I.strv(s.substr((size_t)pos, (size_t)len));
        }
        case S_substring: {
            int n = (int)s.size();
            int a = toInt(I, A[0], "substring"), b = toIntOr(I, A[1], n, "substring");
            a = std::max(0, std::min(a, n));
            b = std::max(0, std::min(b, n));
            if (a > b) std::swap(a, b);
            return I.strv(s.substr((size_t)a, (size_t)(b - a)));
        }
        case S_toLowerCase: { std::string r = s; for (auto& c : r) c = (char)tolower((unsigned char)c); return I.strv(r); }
        case S_toUpperCase: { std::string r = s; for (auto& c : r) c = (char)toupper((unsigned char)c); return I.strv(r); }
        case S_toString: return Value::Object(so);
        case S_trim: return I.strv(trimStr(s, true, true));
        case S_ltrim: return I.strv(trimStr(s, true, false));
        case S_rtrim: return I.strv(trimStr(s, false, true));
        case S_startsWith: { const std::string& p = needStr(I, A[0], "startsWith"); return Value::Bool(s.compare(0, p.size(), p) == 0); }
        case S_endsWith: { const std::string& p = needStr(I, A[0], "endsWith"); return Value::Bool(s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0); }
        case S_contains: return Value::Bool(s.find(needStr(I, A[0], "contains")) != std::string::npos);
        case S_replace: {
            const std::string& from = needStr(I, A[0], "replace");
            const std::string& to = needStr(I, A[1], "replace");
            if (from.empty()) return Value::Object(so);
            std::string r;
            size_t st = 0;
            for (;;) {
                size_t p = s.find(from, st);
                if (p == std::string::npos) { r += s.substr(st); break; }
                r += s.substr(st, p - st);
                r += to;
                st = p + from.size();
            }
            return I.strv(r);
        }
        case S_lpad: case S_rpad: {
            const std::string& pad = needStr(I, A[0], "pad");
            int len = toInt(I, A[1], "pad");
            if (pad.empty()) return Value::Object(so);
            std::string r = s, fill;
            while ((int)(r.size() + fill.size()) < len) fill += pad;
            return I.strv(sym == S_lpad ? fill + r : r + fill);
        }
        case S_iterator: case S_keyValueIterator: { IterObj* it = I.newIter(IT_STRING); it->a = Value::Object(so); return Value::Object(it); }
        case S_toInt: { return Value::Int((int32_t)strtol(s.c_str(), nullptr, 10)); }
        case S_toFloat: { return Value::Float(strtod(s.c_str(), nullptr)); }
        default: break;
    }
    I.fail("String has no method '" + I.syms[(size_t)sym]->s + "'");
}

Value mapMethod(VM::Impl& I, MapObj* m, int sym, Args A) {
    Value self = Value::Object(m);
    switch (sym) {
        case S_set: I.mapSet(m, A[0], A[1]); return Value();
        case S_get: { Value out; I.mapGet(m, A[0], out); return out; }
        case S_exists: { Value out; return Value::Bool(I.mapGet(m, A[0], out)); }
        case S_remove: return Value::Bool(I.mapRemove(m, A[0]));
        case S_clear: m->idx.clear(); m->ents.clear(); m->live = 0; return Value();
        case S_copy: {
            MapObj* r = I.newMap();
            for (auto& e : m->ents) if (e.alive) I.mapSet(r, e.k, e.v);
            return Value::Object(r);
        }
        case S_keys: { IterObj* it = I.newIter(IT_MAPKEYS); it->a = self; return Value::Object(it); }
        case S_iterator: { IterObj* it = I.newIter(IT_MAPVALS); it->a = self; return Value::Object(it); }
        case S_keyValueIterator: { IterObj* it = I.newIter(IT_MAPKV); it->a = self; return Value::Object(it); }
        case S_toString: return I.strv(I.toStr(self));
        case S_isEmpty: return Value::Bool(m->live == 0);
        default: break;
    }
    I.fail("Map has no method '" + I.syms[(size_t)sym]->s + "'");
}

bool iterHasNext(VM::Impl& I, IterObj* it) {
    switch (it->type) {
        case IT_ARRAY: return (size_t)it->i < ((ArrObj*)it->a.o)->v.size();
        case IT_MAPKEYS: case IT_MAPVALS: case IT_MAPKV: {
            MapObj* m = (MapObj*)it->a.o;
            while ((size_t)it->i < m->ents.size() && !m->ents[(size_t)it->i].alive) it->i++;
            return (size_t)it->i < m->ents.size();
        }
        case IT_RANGE: return it->i < it->n;
        case IT_STRING: return (size_t)it->i < S(it->a)->s.size();
        case IT_CUSTOM: {
            Value hn = I.objGet((ObjObj*)it->a.o, I.syms[S_hasNext]);
            return I.truthy(I.callClosureOrNative(hn, nullptr, 0));
        }
        case IT_HOST: return I.truthy(I.hostMethod(it->a, "hasNext", nullptr, 0));
    }
    return false;
}

Value regexMethod(VM::Impl& I, RegexObj* r, int sym, Args A) {
    auto flagsOf = [&]() {
        auto f = std::regex::ECMAScript;
        if (r->flags.find('i') != std::string::npos) f |= std::regex::icase;
        return f;
    };
    (void)flagsOf;
    switch (sym) {
        case S_match: {
            r->subject = needStr(I, A[0], "match");
            r->matched = std::regex_search(r->subject, r->m, r->re);
            return Value::Bool(r->matched);
        }
        case S_matched: {
            if (!r->matched) I.fail("EReg::matched: no match");
            int i = toIntOr(I, A[0], 0, "matched");
            if (i < 0 || (size_t)i >= r->m.size()) I.fail("EReg::matched: invalid group");
            if (!r->m[(size_t)i].matched) return Value();
            return I.strv(r->m[(size_t)i].str());
        }
        case S_matchedLeft: if (!r->matched) I.fail("EReg::matchedLeft: no match"); return I.strv(r->m.prefix().str());
        case S_matchedRight: if (!r->matched) I.fail("EReg::matchedRight: no match"); return I.strv(r->m.suffix().str());
        case S_matchedPos: {
            if (!r->matched) I.fail("EReg::matchedPos: no match");
            ObjObj* o = I.newObj();
            I.objSet(o, I.intern("pos"), Value::Int((int32_t)r->m.position(0)));
            I.objSet(o, I.intern("len"), Value::Int((int32_t)r->m.length(0)));
            return Value::Object(o);
        }
        case S_replace: {
            const std::string& s = needStr(I, A[0], "replace");
            std::string by = needStr(I, A[1], "replace");
            auto fl = std::regex_constants::format_default;
            if (r->flags.find('g') == std::string::npos) fl |= std::regex_constants::format_first_only;
            return I.strv(std::regex_replace(s, r->re, by, fl));
        }
        case S_split: {
            const std::string& s = needStr(I, A[0], "split");
            ArrObj* out = I.newArr();
            Value ov = Value::Object(out);
            std::sregex_iterator it(s.begin(), s.end(), r->re), end;
            size_t last = 0;
            bool g = r->flags.find('g') != std::string::npos;
            for (; it != end; ++it) {
                out->v.push_back(I.strv(s.substr(last, (size_t)it->position(0) - last)));
                last = (size_t)(it->position(0) + it->length(0));
                if (!g) break;
            }
            out->v.push_back(I.strv(s.substr(last)));
            return ov;
        }
        case S_toString: return I.strv(I.toStr(Value::Object(r)));
        default: break;
    }
    I.fail("EReg has no method '" + I.syms[(size_t)sym]->s + "'");
}

}  // namespace

static size_t growableBytes(const Value& v) {
    if (v.t != Type::Obj) return 0;
    if (v.o->kind == K::Array) return ((ArrObj*)v.o)->v.capacity() * sizeof(Value);
    if (v.o->kind == K::StrBuf) return ((BufObj*)v.o)->s.capacity();
    return 0;
}

Value VM::Impl::callMethodByName(Value self, int sym, Value* args, int argc) {
    size_t before = growableBytes(self);
    Value r = callMethodRaw(self, sym, args, argc);
    size_t after = growableBytes(self);
    if (after > before) noteGrowth(after - before);
    if (r.t == Type::Obj && r.o != self.o && r.o->kind == K::Array) noteGrowth(growableBytes(r));
    return r;
}

Value VM::Impl::callMethodRaw(Value self, int sym, Value* args, int argc) {
    Args A{args, argc};
    switch (self.o->kind) {
        case K::Host: return hostMethod(self, syms[(size_t)sym]->s, args, argc);
        case K::Array: return arrayMethod(*this, (ArrObj*)self.o, sym, A);
        case K::String: return stringMethod(*this, (StrObj*)self.o, sym, A);
        case K::Map: return mapMethod(*this, (MapObj*)self.o, sym, A);
        case K::StrBuf: {
            BufObj* b = (BufObj*)self.o;
            switch (sym) {
                case S_add: b->s += toStr(A[0]); return Value();
                case S_addChar: b->s += (char)toInt(*this, A[0], "addChar"); return Value();
                case S_addSub: {
                    const std::string& s = needStr(*this, A[0], "addSub");
                    int pos = toInt(*this, A[1], "addSub");
                    int len = toIntOr(*this, A[2], (int)s.size() - pos, "addSub");
                    if (pos >= 0 && (size_t)pos <= s.size() && len > 0) b->s += s.substr((size_t)pos, (size_t)len);
                    return Value();
                }
                case S_toString: return strv(b->s);
                case S_clear: b->s.clear(); return Value();
                default: break;
            }
            fail("StringBuf has no method '" + syms[(size_t)sym]->s + "'");
        }
        case K::Iter: {
            IterObj* it = (IterObj*)self.o;
            if (sym == S_hasNext) return Value::Bool(iterHasNext(*this, it));
            if (sym == S_next) {
                Value out;
                if (!iterNext(it, out)) fail("No more elements");
                return out;
            }
            if (sym == S_iterator) return self;
            fail("Iterator has no method '" + syms[(size_t)sym]->s + "'");
        }
        case K::Regex: return regexMethod(*this, (RegexObj*)self.o, sym, A);
        case K::Closure: case K::Native: case K::Bound:
            if (sym == S_call) return callClosureOrNative(self, args, argc);
            if (sym == S_apply) {
                Value arr = A[1];
                if (arr.t == Type::Obj && arr.o->kind == K::Array) {
                    auto& v = ((ArrObj*)arr.o)->v;
                    return callClosureOrNative(self, v.data(), (int)v.size());
                }
                return callClosureOrNative(self, nullptr, 0);
            }
            fail("Function has no method '" + syms[(size_t)sym]->s + "'");
        default: break;
    }
    fail("Cannot call method '" + syms[(size_t)sym]->s + "'");
}

bool VM::Impl::isOfType(Value v, const std::string& t) {
    if (t == "Dynamic" || t == "Any") return true;
    switch (v.t) {
        case Type::Undef: case Type::Null: return false;
        case Type::Int: return t == "Int" || t == "Float" || t == "Number";
        case Type::Float: return t == "Float" || t == "Number";
        case Type::Bool: return t == "Bool";
        case Type::Obj: break;
    }
    switch (v.o->kind) {
        case K::String: return t == "String";
        case K::Array: return t == "Array";
        case K::Map: return t == "Map" || t == "StringMap" || t == "IntMap" || t == "ObjectMap" || t == "haxe.ds.StringMap" || t == "haxe.ds.IntMap";
        case K::Object: return t == "Object" || t == "Dynamic";
        case K::Closure: case K::Native: case K::Bound: return t == "Function";
        case K::StrBuf: return t == "StringBuf";
        case K::Regex: return t == "EReg";
        case K::Iter: return t == "Iterator";
        case K::Host: {
            HostObj* h = (HostObj*)v.o;
            return hcb.isType ? hcb.isType(h->id, t.c_str()) != 0 : false;
        }
        default: return false;
    }
}

Value VM::Impl::construct(const std::string& cls, Value* args, int argc) {
    auto it = classes.find(cls);
    if (it == classes.end()) {
        auto g = globalIndex.find(cls);
        if (g != globalIndex.end() && globals[(size_t)g->second].t == Type::Obj && globals[(size_t)g->second].o->kind == K::Host)
            return hostNew(globals[(size_t)g->second], args, argc);
        fail("Type not found: " + cls);
    }
    return it->second(*vm, args, argc);
}

void VM::Impl::defGlobalObj(const std::string& name, ObjObj* o) {
    globals[(size_t)globalSlot(name)] = Value::Object(o);
}

void VM::Impl::installBuiltins() {
    VM::Impl& I = *this;
    auto fnField = [&](ObjObj* o, const char* name, NativeFn fn) {
        objSet(o, intern(name), Value::Object(newNative(name, std::move(fn))));
    };
    auto numArg = [&](Value* a, int n, int i, const char* who) -> double {
        if (i >= n || !(a[i].t == Type::Int || a[i].t == Type::Float)) I.fail(std::string(who) + " expects a number");
        return a[i].asNumber();
    };
    auto classObj = [&](const char* name) {
        ObjObj* o = newObj();
        objSet(o, syms[S___name], Value::Object(intern(name)));
        defGlobalObj(name, o);
        return o;
    };

    globals[(size_t)globalSlot("trace")] = Value::Object(newNative("trace", [&I](VM&, Value* a, int n) {
        std::string pos = I.currentPos();
        size_t c = pos.rfind(':');
        std::string origin = c == std::string::npos ? pos : pos.substr(0, c);
        int line = c == std::string::npos ? 0 : atoi(pos.c_str() + c + 1);
        I.traceOut(origin, line, a, n);
        return Value();
    }));

    {
        ObjObj* m = classObj("Math");
        objSet(m, intern("PI"), Value::Float(3.14159265358979323846));
        objSet(m, intern("NaN"), Value::Float(std::nan("")));
        objSet(m, intern("POSITIVE_INFINITY"), Value::Float(INFINITY));
        objSet(m, intern("NEGATIVE_INFINITY"), Value::Float(-INFINITY));
#define MATH1(NAME, EXPR)                                                                   \
        fnField(m, NAME, [numArg](VM&, Value* a, int n) { double x = numArg(a, n, 0, "Math." NAME); return Value::Float(EXPR); });
        MATH1("sin", std::sin(x)) MATH1("cos", std::cos(x)) MATH1("tan", std::tan(x))
        MATH1("asin", std::asin(x)) MATH1("acos", std::acos(x)) MATH1("atan", std::atan(x))
        MATH1("exp", std::exp(x)) MATH1("log", std::log(x)) MATH1("sqrt", std::sqrt(x))
        MATH1("ffloor", std::floor(x)) MATH1("fceil", std::ceil(x)) MATH1("fround", std::floor(x + 0.5))
#undef MATH1
        fnField(m, "abs", [numArg](VM&, Value* a, int n) {
            numArg(a, n, 0, "Math.abs");
            if (a[0].t == Type::Int) return Value::Int(a[0].i < 0 ? -a[0].i : a[0].i);
            return Value::Float(std::fabs(a[0].d));
        });
        auto toI = [](double d) -> Value {
            if (std::isnan(d) || std::isinf(d) || std::fabs(d) > 2147483647.0) return Value::Float(d);
            return Value::Int((int32_t)d);
        };
        fnField(m, "floor", [numArg, toI](VM&, Value* a, int n) { return toI(std::floor(numArg(a, n, 0, "Math.floor"))); });
        fnField(m, "ceil", [numArg, toI](VM&, Value* a, int n) { return toI(std::ceil(numArg(a, n, 0, "Math.ceil"))); });
        fnField(m, "round", [numArg, toI](VM&, Value* a, int n) { return toI(std::floor(numArg(a, n, 0, "Math.round") + 0.5)); });
        fnField(m, "atan2", [numArg](VM&, Value* a, int n) { return Value::Float(std::atan2(numArg(a, n, 0, "Math.atan2"), numArg(a, n, 1, "Math.atan2"))); });
        fnField(m, "pow", [numArg](VM&, Value* a, int n) { return Value::Float(std::pow(numArg(a, n, 0, "Math.pow"), numArg(a, n, 1, "Math.pow"))); });
        fnField(m, "min", [numArg](VM&, Value* a, int n) {
            double x = numArg(a, n, 0, "Math.min"), y = numArg(a, n, 1, "Math.min");
            if (std::isnan(x) || std::isnan(y)) return Value::Float(std::nan(""));
            return x <= y ? a[0] : a[1];
        });
        fnField(m, "max", [numArg](VM&, Value* a, int n) {
            double x = numArg(a, n, 0, "Math.max"), y = numArg(a, n, 1, "Math.max");
            if (std::isnan(x) || std::isnan(y)) return Value::Float(std::nan(""));
            return x >= y ? a[0] : a[1];
        });
        fnField(m, "random", [](VM&, Value*, int) {
            static uint64_t s = 0x9E3779B97F4A7C15ull ^ (uint64_t)std::chrono::steady_clock::now().time_since_epoch().count();
            s ^= s << 13; s ^= s >> 7; s ^= s << 17;
            return Value::Float((double)(s >> 11) / 9007199254740992.0);
        });
        fnField(m, "isNaN", [numArg](VM&, Value* a, int n) { return Value::Bool(std::isnan(numArg(a, n, 0, "Math.isNaN"))); });
        fnField(m, "isFinite", [numArg](VM&, Value* a, int n) { return Value::Bool(std::isfinite(numArg(a, n, 0, "Math.isFinite"))); });
    }

    {
        ObjObj* s = classObj("Std");
        fnField(s, "string", [&I](VM&, Value* a, int n) { return I.strv(I.toStr(n ? a[0] : Value())); });
        fnField(s, "int", [numArg](VM&, Value* a, int n) {
            double d = numArg(a, n, 0, "Std.int");
            if (std::isnan(d) || std::isinf(d)) return Value::Int(0);
            return Value::Int((int32_t)(int64_t)d);
        });
        fnField(s, "parseInt", [&I](VM&, Value* a, int n) {
            if (n < 1 || !isStr(a[0])) return Value();
            const std::string& str = S(a[0])->s;
            const char* p = str.c_str();
            while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
            char* end;
            bool hex = (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) || ((p[0] == '-' || p[0] == '+') && p[1] == '0' && (p[2] == 'x' || p[2] == 'X'));
            long long v = strtoll(p, &end, hex ? 16 : 10);
            if (end == p) return Value();
            (void)I;
            return Value::Int((int32_t)v);
        });
        fnField(s, "parseFloat", [](VM&, Value* a, int n) {
            if (n < 1 || !isStr(a[0])) return Value::Float(std::nan(""));
            const char* p = S(a[0])->s.c_str();
            char* end;
            double d = strtod(p, &end);
            if (end == p) return Value::Float(std::nan(""));
            return Value::Float(d);
        });
        fnField(s, "random", [numArg](VM&, Value* a, int n) {
            int m = (int)numArg(a, n, 0, "Std.random");
            if (m <= 0) return Value::Int(0);
            return Value::Int(rand() % m);
        });
        auto isOf = [&I](VM&, Value* a, int n) {
            if (n < 2) return Value::Bool(false);
            std::string tn;
            if (a[1].t == Type::Obj && a[1].o->kind == K::Object) {
                Value nm = I.objGet((ObjObj*)a[1].o, I.syms[S___name]);
                if (isStr(nm)) tn = S(nm)->s;
            }
            return Value::Bool(I.isOfType(a[0], tn));
        };
        fnField(s, "isOfType", isOf);
        fnField(s, "is", isOf);
    }

    {
        const char* names[] = {"Int", "Float", "Bool", "Dynamic", "Any", "Map", "StringMap", "IntMap", "ObjectMap", "StringBuf", "EReg", "Function", nullptr};
        for (int i = 0; names[i]; i++) classObj(names[i]);
        ObjObj* arr = classObj("Array");
        (void)arr;
        ObjObj* str = classObj("String");
        fnField(str, "fromCharCode", [&I](VM&, Value* a, int n) {
            int c = n ? toInt(I, a[0], "String.fromCharCode") : 0;
            std::string s;
            if (c < 0x80) s += (char)c;
            else if (c < 0x800) { s += (char)(0xC0 | (c >> 6)); s += (char)(0x80 | (c & 0x3F)); }
            else { s += (char)(0xE0 | (c >> 12)); s += (char)(0x80 | ((c >> 6) & 0x3F)); s += (char)(0x80 | (c & 0x3F)); }
            return I.strv(s);
        });
    }

    {
        ObjObj* st = classObj("StringTools");
        struct M { const char* name; int sym; };
        static const M ms[] = {{"trim", S_trim}, {"ltrim", S_ltrim}, {"rtrim", S_rtrim}, {"startsWith", S_startsWith},
                               {"endsWith", S_endsWith}, {"contains", S_contains}, {"replace", S_replace}, {"lpad", S_lpad}, {"rpad", S_rpad}};
        for (const M& m : ms) {
            int sym = m.sym;
            fnField(st, m.name, [&I, sym](VM&, Value* a, int n) {
                if (n < 1 || !isStr(a[0])) I.fail("StringTools expects a String");
                return I.callMethodByName(a[0], sym, a + 1, n - 1);
            });
        }
        fnField(st, "hex", [&I](VM&, Value* a, int n) {
            unsigned v = (unsigned)toInt(I, n ? a[0] : Value(), "StringTools.hex");
            int digits = n > 1 ? toInt(I, a[1], "StringTools.hex") : 0;
            char buf[32];
            snprintf(buf, sizeof buf, "%X", v);
            std::string s = buf;
            while ((int)s.size() < digits) s = "0" + s;
            return I.strv(s);
        });
    }

    {
        ObjObj* r = classObj("Reflect");
        fnField(r, "field", [&I](VM&, Value* a, int n) {
            if (n < 2 || !isStr(a[1])) return Value();
            if (a[0].t == Type::Null) return Value();
            StrObj* k = I.intern(S(a[1])->s);
            return I.getField(a[0], k, k->sym);
        });
        fnField(r, "setField", [&I](VM&, Value* a, int n) {
            if (n < 3 || !isStr(a[1])) I.fail("Reflect.setField expects (obj, name, value)");
            I.setField(a[0], I.intern(S(a[1])->s), a[2]);
            return Value();
        });
        fnField(r, "hasField", [&I](VM&, Value* a, int n) {
            if (n < 2 || !isStr(a[1]) || a[0].t != Type::Obj || a[0].o->kind != K::Object) return Value::Bool(false);
            StrObj* k = I.intern(S(a[1])->s);
            for (auto& f : ((ObjObj*)a[0].o)->f) if (f.k == k) return Value::Bool(true);
            return Value::Bool(false);
        });
        fnField(r, "fields", [&I](VM&, Value* a, int n) {
            ArrObj* out = I.newArr();
            if (n >= 1 && a[0].t == Type::Obj && a[0].o->kind == K::Object)
                for (auto& f : ((ObjObj*)a[0].o)->f) out->v.push_back(Value::Object(f.k));
            return Value::Object(out);
        });
        fnField(r, "deleteField", [&I](VM&, Value* a, int n) {
            if (n < 2 || !isStr(a[1]) || a[0].t != Type::Obj || a[0].o->kind != K::Object) return Value::Bool(false);
            StrObj* k = I.intern(S(a[1])->s);
            auto& f = ((ObjObj*)a[0].o)->f;
            for (size_t i = 0; i < f.size(); i++) if (f[i].k == k) { f.erase(f.begin() + (long)i); return Value::Bool(true); }
            return Value::Bool(false);
        });
        fnField(r, "isFunction", [](VM&, Value* a, int n) {
            return Value::Bool(n >= 1 && a[0].t == Type::Obj && (a[0].o->kind == K::Closure || a[0].o->kind == K::Native || a[0].o->kind == K::Bound));
        });
        fnField(r, "isObject", [](VM&, Value* a, int n) { return Value::Bool(n >= 1 && a[0].t == Type::Obj && a[0].o->kind == K::Object); });
        fnField(r, "callMethod", [&I](VM&, Value* a, int n) {
            if (n < 2) I.fail("Reflect.callMethod expects (obj, fn, args)");
            if (n >= 3 && a[2].t == Type::Obj && a[2].o->kind == K::Array) {
                auto& v = ((ArrObj*)a[2].o)->v;
                return I.callClosureOrNative(a[1], v.data(), (int)v.size());
            }
            return I.callClosureOrNative(a[1], nullptr, 0);
        });
        fnField(r, "copy", [&I](VM&, Value* a, int n) {
            if (n < 1 || a[0].t != Type::Obj || a[0].o->kind != K::Object) return n ? a[0] : Value();
            ObjObj* o = I.newObj();
            o->f = ((ObjObj*)a[0].o)->f;
            return Value::Object(o);
        });
    }

    {
        ObjObj* sys = classObj("Sys");
        fnField(sys, "time", [](VM&, Value*, int) { return Value::Float(stampNow()); });
        fnField(sys, "println", [&I](VM&, Value* a, int n) { I.printer(n ? I.toStr(a[0]) : std::string()); return Value(); });
        fnField(sys, "print", [&I](VM&, Value* a, int n) { std::string s = n ? I.toStr(a[0]) : std::string(); fwrite(s.data(), 1, s.size(), stdout); return Value(); });
        fnField(sys, "cpuTime", [](VM&, Value*, int) { return Value::Float((double)clock() / CLOCKS_PER_SEC); });
        ObjObj* haxe = newObj();
        ObjObj* timer = newObj();
        fnField(timer, "stamp", [](VM&, Value*, int) { return Value::Float(stampNow()); });
        objSet(haxe, intern("Timer"), Value::Object(timer));
        defGlobalObj("haxe", haxe);
        globals[(size_t)globalSlot("Timer")] = Value::Object(timer);
    }

    classes["Array"] = [&I](VM&, Value*, int) { return Value::Object(I.newArr()); };
    auto mk = [&I](VM&, Value*, int) { return Value::Object(I.newMap()); };
    for (const char* n : {"Map", "StringMap", "IntMap", "ObjectMap", "haxe.ds.StringMap", "haxe.ds.IntMap", "haxe.ds.ObjectMap", "haxe.ds.Map"})
        classes[n] = mk;
    classes["StringBuf"] = [&I](VM&, Value*, int) { return Value::Object(I.alloc<BufObj>()); };
    classes["EReg"] = [&I](VM&, Value* a, int n) {
        if (n < 1 || !isStr(a[0])) I.fail("EReg expects (pattern, flags)");
        RegexObj* r = I.alloc<RegexObj>(256);
        r->src = S(a[0])->s;
        r->flags = (n > 1 && isStr(a[1])) ? S(a[1])->s : "";
        auto f = std::regex::ECMAScript;
        if (r->flags.find('i') != std::string::npos) f |= std::regex::icase;
        r->re = std::regex(r->src, f);
        return Value::Object(r);
    };
    classes["Object"] = [&I](VM&, Value*, int) { return Value::Object(I.newObj()); };

    for (size_t i = 0; i < globalNames.size(); i++)
        if (globals[i].t != Type::Undef) builtinNames.insert(globalNames[i]);
}

}  // namespace ssvm
