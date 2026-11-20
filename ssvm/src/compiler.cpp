#include <memory>

#include "internal.hpp"

namespace ssvm {

namespace {

enum UseKind { U_GET, U_SET, U_SETP, U_DECL, U_INC };

struct VarInfo {
    std::string name;
    int slot = 0;
    bool captured = false;
    bool isFinal = false;
    bool isParam = false;
    struct Use { int pc; int kind; };
    std::vector<Use> uses;
};

struct LoopCtx {
    std::vector<int> breaks;
    std::vector<int> continues;
    int continueTarget = -1;
    int tryDepth = 0;
};

struct FuncState {
    FuncState* parent = nullptr;
    Proto* p = nullptr;
    std::vector<std::vector<VarInfo*>> scopes;
    std::vector<int> scopeStart;
    std::vector<std::unique_ptr<VarInfo>> vars;
    int nextSlot = 0, maxSlot = 0;
    std::vector<std::string> upNames;
    std::vector<VarInfo*> upVars;
    std::vector<LoopCtx> loops;
    int tryDepth = 0;
    bool isMain = false;
    std::unordered_map<std::string, int> strConsts;
    std::unordered_map<int64_t, int> numConsts;
};

struct Res {
    enum Kind { Local, Up, Global, Self } k = Global;
    VarInfo* v = nullptr;
    int idx = 0;
    int sym = 0;
};

class Compiler {
public:
    Compiler(VM::Impl& vm, const std::string& origin) : vm_(vm), origin_(origin) {}

    Proto* compileMain(Node* root, Program* info = nullptr) {
        info_ = info;
        FuncState fs;
        fs.isMain = true;
        fs.p = newProto("<main>");
        fs_ = &fs;
        collectTopLevel(root);
        emit(OP_NOP);
        block(root, true);
        emit(OP_RET);
        finishFunction(fs);
        fs_ = nullptr;
        if (info_) {
            for (auto& n : usedOrder_) if (!declared_.count(n)) info_->needs.push_back(n);
            info_->eagerNeeds = eager_;
            for (auto& n : declared_) info_->declared.push_back(n);
        }
        return fs.p;
    }

private:
    VM::Impl& vm_;
    std::string origin_;
    FuncState* fs_ = nullptr;
    int line_ = 1;
    Program* info_ = nullptr;
    bool conditionalNeeds_ = false;
    std::vector<std::string> usedOrder_;
    std::unordered_set<std::string> used_, declared_;
    std::unordered_set<std::string> eager_;
    std::unordered_set<std::string> topDeclared_, scriptTypes_;
    void collectTopLevel(Node* root) {
        if (!root) return;
        for (Node* st : root->list) {
            if (!st) continue;
            if (st->k == N::Var) {topDeclared_.insert(st->s);if(st->s2=="__ss_enum"||st->s2=="__ss_type")scriptTypes_.insert(st->s);}
            else if (st->k == N::Vars) { for (Node* v : st->list) if (v) topDeclared_.insert(v->s); }
            else if (st->k == N::Func && !st->s.empty()) topDeclared_.insert(st->s);
        }
    }
    void useGlobal(const std::string& name) {
        if (used_.insert(name).second) usedOrder_.push_back(name);
        if (fs_->isMain && !conditionalNeeds_) eager_.insert(name);
    }
    void unsupported(const std::string& why) { if (info_ && info_->unsupported.empty()) info_->unsupported = why; }

    [[noreturn]] void err(const std::string& m, int line = -1) {
        throw Error(origin_ + ":" + std::to_string(line < 0 ? line_ : line) + ": " + m);
    }

    Proto* newProto(const std::string& name) {
        vm_.protoPool.emplace_back(new Proto());
        Proto* p = vm_.protoPool.back().get();
        p->name = name;
        p->origin = origin_;
        return p;
    }

    int emit(Op op, int a = 0, int b = 0) {
        Ins i;
        i.op = (uint8_t)op;
        i.x = 0;
        i.b = (uint16_t)b;
        i.a = a;
        fs_->p->code.push_back(i);
        fs_->p->lines.push_back(line_);
        return (int)fs_->p->code.size() - 1;
    }
    int here() const { return (int)fs_->p->code.size(); }
    void patchTo(int at, int target) { fs_->p->code[(size_t)at].a = target; }
    void patchHere(int at) { patchTo(at, here()); }
    void at(Node* n) { line_ = n->line; }

    int strConst(const std::string& s) {
        auto it = fs_->strConsts.find(s);
        if (it != fs_->strConsts.end()) return it->second;
        fs_->p->consts.push_back(Value::Object(vm_.intern(s)));
        int idx = (int)fs_->p->consts.size() - 1;
        fs_->strConsts[s] = idx;
        return idx;
    }
    int floatConst(double d) {
        int64_t bits;
        memcpy(&bits, &d, 8);
        auto it = fs_->numConsts.find(bits);
        if (it != fs_->numConsts.end()) return it->second;
        fs_->p->consts.push_back(Value::Float(d));
        int idx = (int)fs_->p->consts.size() - 1;
        fs_->numConsts[bits] = idx;
        return idx;
    }
    int sym(const std::string& s) { return vm_.intern(s)->sym; }

    void pushScope() {
        fs_->scopes.emplace_back();
        fs_->scopeStart.push_back(fs_->nextSlot);
    }
    void popScope() {
        fs_->nextSlot = fs_->scopeStart.back();
        fs_->scopeStart.pop_back();
        fs_->scopes.pop_back();
    }
    int allocSlot() {
        int s = fs_->nextSlot++;
        if (fs_->nextSlot > fs_->maxSlot) fs_->maxSlot = fs_->nextSlot;
        return s;
    }
    VarInfo* declare(const std::string& name, bool isFinal) {
        fs_->vars.emplace_back(new VarInfo());
        VarInfo* v = fs_->vars.back().get();
        v->name = name;
        v->slot = allocSlot();
        v->isFinal = isFinal;
        if (fs_->scopes.empty()) pushScope();
        fs_->scopes.back().push_back(v);
        return v;
    }
    bool globalDecl() const { return fs_->isMain && fs_->scopes.empty(); }

    static VarInfo* lookupLocal(FuncState* fs, const std::string& name) {
        for (size_t i = fs->scopes.size(); i-- > 0;) {
            auto& sc = fs->scopes[i];
            for (size_t j = sc.size(); j-- > 0;)
                if (sc[j]->name == name) return sc[j];
        }
        return nullptr;
    }

    int findUpvalue(FuncState* fs, const std::string& name) {
        if (!fs->parent) return -1;
        for (size_t i = 0; i < fs->upNames.size(); i++)
            if (fs->upNames[i] == name) return (int)i;
        VarInfo* v = lookupLocal(fs->parent, name);
        if (v) {
            v->captured = true;
            fs->p->ups.push_back({true, v->slot});
            fs->upNames.push_back(name);
            fs->upVars.push_back(v);
            return (int)fs->p->ups.size() - 1;
        }
        int pi = findUpvalue(fs->parent, name);
        if (pi >= 0) {
            fs->p->ups.push_back({false, pi});
            fs->upNames.push_back(name);
            fs->upVars.push_back(fs->parent->upVars[(size_t)pi]);
            return (int)fs->p->ups.size() - 1;
        }
        return -1;
    }

    Res resolve(const std::string& name) {
        Res r;
        if (VarInfo* v = lookupLocal(fs_, name)) { r.k = Res::Local; r.v = v; r.idx = v->slot; return r; }
        int u = findUpvalue(fs_, name);
        if (u >= 0) { r.k = Res::Up; r.idx = u; r.v = fs_->upVars[(size_t)u]; return r; }
        if (vm_.selfSlot >= 0 && vm_.selfFields.count(name) && !topDeclared_.count(name)) {
            r.k = Res::Self;
            r.idx = vm_.selfSlot;
            r.sym = sym(name);
            return r;
        }
        r.k = Res::Global;
        useGlobal(name);
        r.idx = vm_.globalSlot(name);
        return r;
    }

    void emitLoad(const Res& r) {
        switch (r.k) {
            case Res::Local: { int pc = emit(OP_LOCAL, r.idx); r.v->uses.push_back({pc, U_GET}); break; }
            case Res::Up: emit(OP_UPGET, r.idx); break;
            case Res::Global: emit(OP_GGET, r.idx); break;
            case Res::Self: emit(OP_GGET, r.idx); emit(OP_GETF, r.sym); break;
        }
    }
    void emitStore(const Res& r, bool keep, const std::string& name) {
        if (r.k != Res::Global && r.v && r.v->isFinal) err("Cannot assign to final variable '" + name + "'");
        if (r.k == Res::Global && vm_.finalGlobals.count(name)) err("Cannot assign to final variable '" + name + "'");
        switch (r.k) {
            case Res::Local: {
                int pc = emit(keep ? OP_SETLOCAL : OP_SETLOCALP, r.idx);
                r.v->uses.push_back({pc, keep ? U_SET : U_SETP});
                break;
            }
            case Res::Up: emit(keep ? OP_UPSET : OP_UPSETP, r.idx); break;
            case Res::Global: emit(keep ? OP_GSET : OP_GSETP, r.idx); break;
            case Res::Self:
                emit(OP_GGET, r.idx);
                emit(OP_SWAP);
                emit(OP_SETF, r.sym);
                if (!keep) emit(OP_POP);
                break;
        }
    }
    void emitDecl(VarInfo* v) {
        int pc = emit(OP_SETLOCALP, v->slot);
        v->uses.push_back({pc, U_DECL});
    }

    void finishFunction(FuncState& fs) {
        Proto* p = fs.p;
        uint32_t mask = 0;
        for (auto& up : fs.vars) {
            VarInfo* v = up.get();
            if (!v->captured) continue;
            if (v->isParam) {
                if (v->slot >= 32) err("Too many parameters captured by a closure");
                mask |= 1u << v->slot;
            }
            for (auto& u : v->uses) {
                Ins& in = p->code[(size_t)u.pc];
                switch (u.kind) {
                    case U_GET: in.op = OP_BOXGET; break;
                    case U_SET: in.op = OP_BOXSET; break;
                    case U_SETP: in.op = OP_BOXSETP; break;
                    case U_DECL: in.op = OP_BOXNEW; break;
                    case U_INC: in.op = OP_BOXINC; break;
                }
            }
        }
        for (size_t i = 0; i + 1 < p->code.size(); i++)
            if (p->code[i].op == OP_RANGENEXT && p->code[i + 1].op == OP_SETLOCALP && p->code[i + 1].a < 60000)
                p->code[i].b = (uint16_t)(p->code[i + 1].a + 1);
        if (mask) {
            p->code[0].op = OP_BOXPARAMS;
            p->code[0].a = (int32_t)mask;
            p->entry = 0;
        } else {
            p->entry = 1;
        }
        p->nlocals = fs.maxSlot;
    }

    void block(Node* n, bool want) {
        bool root = n->flag && fs_->isMain && fs_->scopes.empty() && fs_->parent == nullptr;
        if (!root) pushScope();
        size_t cnt = n->list.size();
        for (size_t i = 0; i < cnt; i++) {
            bool last = (i + 1 == cnt);
            expr(n->list[i], want && last);
        }
        if (cnt == 0 && want) emit(OP_NULL_);
        if (!root) popScope();
    }

    Op binOp(const std::string& s, int line) {
        if (s == "+") return OP_ADD;
        if (s == "-") return OP_SUB;
        if (s == "*") return OP_MUL;
        if (s == "/") return OP_DIV;
        if (s == "%") return OP_MOD;
        if (s == "&") return OP_BAND;
        if (s == "|") return OP_BOR;
        if (s == "^") return OP_BXOR;
        if (s == "<<") return OP_SHL;
        if (s == ">>") return OP_SHR;
        if (s == ">>>") return OP_USHR;
        if (s == "==") return OP_EQ;
        if (s == "!=") return OP_NE;
        if (s == "<") return OP_LT;
        if (s == "<=") return OP_LE;
        if (s == ">") return OP_GT;
        if (s == ">=") return OP_GE;
        err("Invalid operator " + s, line);
    }

    static bool isCmp(const std::string& o) { return o == "<" || o == "<=" || o == ">" || o == ">=" || o == "==" || o == "!="; }

    void condJump(Node* c, std::vector<int>& falseJumps) {
        at(c);
        if (c->k == N::Binop && isCmp(c->s)) {
            static const char* names[] = {"<", "<=", ">", ">=", "==", "!="};
            int k = 0;
            while (c->s != names[k]) k++;
            bool imm = c->b->k == N::Int && c->b->iv >= -32768 && c->b->iv <= 32767;
            expr(c->a, true);
            if (!imm) expr(c->b, true);
            at(c);
            Op op = (Op)((imm ? OP_JFLTI : OP_JFLT) + 0);
            static const Op reg[] = {OP_JFLT, OP_JFLE, OP_JFGT, OP_JFGE, OP_JFEQ, OP_JFNE};
            static const Op immo[] = {OP_JFLTI, OP_JFLEI, OP_JFGTI, OP_JFGEI, OP_JFEQI, OP_JFNEI};
            op = imm ? immo[k] : reg[k];
            falseJumps.push_back(emit(op, 0, imm ? (int)(uint16_t)(int16_t)c->b->iv : 0));
            return;
        }
        if (c->k == N::Binop && c->s == "&&") {
            condJump(c->a, falseJumps);
            condJump(c->b, falseJumps);
            return;
        }
        expr(c, true);
        at(c);
        falseJumps.push_back(emit(OP_JMPF));
    }

    void expr(Node* n, bool want) {
        at(n);
        switch (n->k) {
            case N::Int: if (want) emit(OP_INT, (int32_t)n->iv); return;
            case N::Float: if (want) emit(OP_CONST, floatConst(n->fv)); return;
            case N::Str: if (want) emit(OP_CONST, strConst(n->s)); return;
            case N::Interp: {
                for (Node* part : n->list) {
                    if (part->k == N::Str) { at(part); emit(OP_CONST, strConst(part->s)); }
                    else expr(part, true);
                }
                at(n);
                emit(OP_CONCAT, (int)n->list.size());
                if (!want) emit(OP_POP);
                return;
            }
            case N::Regex: {
                useGlobal("__ss_regex");
                emit(OP_CONST, strConst(n->s));
                emit(OP_CONST, strConst(n->s2));
                emit(OP_NEW, strConst("__ss_regex"), 2);
                if (!want) emit(OP_POP);
                return;
            }
            case N::Ident: {
                if (n->s == "null") { if (want) emit(OP_NULL_); return; }
                if (n->s == "true") { if (want) emit(OP_TRUE_); return; }
                if (n->s == "false") { if (want) emit(OP_FALSE_); return; }
                emitLoad(resolve(n->s));
                if (!want) emit(OP_POP);
                return;
            }
            case N::Var: varDecl(n, want); return;
            case N::Vars:
                for (Node* v : n->list) varDecl(v, false);
                if (want) emit(OP_NULL_);
                return;
            case N::Block: block(n, want); return;
            case N::Field: {
                expr(n->a, true);
                at(n);
                emit(OP_GETF, sym(n->s));
                if (!want) emit(OP_POP);
                return;
            }
            case N::SafeNav: {
                expr(n->a, true);
                at(n);
                int j = emit(OP_JMPNULL);
                emit(OP_GETF, sym(n->s));
                patchHere(j);
                if (!want) emit(OP_POP);
                return;
            }
            case N::Index: {
                expr(n->a, true);
                expr(n->b, true);
                at(n);
                emit(OP_GETI);
                if (!want) emit(OP_POP);
                return;
            }
            case N::Unop: unop(n, want); return;
            case N::Binop: binop(n, want); return;
            case N::Assign: assign(n, want); return;
            case N::Coalesce: coalesce(n, want); return;
            case N::Ternary: {
                std::vector<int> jfs;
                condJump(n->a, jfs);
                expr(n->b, want);
                int je = emit(OP_JMP);
                for (int j : jfs) patchHere(j);
                expr(n->c, want);
                patchHere(je);
                return;
            }
            case N::If: {
                std::vector<int> jfs;
                condJump(n->a, jfs);
                at(n);
                expr(n->b, want);
                if (n->c) {
                    int je = emit(OP_JMP);
                    for (int j : jfs) patchHere(j);
                    expr(n->c, want);
                    patchHere(je);
                } else if (want) {
                    int je = emit(OP_JMP);
                    for (int j : jfs) patchHere(j);
                    emit(OP_NULL_);
                    patchHere(je);
                } else {
                    for (int j : jfs) patchHere(j);
                }
                return;
            }
            case N::While: {
                fs_->loops.emplace_back();
                fs_->loops.back().tryDepth = fs_->tryDepth;
                int start = here();
                fs_->loops.back().continueTarget = start;
                std::vector<int> jfs;
                condJump(n->a, jfs);
                expr(n->b, false);
                at(n);
                emit(OP_LOOP, start);
                for (int j : jfs) patchHere(j);
                endLoop(here());
                if (want) emit(OP_NULL_);
                return;
            }
            case N::DoWhile: {
                fs_->loops.emplace_back();
                fs_->loops.back().tryDepth = fs_->tryDepth;
                int start = here();
                expr(n->b, false);
                int condPos = here();
                for (int c : fs_->loops.back().continues) patchTo(c, condPos);
                fs_->loops.back().continues.clear();
                fs_->loops.back().continueTarget = condPos;
                std::vector<int> jxs;
                condJump(n->a, jxs);
                at(n);
                emit(OP_LOOP, start);
                for (int j : jxs) patchHere(j);
                endLoop(here());
                if (want) emit(OP_NULL_);
                return;
            }
            case N::For: forLoop(n, want); return;
            case N::Break: {
                if (fs_->loops.empty()) err("break outside of a loop");
                LoopCtx& lc = fs_->loops.back();
                for (int i = fs_->tryDepth; i > lc.tryDepth; i--) emit(OP_ENDTRY);
                lc.breaks.push_back(emit(OP_JMP));
                return;
            }
            case N::Continue: {
                if (fs_->loops.empty()) err("continue outside of a loop");
                LoopCtx& lc = fs_->loops.back();
                for (int i = fs_->tryDepth; i > lc.tryDepth; i--) emit(OP_ENDTRY);
                if (lc.continueTarget >= 0) emit(OP_LOOP, lc.continueTarget);
                else lc.continues.push_back(emit(OP_JMP));
                return;
            }
            case N::Return: {
                if (n->a) expr(n->a, true); else emit(OP_NULL_);
                at(n);
                emit(OP_RET);
                return;
            }
            case N::Throw: {
                expr(n->a, true);
                at(n);
                emit(OP_THROW);
                return;
            }
            case N::Try: tryStmt(n, want); return;
            case N::Switch: switchStmt(n, want); return;
            case N::Func: funcExpr(n, want); return;
            case N::Array: {
                size_t cnt = n->list.size();
                if (cnt <= 256) {
                    for (Node* e : n->list) expr(e, true);
                    at(n);
                    emit(OP_ARR, (int)cnt);
                } else {
                    emit(OP_ARR, 0);
                    for (size_t i = 0; i < cnt; i += 256) {
                        size_t k = std::min<size_t>(256, cnt - i);
                        for (size_t j = 0; j < k; j++) expr(n->list[i + j], true);
                        emit(OP_ARRAPP, (int)k);
                    }
                }
                if (!want) emit(OP_POP);
                return;
            }
            case N::MapLit: {
                size_t pairs = n->list.size() / 2;
                if (pairs > 1000) err("Map literal is too large (max 1000 entries)");
                for (Node* e : n->list) expr(e, true);
                at(n);
                emit(OP_MAP, (int)pairs);
                if (!want) emit(OP_POP);
                return;
            }
            case N::Object: {
                if (n->list.size() > 1000) err("Object literal is too large");
                std::vector<StrObj*> keys;
                for (auto& k : n->names) keys.push_back(vm_.intern(k));
                fs_->p->keyLists.push_back(keys);
                int klIdx = (int)fs_->p->keyLists.size() - 1;
                for (Node* e : n->list) expr(e, true);
                at(n);
                emit(OP_OBJ, klIdx, (int)n->list.size());
                if (!want) emit(OP_POP);
                return;
            }
            case N::New: {
                const auto& name = n->s;
                if (name == "EReg" || !vm_.classes.count(name)) useGlobal(name);
                for (Node* e : n->list) expr(e, true);
                at(n);
                emit(OP_NEW, strConst(name), (int)n->list.size());
                if (!want) emit(OP_POP);
                return;
            }
            case N::Call: call(n, want); return;
            case N::Is: {
                expr(n->a, true);
                at(n);
                emit(OP_ISTYPE, strConst(n->s), 0);
                if (!want) emit(OP_POP);
                return;
            }
            case N::Import: {
                if (info_ && !n->names.empty()) {
                    const auto& local = n->s2.empty() ? n->s : n->s2;
                    info_->imports.push_back({n->iv ? "" : local, n->names[0]});
                }
                if (want) emit(OP_NULL_);
                return;
            }
            case N::Nop:
                if (n->flag && n->s != "StringTools") unsupported("using " + n->s);
                if (want) emit(OP_NULL_);
                return;
            case N::Cast: {
                int code = n->s == "String" ? 1 : n->s == "Bool" ? 2 : n->s == "Int" ? 3 : n->s == "Float" ? 4 : n->s == "Array" ? 5 : 0;
                if(code==0 && scriptTypes_.count(n->s))code=6;
                expr(n->a, want || code != 0);
                if (code == 0) return;
                at(n);
                emit(OP_CAST, code==6?strConst(n->s):0, code);
                if (!want) emit(OP_POP);
                return;
            }
        }
    }

    void endLoop(int endPos) {
        LoopCtx& lc = fs_->loops.back();
        for (int b : lc.breaks) patchTo(b, endPos);
        for (int c : lc.continues) patchTo(c, lc.continueTarget >= 0 ? lc.continueTarget : endPos);
        fs_->loops.pop_back();
    }

    void varDecl(Node* n, bool want) {
        if (globalDecl()) {
            if (n->a) expr(n->a, true); else emit(OP_NULL_);
            at(n);
            if (n->flag) vm_.finalGlobals.insert(n->s); else vm_.finalGlobals.erase(n->s);
            declared_.insert(n->s);
            emit(OP_GDEF, vm_.globalSlot(n->s));
        } else {
            if (n->a) expr(n->a, true); else emit(OP_NULL_);
            at(n);
            VarInfo* v = declare(n->s, n->flag);
            emitDecl(v);
        }
        if (want) emit(OP_NULL_);
    }

    void unop(Node* n, bool want) {
        const std::string& op = n->s;
        if (op == "++" || op == "--") { incdec(n, want); return; }
        expr(n->a, true);
        at(n);
        if (op == "-") emit(OP_NEG);
        else if (op == "!") emit(OP_NOT);
        else if (op == "~") emit(OP_BNOT);
        else err("Invalid operator " + op);
        if (!want) emit(OP_POP);
    }

    void incdec(Node* n, bool want) {
        int d = n->s == "++" ? 1 : -1;
        bool prefix = n->flag;
        Node* t = n->a;
        if (t->k == N::Ident) {
            Res r = resolve(t->s);
            if (!want && r.k == Res::Local) {
                if (r.v->isFinal) err("Cannot assign to final variable '" + t->s + "'");
                at(n);
                int pc = emit(OP_INCL, r.idx, (uint16_t)(int16_t)d);
                r.v->uses.push_back({pc, U_INC});
                return;
            }
            emitLoad(r);
            if (want && !prefix) emit(OP_DUP);
            emit(OP_INT, d);
            emit(OP_ADD);
            if (want && !prefix) emitStore(r, false, t->s);
            else emitStore(r, want, t->s);
            return;
        }
        if (t->k == N::Field) {
            expr(t->a, true);
            at(n);
            emit(OP_DUP);
            emit(OP_GETF, sym(t->s));
            if (want && !prefix) {
                int tmp = allocSlot();
                emit(OP_DUP);
                emit(OP_SETLOCALP, tmp);
                emit(OP_INT, d);
                emit(OP_ADD);
                emit(OP_SETF, sym(t->s));
                emit(OP_POP);
                emit(OP_LOCAL, tmp);
                fs_->nextSlot--;
            } else {
                emit(OP_INT, d);
                emit(OP_ADD);
                emit(OP_SETF, sym(t->s));
                if (!want) emit(OP_POP);
            }
            return;
        }
        if (t->k == N::Index) {
            expr(t->a, true);
            expr(t->b, true);
            at(n);
            emit(OP_DUP2);
            emit(OP_GETI);
            if (want && !prefix) {
                int tmp = allocSlot();
                emit(OP_DUP);
                emit(OP_SETLOCALP, tmp);
                emit(OP_INT, d);
                emit(OP_ADD);
                emit(OP_SETI);
                emit(OP_POP);
                emit(OP_LOCAL, tmp);
                fs_->nextSlot--;
            } else {
                emit(OP_INT, d);
                emit(OP_ADD);
                emit(OP_SETI);
                if (!want) emit(OP_POP);
            }
            return;
        }
        err("Invalid increment target");
    }

    void binop(Node* n, bool want) {
        const std::string& op = n->s;
        if (op == "&&") {
            expr(n->a, true);
            int jf = emit(OP_JMPF);
            expr(n->b, true);
            emit(OP_TOBOOL);
            int je = emit(OP_JMP);
            patchHere(jf);
            emit(OP_FALSE_);
            patchHere(je);
            if (!want) emit(OP_POP);
            return;
        }
        if (op == "||") {
            expr(n->a, true);
            int jt = emit(OP_JMPT);
            expr(n->b, true);
            emit(OP_TOBOOL);
            int je = emit(OP_JMP);
            patchHere(jt);
            emit(OP_TRUE_);
            patchHere(je);
            if (!want) emit(OP_POP);
            return;
        }
        if (op == "...") {
            expr(n->a, true);
            expr(n->b, true);
            at(n);
            emit(OP_RANGE);
            if (!want) emit(OP_POP);
            return;
        }
        if (op == "=>") err("Unexpected '=>' outside of a map literal or for loop");
        if ((op == "+" || op == "-") && n->b->k == N::Int && n->b->iv >= -32767 && n->b->iv <= 32767) {
            expr(n->a, true);
            at(n);
            emit(OP_ADDI, 0, (int)(uint16_t)(int16_t)(op == "+" ? n->b->iv : -n->b->iv));
            if (!want) emit(OP_POP);
            return;
        }
        expr(n->a, true);
        expr(n->b, true);
        at(n);
        emit(binOp(op, n->line));
        if (!want) emit(OP_POP);
    }

    void assign(Node* n, bool want) {
        const std::string& op = n->s;
        Node* t = n->a;
        bool plain = (op == "=");
        Op bop = OP_NOP;
        if (!plain) bop = binOp(op.substr(0, op.size() - 1), n->line);

        if (t->k == N::Ident) {
            Res r = resolve(t->s);
            if (plain) {
                expr(n->b, true);
            } else {
                if (!want && r.k == Res::Local && !r.v->isFinal && n->b->k == N::Int && n->b->iv >= -32768 && n->b->iv <= 32767 &&
                    (op == "+=" || op == "-=")) {
                    int d = (int)n->b->iv * (op == "-=" ? -1 : 1);
                    at(n);
                    int pc = emit(OP_INCL, r.idx, (uint16_t)(int16_t)d);
                    r.v->uses.push_back({pc, U_INC});
                    return;
                }
                emitLoad(r);
                expr(n->b, true);
                at(n);
                emit(bop);
            }
            at(n);
            emitStore(r, want, t->s);
            return;
        }
        if (t->k == N::Field) {
            expr(t->a, true);
            if (!plain) {
                at(n);
                emit(OP_DUP);
                emit(OP_GETF, sym(t->s));
            }
            expr(n->b, true);
            at(n);
            if (!plain) emit(bop);
            emit(OP_SETF, sym(t->s));
            if (!want) emit(OP_POP);
            return;
        }
        if (t->k == N::Index) {
            expr(t->a, true);
            expr(t->b, true);
            if (!plain) {
                at(n);
                emit(OP_DUP2);
                emit(OP_GETI);
            }
            expr(n->b, true);
            at(n);
            if (!plain) emit(bop);
            emit(OP_SETI);
            if (!want) emit(OP_POP);
            return;
        }
        err("Invalid assignment target");
    }

    void coalesce(Node* n, bool want) {
        if (!n->flag) {
            expr(n->a, true);
            at(n);
            int j = emit(OP_JMPNN);
            expr(n->b, true);
            patchHere(j);
            if (!want) emit(OP_POP);
            return;
        }
        Node* t = n->a;
        if (t->k == N::Ident) {
            Res r = resolve(t->s);
            emitLoad(r);
            int j = emit(OP_JMPNN);
            expr(n->b, true);
            emitStore(r, true, t->s);
            patchHere(j);
            if (!want) emit(OP_POP);
            return;
        }
        if (t->k == N::Field) {
            expr(t->a, true);
            emit(OP_DUP);
            emit(OP_GETF, sym(t->s));
            int j = emit(OP_JMPNN);
            expr(n->b, true);
            emit(OP_SETF, sym(t->s));
            int je = emit(OP_JMP);
            patchHere(j);
            emit(OP_SWAP);
            emit(OP_POP);
            patchHere(je);
            if (!want) emit(OP_POP);
            return;
        }
        if (t->k == N::Index) {
            expr(t->a, true);
            expr(t->b, true);
            emit(OP_DUP2);
            emit(OP_GETI);
            int j = emit(OP_JMPNN);
            expr(n->b, true);
            emit(OP_SETI);
            int je = emit(OP_JMP);
            patchHere(j);
            emit(OP_SWAP);
            emit(OP_POP);
            emit(OP_SWAP);
            emit(OP_POP);
            patchHere(je);
            if (!want) emit(OP_POP);
            return;
        }
        err("Invalid assignment target");
    }

    void call(Node* n, bool want) {
        Node* c = n->a;
        size_t argc = n->list.size();
        if (argc > 200) err("Too many call arguments");
        if (c->k == N::Field) {
            expr(c->a, true);
            for (Node* a : n->list) expr(a, true);
            at(n);
            emit(OP_CALLM, sym(c->s), (int)argc);
        } else if (c->k == N::SafeNav) {
            expr(c->a, true);
            at(n);
            int j = emit(OP_JMPNULL);
            for (Node* a : n->list) expr(a, true);
            at(n);
            emit(OP_CALLM, sym(c->s), (int)argc);
            patchHere(j);
        } else if (c->k == N::Ident && c->s != "null" && c->s != "true" && c->s != "false") {
            Res r = resolve(c->s);
            if (r.k == Res::Self) {
                emit(OP_GGET, r.idx);
                for (Node* a : n->list) expr(a, true);
                at(n);
                emit(OP_CALLM, r.sym, (int)argc);
            } else {
                emitLoad(r);
                for (Node* a : n->list) expr(a, true);
                at(n);
                emit(OP_CALL, 0, (int)argc);
            }
        } else {
            expr(c, true);
            for (Node* a : n->list) expr(a, true);
            at(n);
            emit(OP_CALL, 0, (int)argc);
        }
        if (!want) emit(OP_POP);
    }

    void forLoop(Node* n, bool want) {
        pushScope();
        Node* it = n->a;
        bool range = (it->k == N::Binop && it->s == "..." );
        fs_->loops.emplace_back();
        fs_->loops.back().tryDepth = fs_->tryDepth;
        int start;
        int jnext;
        if (range) {
            expr(it->a, true);
            expr(it->b, true);
            at(n);
            start = here();
            jnext = emit(OP_RANGENEXT);
        } else {
            expr(it, true);
            at(n);
            emit(OP_ITER, 0, n->s2.empty() ? 0 : 1);
            start = here();
            jnext = emit(n->s2.empty() ? OP_ITERNEXT : OP_ITERNEXT2);
        }
        fs_->loops.back().continueTarget = start;
        if (n->s2.empty()) {
            VarInfo* v = declare(n->s, false);
            emitDecl(v);
        } else {
            VarInfo* vv = declare(n->s2, false);
            emitDecl(vv);
            VarInfo* kv = declare(n->s, false);
            emitDecl(kv);
        }
        expr(n->b, false);
        at(n);
        emit(OP_LOOP, start);
        patchHere(jnext);
        endLoop(here());
        emit(OP_POP);
        if (range) emit(OP_POP);
        popScope();
        if (want) emit(OP_NULL_);
    }

    void tryStmt(Node* n, bool want) {
        int th = emit(OP_TRY);
        fs_->tryDepth++;
        expr(n->a, want);
        fs_->tryDepth--;
        emit(OP_ENDTRY);
        std::vector<int> ends;
        ends.push_back(emit(OP_JMP));
        patchHere(th);
        for (CatchC& c : n->catches) {
            pushScope();
            int jnext = -1;
            bool wildcard = c.type.empty() || c.type == "Dynamic" || c.type == "Any" || c.type == "Exception" ||
                            c.type == "haxe.Exception" || c.type == "Error" || c.type == "Function";
            if (!wildcard) {
                emit(OP_ISTYPE, strConst(c.type), 1);
                jnext = emit(OP_JMPF);
            }
            VarInfo* v = declare(c.var, false);
            emitDecl(v);
            expr(c.body, want);
            popScope();
            ends.push_back(emit(OP_JMP));
            if (jnext >= 0) patchHere(jnext);
        }
        emit(OP_THROW);
        for (int e : ends) patchHere(e);
    }


    void patternNames(Node* p, std::unordered_set<std::string>& out, bool nested=false) {
        if(p->k==N::Ident && nested && p->s!="_" && p->s!="null" && p->s!="true" && p->s!="false") out.insert(p->s);
        if(p->k==N::Call) for(auto* a:p->list) patternNames(a,out,true);
    }
    std::string patternOwner(Node* owner) {
        if(owner->k==N::Ident) return owner->s;
        if(owner->k==N::Field) return patternOwner(owner->a)+"."+owner->s;
        err("Invalid enum pattern qualifier",owner->line);
    }
    void emitPattern(Node* p,int value,std::vector<int>& failures,bool nested=false,
                     const std::function<void()>& expressionBody={}) {
        if(p->k==N::Ident && p->s=="_") return;
        if(p->k==N::Ident && nested && p->s!="null" && p->s!="true" && p->s!="false") {
            emit(OP_LOCAL,value);emitStore(resolve(p->s),false,p->s);return;
        }
        if(p->k==N::Call && (p->a->k==N::Ident || p->a->k==N::Field)) {
            std::string tag=p->a->s, type;
            if(p->a->k==N::Field) type=patternOwner(p->a->a);
            int params=allocSlot();
            emit(OP_LOCAL,value);emit(OP_ENUMCHECK,strConst(type+"|"+tag),(int)p->list.size());
            emit(OP_SETLOCALP,params);
            if(expressionBody) {
                emit(OP_LOCAL,params);emit(OP_FALSE_);emit(OP_EQ);
                int enumPattern=emit(OP_JMPF);
                emit(OP_LOCAL,value);
                auto bindings=std::move(fs_->scopes.back());
                fs_->scopes.back().clear();
                bool savedConditional=conditionalNeeds_;
                conditionalNeeds_=true;
                expr(p,true);
                emit(OP_EQ);failures.push_back(emit(OP_JMPF));
                int nextSlot=fs_->nextSlot;
                expressionBody();
                conditionalNeeds_=savedConditional;
                fs_->nextSlot=nextSlot;
                fs_->scopes.back()=std::move(bindings);
                patchHere(enumPattern);
            }
            emit(OP_LOCAL,params);
            failures.push_back(emit(OP_JMPF));
            for(size_t i=0;i<p->list.size();i++) {
                int child=allocSlot();
                emit(OP_LOCAL,params);emit(OP_INT,(int)i);emit(OP_GETI);emit(OP_SETLOCALP,child);
                emitPattern(p->list[i],child,failures,true);fs_->nextSlot--;
            }
            fs_->nextSlot--;
            return;
        }
        emit(OP_LOCAL,value);expr(p,true);at(p);emit(OP_EQ);failures.push_back(emit(OP_JMPF));
    }
    void switchStmt(Node* n, bool want) {
        int tmp = allocSlot();expr(n->a,true);at(n);emit(OP_SETLOCALP,tmp);
        std::vector<int> ends;
        for(CaseC& c:n->cases) {
            pushScope();
            std::unordered_set<std::string> bindings;
            if(!c.values.empty()) patternNames(c.values[0],bindings);
            for(Node* p:c.values) {
                std::unordered_set<std::string> names;patternNames(p,names);
                if(names!=bindings) err("Switch alternatives must bind the same names",p->line);
            }
            for(const auto& name:bindings) {emit(OP_NULL_);emitDecl(declare(name,false));}
            std::vector<int> toBody;
            for(Node* p:c.values) {
                std::vector<int> failures;
                emitPattern(p,tmp,failures,false,[&] {
                    if(c.guard) {expr(c.guard,true);failures.push_back(emit(OP_JMPF));}
                    expr(c.body,want);ends.push_back(emit(OP_JMP));
                });
                if(c.guard) {expr(c.guard,true);failures.push_back(emit(OP_JMPF));}
                toBody.push_back(emit(OP_JMP));
                for(int j:failures) patchHere(j);
            }
            int jnext=c.values.empty()?-1:emit(OP_JMP);
            for(int j:toBody) patchHere(j);
            if(c.values.empty() && c.guard) {expr(c.guard,true);jnext=emit(OP_JMPF);}
            expr(c.body,want);ends.push_back(emit(OP_JMP));
            if(jnext>=0)patchHere(jnext);
            popScope();
        }
        if(n->b)expr(n->b,want);else if(want)emit(OP_NULL_);
        for(int j:ends)patchHere(j);
        fs_->nextSlot--;
    }

    void funcExpr(Node* n, bool want) {
        bool global = !n->s.empty() && globalDecl();
        VarInfo* nameVar = nullptr;
        if (!n->s.empty() && !global) {
            emit(OP_NULL_);
            nameVar = declare(n->s, false);
            emitDecl(nameVar);
        }
        Proto* child = compileFunction(n);
        fs_->p->protos.push_back(child);
        at(n);
        emit(OP_CLOSURE, (int)fs_->p->protos.size() - 1);
        if (n->s.empty()) {
            if (!want) emit(OP_POP);
            return;
        }
        if (global) {
            if (want) emit(OP_DUP);
            vm_.finalGlobals.erase(n->s);
            declared_.insert(n->s);
            emit(OP_GDEF, vm_.globalSlot(n->s));
        } else {
            Res r = resolve(n->s);
            emitStore(r, want, n->s);
        }
        (void)nameVar;
    }

    Proto* compileFunction(Node* f) {
        FuncState nfs;
        nfs.parent = fs_;
        nfs.p = newProto(f->s.empty() ? "<anonymous>" : f->s);
        int savedLine = line_;
        fs_ = &nfs;
        pushScope();
        nfs.p->nparams = (int)f->params.size();
        int minArgs = 0;
        for (size_t i = 0; i < f->params.size(); i++) {
            VarInfo* v = declare(f->params[i].name, false);
            v->isParam = true;
            nfs.p->paramNames.push_back(f->params[i].name);
            if (!f->params[i].opt && !f->params[i].def) minArgs = (int)i + 1;
        }
        nfs.p->minArgs = minArgs;
        emit(OP_NOP);
        for (size_t i = 0; i < f->params.size(); i++) {
            if (!f->params[i].def) continue;
            VarInfo* v = nfs.scopes.back()[i];
            at(f->params[i].def);
            Res r; r.k = Res::Local; r.v = v; r.idx = v->slot;
            emitLoad(r);
            emit(OP_NULL_);
            emit(OP_NE);
            int jskip = emit(OP_JMPT);
            expr(f->params[i].def, true);
            int pc = emit(OP_SETLOCALP, v->slot);
            v->uses.push_back({pc, U_SETP});
            patchHere(jskip);
        }
        expr(f->a, true);
        emit(OP_RET);
        popScope();
        finishFunction(nfs);
        fs_ = nfs.parent;
        line_ = savedLine;
        return nfs.p;
    }
};

}  // namespace

Proto* compileProgram(VM::Impl& vm, Ast& ast, const std::string& origin, Program* info) {
    Compiler c(vm, origin);
    return c.compileMain(ast.root, info);
}

}  // namespace ssvm
