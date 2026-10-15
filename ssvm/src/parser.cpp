#include <cmath>
#include <cstdlib>

#include "internal.hpp"

namespace ssvm {

namespace {

enum TK {
    T_EOF, T_ID, T_INT, T_FLOAT, T_STR, T_ISTR, T_OP, T_LP, T_RP, T_LB, T_RB, T_LK, T_RK,
    T_COMMA, T_SEMI, T_DOT, T_COLON, T_QUEST, T_QQ, T_QQA, T_QDOT, T_META, T_REGEX
};

struct StrPart { bool isExpr; std::string text; int line; };

struct Token {
    TK k = T_EOF;
    std::string s, s2;
    int64_t iv = 0;
    double fv = 0;
    int line = 1;
    std::vector<StrPart> parts;
};

[[noreturn]] void fail(const std::string& origin, int line, const std::string& msg) {
    throw Error(origin + ":" + std::to_string(line) + ": " + msg);
}

inline bool isIdStart(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
inline bool isDigit(char c) { return c >= '0' && c <= '9'; }
inline bool isIdChar(char c) { return isIdStart(c) || isDigit(c); }

void appendUtf8(std::string& out, uint32_t cp) {
    if (cp < 0x80) out += (char)cp;
    else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}

int hexVal(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

struct CondEval {
    const std::string& s;
    size_t p = 0;
    explicit CondEval(const std::string& str) : s(str) {}
    void ws() { while (p < s.size() && (s[p] == ' ' || s[p] == '\t')) p++; }
    static bool defined(const std::string& n) {
        static const char* defs[] = {"cpp", "sys", "hscript", "sscript", "static", "desktop", "ssvm", nullptr};
        for (int i = 0; defs[i]; i++) if (n == defs[i]) return true;
        return false;
    }
    bool parseOr() {
        bool v = parseAnd();
        for (;;) { ws(); if (s.compare(p, 2, "||") == 0) { p += 2; bool r = parseAnd(); v = v || r; } else break; }
        return v;
    }
    bool parseAnd() {
        bool v = parseNot();
        for (;;) { ws(); if (s.compare(p, 2, "&&") == 0) { p += 2; bool r = parseNot(); v = v && r; } else break; }
        return v;
    }
    bool parseNot() {
        ws();
        if (p < s.size() && s[p] == '!') { p++; return !parseNot(); }
        if (p < s.size() && s[p] == '(') { p++; bool v = parseOr(); ws(); if (p < s.size() && s[p] == ')') p++; return v; }
        size_t st = p;
        while (p < s.size() && (isIdChar(s[p]))) p++;
        return defined(s.substr(st, p - st));
    }
};

class Lexer {
public:
    Lexer(const std::string& src, const std::string& origin, int line) : s(src), origin(origin), line(line) {}

    std::vector<Token> run() {
        std::vector<Token> out;
        out.reserve(s.size() / 3 + 8);
        for (;;) {
            if (!skipSpace()) {}
            Token t;
            t.line = line;
            if (pos >= s.size()) { t.k = T_EOF; out.push_back(std::move(t)); break; }
            lexOne(t, out);
            if (t.k != T_EOF || true) {
                if (!skipThis) out.push_back(std::move(t));
                skipThis = false;
            }
        }
        return out;
    }

private:
    const std::string& s;
    std::string origin;
    size_t pos = 0;
    int line;
    bool skipThis = false;
    struct PP { bool active, taken, parent; };
    std::vector<PP> pp;
    bool lineStart = true;

    bool ppActive() const { return pp.empty() || pp.back().active; }

    char cur() const { return pos < s.size() ? s[pos] : '\0'; }
    char at(size_t o) const { return pos + o < s.size() ? s[pos + o] : '\0'; }

    bool skipSpace() {
        for (;;) {
            while (pos < s.size()) {
                char c = s[pos];
                if (c == '\n') { line++; pos++; lineStart = true; }
                else if (c == ' ' || c == '\t' || c == '\r') pos++;
                else break;
            }
            if (pos >= s.size()) return false;
            if (s[pos] == '/' && at(1) == '/') {
                while (pos < s.size() && s[pos] != '\n') pos++;
                continue;
            }
            if (s[pos] == '/' && at(1) == '*') {
                int start = line;
                pos += 2;
                for (;;) {
                    if (pos >= s.size()) fail(origin, start, "Unterminated comment");
                    if (s[pos] == '*' && at(1) == '/') { pos += 2; break; }
                    if (s[pos] == '\n') line++;
                    pos++;
                }
                continue;
            }
            if (s[pos] == '#' && lineStart && handleDirective()) continue;
            if (!ppActive()) {
                while (pos < s.size() && s[pos] != '\n') pos++;
                continue;
            }
            lineStart = false;
            return true;
        }
    }

    bool handleDirective() {
        size_t p = pos + 1;
        size_t st = p;
        while (p < s.size() && isIdChar(s[p])) p++;
        std::string d = s.substr(st, p - st);
        if (d != "if" && d != "elseif" && d != "else" && d != "end") return false;
        size_t e = p;
        while (e < s.size() && s[e] != '\n') e++;
        std::string rest = s.substr(p, e - p);
        pos = e;
        if (d == "if") {
            bool parent = ppActive();
            CondEval ce(rest);
            bool v = parent && ce.parseOr();
            pp.push_back({v, v, parent});
        } else if (d == "elseif") {
            if (pp.empty()) fail(origin, line, "Unexpected #elseif");
            PP& t = pp.back();
            CondEval ce(rest);
            bool v = t.parent && !t.taken && ce.parseOr();
            t.active = v;
            if (v) t.taken = true;
        } else if (d == "else") {
            if (pp.empty()) fail(origin, line, "Unexpected #else");
            PP& t = pp.back();
            t.active = t.parent && !t.taken;
            t.taken = true;
        } else {
            if (pp.empty()) fail(origin, line, "Unexpected #end");
            pp.pop_back();
        }
        return true;
    }

    static bool valueLike(const std::vector<Token>& out) {
        if (out.empty()) return false;
        TK k = out.back().k;
        return k == T_ID || k == T_INT || k == T_FLOAT || k == T_RP || k == T_RK || k == T_STR || k == T_ISTR;
    }

    void lexOne(Token& t, std::vector<Token>& out) {
        char c = cur();
        if (isIdStart(c)) {
            size_t st = pos;
            while (pos < s.size() && isIdChar(s[pos])) pos++;
            t.k = T_ID;
            t.s = s.substr(st, pos - st);
            return;
        }
        if (isDigit(c) || (c == '.' && isDigit(at(1)) && !valueLike(out))) { lexNumber(t); return; }
        if (c == '"' || c == '\'') { lexString(t, c); return; }
        if (c == '@') {
            pos++;
            if (cur() == ':') pos++;
            size_t st = pos;
            while (pos < s.size() && (isIdChar(s[pos]) || s[pos] == '.')) pos++;
            t.k = T_META;
            t.s = s.substr(st, pos - st);
            return;
        }
        if (c == '~' && at(1) == '/') { lexRegex(t); return; }
        pos++;
        switch (c) {
            case '(': t.k = T_LP; return;
            case ')': t.k = T_RP; return;
            case '{': t.k = T_LB; return;
            case '}': t.k = T_RB; return;
            case '[': t.k = T_LK; return;
            case ']': t.k = T_RK; return;
            case ',': t.k = T_COMMA; return;
            case ';': t.k = T_SEMI; return;
            case ':': t.k = T_COLON; return;
            case '.':
                if (cur() == '.' && at(1) == '.') { pos += 2; t.k = T_OP; t.s = "..."; return; }
                t.k = T_DOT; return;
            case '?':
                if (cur() == '?') {
                    pos++;
                    if (cur() == '=') { pos++; t.k = T_QQA; return; }
                    t.k = T_QQ; return;
                }
                if (cur() == '.' && !isDigit(at(1))) { pos++; t.k = T_QDOT; return; }
                t.k = T_QUEST; return;
            default: break;
        }
        pos--;
        static const char* ops[] = {">>>=", "<<=", ">>=", ">>>", "==", "!=", "<=", ">=", "&&", "||", "++", "--",
                                    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", "=>", "->",
                                    "+", "-", "*", "/", "%", "&", "|", "^", "!", "~", "<", ">", "=", nullptr};
        for (int i = 0; ops[i]; i++) {
            size_t n = strlen(ops[i]);
            if (s.compare(pos, n, ops[i]) == 0) {
                pos += n;
                t.k = T_OP;
                t.s = ops[i];
                return;
            }
        }
        fail(origin, line, std::string("Invalid character '") + c + "'");
    }

    void lexNumber(Token& t) {
        size_t st = pos;
        if (cur() == '0' && (at(1) == 'x' || at(1) == 'X')) {
            pos += 2;
            uint64_t v = 0;
            size_t ds = pos;
            while (pos < s.size() && hexVal(s[pos]) >= 0) { v = v * 16 + (uint64_t)hexVal(s[pos]); pos++; }
            if (pos == ds) fail(origin, line, "Invalid hex literal");
            if (v <= 0xFFFFFFFFull) { t.k = T_INT; t.iv = (int32_t)(uint32_t)v; }
            else { t.k = T_FLOAT; t.fv = (double)v; }
            return;
        }
        bool isFloat = false;
        while (isDigit(cur())) pos++;
        if (cur() == '.' && isDigit(at(1))) {
            isFloat = true;
            pos++;
            while (isDigit(cur())) pos++;
        } else if (st == pos) {
            isFloat = true;
            pos++;
            while (isDigit(cur())) pos++;
        }
        if ((cur() == 'e' || cur() == 'E') && (isDigit(at(1)) || ((at(1) == '+' || at(1) == '-') && isDigit(at(2))))) {
            isFloat = true;
            pos += 2;
            while (isDigit(cur())) pos++;
        }
        std::string txt = s.substr(st, pos - st);
        if (isFloat) { t.k = T_FLOAT; t.fv = strtod(txt.c_str(), nullptr); }
        else {
            double d = strtod(txt.c_str(), nullptr);
            if (d > 2147483647.0) { t.k = T_FLOAT; t.fv = d; }
            else { t.k = T_INT; t.iv = (int64_t)d; }
        }
    }

    void escape(std::string& out) {
        char e = cur();
        pos++;
        switch (e) {
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            case 't': out += '\t'; break;
            case '0': out += '\0'; break;
            case '\\': out += '\\'; break;
            case '"': out += '"'; break;
            case '\'': out += '\''; break;
            case 'x': {
                int v = 0, n = 0;
                while (n < 2 && hexVal(cur()) >= 0) { v = v * 16 + hexVal(cur()); pos++; n++; }
                out += (char)v;
                break;
            }
            case 'u': {
                uint32_t v = 0;
                int n = 0;
                bool brace = false;
                if (cur() == '{') { brace = true; pos++; }
                while (n < (brace ? 6 : 4) && hexVal(cur()) >= 0) { v = v * 16 + (uint32_t)hexVal(cur()); pos++; n++; }
                if (brace && cur() == '}') pos++;
                appendUtf8(out, v);
                break;
            }
            default: out += '\\'; out += e; break;
        }
    }

    void lexString(Token& t, char q) {
        int startLine = line;
        pos++;
        std::string lit;
        std::vector<StrPart> parts;
        bool interp = (q == '\'');
        for (;;) {
            if (pos >= s.size()) fail(origin, startLine, "Unterminated string");
            char c = s[pos];
            if (c == q) { pos++; break; }
            if (c == '\n') line++;
            if (c == '\\') { pos++; escape(lit); continue; }
            if (interp && c == '$') {
                if (at(1) == '$') { lit += '$'; pos += 2; continue; }
                if (at(1) == '{') {
                    pos += 2;
                    int depth = 1;
                    size_t st = pos;
                    int exprLine = line;
                    while (pos < s.size() && depth > 0) {
                        char d = s[pos];
                        if (d == '\n') line++;
                        if (d == '{') depth++;
                        else if (d == '}') depth--;
                        else if (d == '"' || d == '\'') {
                            char qq = d;
                            pos++;
                            while (pos < s.size() && s[pos] != qq) { if (s[pos] == '\\') pos++; pos++; }
                        }
                        pos++;
                    }
                    if (depth != 0) fail(origin, startLine, "Unterminated string interpolation");
                    std::string ex = s.substr(st, pos - 1 - st);
                    if (!lit.empty()) { parts.push_back({false, lit, startLine}); lit.clear(); }
                    parts.push_back({true, ex, exprLine});
                    continue;
                }
                if (isIdStart(at(1))) {
                    pos++;
                    size_t st = pos;
                    while (pos < s.size() && isIdChar(s[pos])) pos++;
                    if (!lit.empty()) { parts.push_back({false, lit, startLine}); lit.clear(); }
                    parts.push_back({true, s.substr(st, pos - st), line});
                    continue;
                }
            }
            lit += c;
            pos++;
        }
        if (parts.empty()) { t.k = T_STR; t.s = lit; return; }
        if (!lit.empty()) parts.push_back({false, lit, startLine});
        t.k = T_ISTR;
        t.parts = std::move(parts);
    }

    void lexRegex(Token& t) {
        pos += 2;
        std::string pat;
        for (;;) {
            if (pos >= s.size() || s[pos] == '\n') fail(origin, line, "Unterminated regular expression");
            char c = s[pos];
            if (c == '\\' && at(1) == '/') { pat += '/'; pos += 2; continue; }
            if (c == '\\') { pat += c; pat += at(1); pos += 2; continue; }
            if (c == '/') { pos++; break; }
            pat += c;
            pos++;
        }
        std::string flags;
        while (pos < s.size() && isIdStart(s[pos])) flags += s[pos++];
        t.k = T_REGEX;
        t.s = pat;
        t.s2 = flags;
    }
};

class Parser {
public:
    Parser(std::vector<Token> toks, Ast& ast, const std::string& origin) : toks_(std::move(toks)), ast_(ast), origin_(origin) {}

    Node* parseProgramNode() {
        Node* root = ast_.mk(N::Block, 1);
        root->flag = true;
        while (peek().k != T_EOF) parseStatement(root->list);
        return root;
    }

    Node* parseSingleExpr() {
        Node* e = parseExpr();
        if (peek().k != T_EOF) unexpected();
        return e;
    }

private:
    std::vector<Token> toks_;
    size_t p_ = 0;
    Ast& ast_;
    std::string origin_;
    int depth_ = 0;
    int uid_ = 0;

    const Token& peek(size_t o = 0) const {
        size_t i = p_ + o;
        return i < toks_.size() ? toks_[i] : toks_.back();
    }
    const Token& next() {
        const Token& t = peek();
        if (p_ < toks_.size() - 1) p_++;
        return t;
    }
    bool isOp(const char* s, size_t o = 0) const { return peek(o).k == T_OP && peek(o).s == s; }
    bool isId(const char* s, size_t o = 0) const { return peek(o).k == T_ID && peek(o).s == s; }

    std::string tokText(const Token& t) const {
        switch (t.k) {
            case T_EOF: return "<eof>";
            case T_ID: case T_OP: return t.s;
            case T_INT: return std::to_string(t.iv);
            case T_FLOAT: return std::to_string(t.fv);
            case T_STR: case T_ISTR: return "<string>";
            case T_LP: return "("; case T_RP: return ")"; case T_LB: return "{"; case T_RB: return "}";
            case T_LK: return "["; case T_RK: return "]"; case T_COMMA: return ","; case T_SEMI: return ";";
            case T_DOT: return "."; case T_COLON: return ":"; case T_QUEST: return "?"; case T_QQ: return "??";
            case T_QQA: return "?\?="; case T_QDOT: return "?."; case T_META: return "@" + t.s; case T_REGEX: return "~/";
        }
        return "?";
    }

    [[noreturn]] void err(const std::string& m, int line = -1) { fail(origin_, line < 0 ? peek().line : line, m); }
    [[noreturn]] void unexpected() { err("Unexpected " + tokText(peek())); }

    void expect(TK k, const char* what) {
        if (peek().k != k) err(std::string("Expected ") + what + " but found " + tokText(peek()));
        next();
    }
    std::string ident() {
        if (peek().k != T_ID) err("Expected identifier but found " + tokText(peek()));
        return next().s;
    }

    Node* mk(N k, int line) { return ast_.mk(k, line); }

    void parseStatement(std::vector<Node*>& out) {
        if (peek().k == T_SEMI) { next(); return; }
        Node* e = parseExpr();
        out.push_back(e);
        endStatement();
    }

    void endStatement() {
        if (peek().k == T_SEMI) { next(); return; }
        if (peek().k == T_EOF || peek().k == T_RB) return;
        if (p_ > 0 && toks_[p_ - 1].k == T_RB) return;
        if (isId("case") || isId("default")) return;
        unexpected();
    }
    
    Node* parseBody() {
        if (peek().k == T_LB && peek(1).k == T_RB) {
            int ln = peek().line;
            next(); next();
            return mk(N::Block, ln);
        }
        return parseExpr();
    }

    Node* parseExpr() {
        if (++depth_ > 200) err("Expression is nested too deeply");
        Node* e = parseAssign();
        depth_--;
        return e;
    }

    static bool isAssignOp(const std::string& s) {
        return s == "=" || s == "+=" || s == "-=" || s == "*=" || s == "/=" || s == "%=" || s == "&=" || s == "|=" ||
               s == "^=" || s == "<<=" || s == ">>=" || s == ">>>=";
    }

    Node* parseAssign() {
        Node* lhs = parseTernary();
        const Token& t = peek();
        if (t.k == T_OP) {
            if (isAssignOp(t.s)) {
                int line = t.line;
                std::string op = t.s;
                next();
                Node* rhs = parseAssign();
                if (!(lhs->k == N::Ident || lhs->k == N::Field || lhs->k == N::Index))
                    err("Invalid assignment target", line);
                Node* n = mk(N::Assign, line);
                n->s = op; n->a = lhs; n->b = rhs;
                return n;
            }
            if (t.s == "=>") {
                int line = t.line;
                next();
                Node* rhs = parseAssign();
                Node* n = mk(N::Binop, line);
                n->s = "=>"; n->a = lhs; n->b = rhs;
                return n;
            }
        } else if (t.k == T_QQA) {
            int line = t.line;
            next();
            Node* rhs = parseAssign();
            if (!(lhs->k == N::Ident || lhs->k == N::Field || lhs->k == N::Index)) err("Invalid assignment target", line);
            Node* n = mk(N::Coalesce, line);
            n->a = lhs; n->b = rhs; n->flag = true;
            return n;
        }
        return lhs;
    }

    Node* parseTernary() {
        Node* c = parseCoalesce();
        if (peek().k == T_QUEST) {
            int line = next().line;
            Node* a = parseAssign();
            expect(T_COLON, "':'");
            Node* b = parseAssign();
            Node* n = mk(N::Ternary, line);
            n->a = c; n->b = a; n->c = b;
            return n;
        }
        return c;
    }

    Node* parseCoalesce() {
        Node* l = parseBin(1);
        if (peek().k == T_QQ) {
            int line = next().line;
            Node* r = parseCoalesce();
            Node* n = mk(N::Coalesce, line);
            n->a = l; n->b = r;
            return n;
        }
        return l;
    }

    static int binPrec(const std::string& s) {
        if (s == "||") return 1;
        if (s == "&&") return 2;
        if (s == "...") return 3;
        if (s == "==" || s == "!=" || s == "<" || s == ">" || s == "<=" || s == ">=") return 4;
        if (s == "|" || s == "&" || s == "^") return 5;
        if (s == "<<" || s == ">>" || s == ">>>") return 6;
        if (s == "+" || s == "-") return 7;
        if (s == "*" || s == "/" || s == "%") return 8;
        return -1;
    }

    Node* parseBin(int minPrec) {
        Node* lhs = parseUnary();
        for (;;) {
            const Token& t = peek();
            if (t.k == T_ID && t.s == "is" && minPrec <= 9) {
                int line = next().line;
                std::string path = ident();
                while (peek().k == T_DOT) { next(); path += "."; path += ident(); }
                Node* n = mk(N::Is, line);
                n->a = lhs; n->s = path;
                lhs = n;
                continue;
            }
            if (t.k != T_OP) break;
            int prec = binPrec(t.s);
            if (prec < 0 || prec < minPrec) break;
            int line = t.line;
            std::string op = t.s;
            next();
            Node* rhs = parseBin(prec + 1);
            Node* n = mk(N::Binop, line);
            n->s = op; n->a = lhs; n->b = rhs;
            lhs = n;
        }
        return lhs;
    }

    Node* parseUnary() {
        const Token& t = peek();
        if (t.k == T_OP) {
            if (t.s == "-") {
                int line = next().line;
                Node* e = parseUnary();
                if (e->k == N::Int && !e->paren) { e->iv = -e->iv; return e; }
                if (e->k == N::Float && !e->paren) { e->fv = -e->fv; return e; }
                Node* n = mk(N::Unop, line);
                n->s = "-"; n->flag = true; n->a = e;
                return n;
            }
            if (t.s == "!" || t.s == "~" || t.s == "++" || t.s == "--") {
                int line = t.line;
                std::string op = t.s;
                next();
                Node* e = parseUnary();
                if ((op == "++" || op == "--") && !(e->k == N::Ident || e->k == N::Field || e->k == N::Index))
                    err("Invalid operand for " + op, line);
                Node* n = mk(N::Unop, line);
                n->s = op; n->flag = true; n->a = e;
                return n;
            }
            if (t.s == "+") {
                next();
                return parseUnary();
            }
        }
        return parsePostfix(parsePrimary());
    }

    static bool noPostfix(const Node* e) {
        if (e->paren) return false;
        switch (e->k) {
            case N::Block: case N::If: case N::While: case N::DoWhile: case N::For: case N::Switch: case N::Try:
            case N::Var: case N::Vars: case N::Return: case N::Throw: case N::Break: case N::Continue:
                return true;
            case N::Func: return true;
            default: return false;
        }
    }

    Node* parsePostfix(Node* e) {
        for (;;) {
            const Token& t = peek();
            if (noPostfix(e)) return e;
            if (t.k == T_DOT) {
                int line = next().line;
                Node* n = mk(N::Field, line);
                n->a = e; n->s = ident();
                e = n;
            } else if (t.k == T_QDOT) {
                int line = next().line;
                Node* n = mk(N::SafeNav, line);
                n->a = e; n->s = ident();
                e = n;
            } else if (t.k == T_LP) {
                int line = next().line;
                Node* n = mk(N::Call, line);
                n->a = e;
                parseArgs(n->list);
                e = n;
            } else if (t.k == T_LK) {
                int line = next().line;
                Node* idx = parseExpr();
                expect(T_RK, "']'");
                Node* n = mk(N::Index, line);
                n->a = e; n->b = idx;
                e = n;
            } else if (t.k == T_OP && (t.s == "++" || t.s == "--") && (e->k == N::Ident || e->k == N::Field || e->k == N::Index)) {
                Node* n = mk(N::Unop, t.line);
                n->s = t.s; n->flag = false; n->a = e;
                next();
                e = n;
            } else {
                return e;
            }
        }
    }

    void parseArgs(std::vector<Node*>& out) {
        if (peek().k == T_RP) { next(); return; }
        for (;;) {
            out.push_back(parseExpr());
            if (peek().k == T_COMMA) { next(); if (peek().k == T_RP) { next(); return; } continue; }
            expect(T_RP, "')'");
            return;
        }
    }

    void skipTypeParams() {
        int depth = 0;
        for (;;) {
            Token& t = const_cast<Token&>(peek());
            if (t.k == T_EOF) err("Unterminated type parameters");
            if (t.k == T_OP && t.s != "->") {
                std::string rest;
                bool done = false;
                for (size_t i = 0; i < t.s.size(); i++) {
                    char c = t.s[i];
                    if (done) { rest += c; continue; }
                    if (c == '<') depth++;
                    else if (c == '>') { depth--; if (depth == 0) done = true; }
                }
                if (done) {
                    if (!rest.empty()) t.s = rest; else next();
                    return;
                }
            }
            next();
        }
    }

    std::string skipType() {
        std::string name;
        if (peek().k == T_QUEST) next();
        if (peek().k == T_LP) {
            int d = 0;
            for (;;) {
                TK k = peek().k;
                if (k == T_EOF) err("Unterminated type");
                if (k == T_LP) d++;
                if (k == T_RP) { d--; if (d == 0) { next(); break; } }
                next();
            }
            name = "Function";
        } else if (peek().k == T_LB) {
            int d = 0;
            for (;;) {
                TK k = peek().k;
                if (k == T_EOF) err("Unterminated type");
                if (k == T_LB) d++;
                if (k == T_RB) { d--; if (d == 0) { next(); break; } }
                next();
            }
            name = "Dynamic";
        } else {
            name = ident();
            while (peek().k == T_DOT) { next(); name += "."; name += ident(); }
            if (peek().k == T_OP && peek().s[0] == '<') skipTypeParams();
        }
        if (isOp("->")) { next(); skipType(); name = "Function"; }
        return name;
    }

    Node* parseInterp(const Token& t) {
        Node* n = mk(N::Interp, t.line);
        for (const StrPart& part : t.parts) {
            if (!part.isExpr) {
                Node* s = mk(N::Str, part.line);
                s->s = part.text;
                n->list.push_back(s);
            } else {
                Lexer lx(part.text, origin_, part.line);
                Parser sub(lx.run(), ast_, origin_);
                sub.depth_ = depth_ + 1;
                if (part.text.find_first_not_of(" \t\r\n") == std::string::npos) err("Expression cannot be empty", part.line);
                n->list.push_back(sub.parseSingleExpr());
            }
        }
        return n;
    }

    bool lambdaAhead() const {
        int d = 0;
        size_t i = p_;
        for (;; i++) {
            if (i >= toks_.size()) return false;
            TK k = toks_[i].k;
            if (k == T_EOF) return false;
            if (k == T_LP) d++;
            else if (k == T_RP) { d--; if (d == 0) break; }
        }
        return i + 1 < toks_.size() && toks_[i + 1].k == T_OP && toks_[i + 1].s == "->";
    }

    Node* parseLambda(int line) {
        Node* f = mk(N::Func, line);
        if (peek().k == T_LP) {
            next();
            parseParams(f);
        } else {
            Param pr;
            pr.name = ident();
            f->params.push_back(pr);
        }
        if (!isOp("->")) unexpected();
        next();
        f->a = parseExpr();
        return f;
    }

    void parseParams(Node* f) {
        if (peek().k == T_RP) { next(); return; }
        for (;;) {
            Param pr;
            if (peek().k == T_QUEST) { next(); pr.opt = true; }
            pr.name = ident();
            if (peek().k == T_COLON) { next(); skipType(); }
            if (isOp("=")) { next(); pr.def = parseExpr(); }
            f->params.push_back(pr);
            if (peek().k == T_COMMA) { next(); continue; }
            expect(T_RP, "')'");
            return;
        }
    }

    Node* parseFunction(int line) {
        Node* f = mk(N::Func, line);
        if (peek().k == T_ID) f->s = next().s;
        expect(T_LP, "'('");
        parseParams(f);
        if (peek().k == T_COLON) { next(); skipType(); }
        f->a = parseExpr();
        return f;
    }

    Node* parseVar(bool isFinal, int line) {
        std::vector<Node*> vars;
        for (;;) {
            Node* v = mk(N::Var, peek().line);
            v->flag = isFinal;
            v->s = ident();
            if (peek().k == T_COLON) { next(); skipType(); }
            if (isOp("=")) { next(); v->a = parseExpr(); }
            vars.push_back(v);
            if (peek().k == T_COMMA) { next(); continue; }
            break;
        }
        if (vars.size() == 1) return vars[0];
        Node* n = mk(N::Vars, line);
        n->list = vars;
        return n;
    }

    Node* parseBlockBody(int line) {
        Node* b = mk(N::Block, line);
        while (peek().k != T_RB) {
            if (peek().k == T_EOF) err("Missing '}'", line);
            parseStatement(b->list);
        }
        next();
        return b;
    }

    static void flattenOr(Node* e, std::vector<Node*>& out) {
        if (e->k == N::Binop && e->s == "|" && !e->paren) { flattenOr(e->a, out); flattenOr(e->b, out); }
        else out.push_back(e);
    }

    Node* parseCaseBody(int line) {
        Node* b = mk(N::Block, line);
        while (!(isId("case") || isId("default") || peek().k == T_RB)) {
            if (peek().k == T_EOF) err("Unterminated switch");
            parseStatement(b->list);
        }
        if (b->list.size() == 1) return b->list[0];
        return b;
    }

    Node* mapCompr(const std::string& tmp, Node* e) {
        switch (e->k) {
            case N::For: case N::While: case N::DoWhile: e->b = mapCompr(tmp, e->b); return e;
            case N::If:
                if (!e->c) { e->b = mapCompr(tmp, e->b); return e; }
                break;
            case N::Block:
                if (e->list.size() == 1) { e->list[0] = mapCompr(tmp, e->list[0]); return e; }
                break;
            default: break;
        }
        int line = e->line;
        Node* id = mk(N::Ident, line); id->s = tmp;
        Node* f = mk(N::Field, line); f->a = id; f->s = "push";
        Node* c = mk(N::Call, line); c->a = f; c->list.push_back(e);
        return c;
    }

    Node* parsePrimary() {
        const Token& t = peek();
        int line = t.line;
        switch (t.k) {
            case T_INT: { Node* n = mk(N::Int, line); n->iv = t.iv; next(); return n; }
            case T_FLOAT: { Node* n = mk(N::Float, line); n->fv = t.fv; next(); return n; }
            case T_STR: { Node* n = mk(N::Str, line); n->s = t.s; next(); return n; }
            case T_ISTR: { Node* n = parseInterp(t); next(); return n; }
            case T_REGEX: { Node* n = mk(N::Regex, line); n->s = t.s; n->s2 = t.s2; next(); return n; }
            case T_LP: {
                if (lambdaAhead()) return parseLambda(line);
                next();
                Node* e = parseExpr();
                if (peek().k == T_COLON) { next(); skipType(); }
                expect(T_RP, "')'");
                e->paren = true;
                return e;
            }
            case T_LB: {
                next();
                if (peek().k == T_RB) { next(); return mk(N::Object, line); }
                if ((peek().k == T_ID || peek().k == T_STR) && peek(1).k == T_COLON) {
                    Node* o = mk(N::Object, line);
                    for (;;) {
                        if (peek().k == T_RB) { next(); break; }
                        if (peek().k != T_ID && peek().k != T_STR) unexpected();
                        std::string key = next().s;
                        expect(T_COLON, "':'");
                        o->names.push_back(key);
                        o->list.push_back(parseExpr());
                        if (peek().k == T_COMMA) { next(); continue; }
                        expect(T_RB, "'}'");
                        break;
                    }
                    return o;
                }
                return parseBlockBody(line);
            }
            case T_LK: {
                next();
                if (peek().k == T_RK) { next(); return mk(N::Array, line); }
                if (isId("for") || isId("while")) {
                    Node* loop = parseExpr();
                    expect(T_RK, "']'");
                    std::string tmp = "__a_" + std::to_string(uid_++) + "_" + std::to_string(line);
                    Node* blk = mk(N::Block, line);
                    Node* v = mk(N::Var, line); v->s = tmp; v->a = mk(N::Array, line);
                    blk->list.push_back(v);
                    blk->list.push_back(mapCompr(tmp, loop));
                    Node* id = mk(N::Ident, line); id->s = tmp;
                    blk->list.push_back(id);
                    return blk;
                }
                std::vector<Node*> items;
                for (;;) {
                    items.push_back(parseExpr());
                    if (peek().k == T_COMMA) { next(); if (peek().k == T_RK) { next(); break; } continue; }
                    expect(T_RK, "']'");
                    break;
                }
                bool isMap = items[0]->k == N::Binop && items[0]->s == "=>";
                Node* n = mk(isMap ? N::MapLit : N::Array, line);
                for (Node* it : items) {
                    if (isMap) {
                        if (!(it->k == N::Binop && it->s == "=>")) err("Expected key => value", it->line);
                        n->list.push_back(it->a);
                        n->list.push_back(it->b);
                    } else {
                        if (it->k == N::Binop && it->s == "=>") err("Mixed array and map literal", it->line);
                        n->list.push_back(it);
                    }
                }
                return n;
            }
            case T_META: {
                next();
                if (peek().k == T_LP) {
                    int d = 0;
                    for (;;) {
                        TK k = peek().k;
                        if (k == T_EOF) err("Unterminated metadata");
                        if (k == T_LP) d++;
                        if (k == T_RP) { d--; if (d == 0) { next(); break; } }
                        next();
                    }
                }
                if (peek().k == T_SEMI || peek().k == T_RB || peek().k == T_EOF) return mk(N::Nop, line);
                return parseExpr();
            }
            case T_ID: break;
            default: unexpected();
        }

        const std::string& w = t.s;
        if (peek(1).k == T_OP && peek(1).s == "->" && w != "case") return parseLambda(line);
        if (w == "var" || w == "final") {
            next();
            return parseVar(w == "final", line);
        }
        if (w == "function") { next(); return parseFunction(line); }
        if (w == "if") {
            next();
            expect(T_LP, "'('");
            Node* c = parseExpr();
            expect(T_RP, "')'");
            Node* n = mk(N::If, line);
            n->a = c;
            n->b = parseExpr();
            if (peek().k == T_SEMI && isId("else", 1)) next();
            if (isId("else")) { next(); n->c = parseExpr(); }
            return n;
        }
        if (w == "while") {
            next();
            expect(T_LP, "'('");
            Node* c = parseExpr();
            expect(T_RP, "')'");
            Node* n = mk(N::While, line);
            n->a = c; n->b = parseBody();
            return n;
        }
        if (w == "do") {
            next();
            Node* body = parseBody();
            if (peek().k == T_SEMI) next();
            if (!isId("while")) err("Expected 'while' after do-body but found " + tokText(peek()));
            next();
            expect(T_LP, "'('");
            Node* c = parseExpr();
            expect(T_RP, "')'");
            Node* n = mk(N::DoWhile, line);
            n->a = c; n->b = body;
            return n;
        }
        if (w == "for") {
            next();
            expect(T_LP, "'('");
            Node* n = mk(N::For, line);
            n->s = ident();
            if (isOp("=>")) { next(); n->s2 = ident(); }
            if (!isId("in")) err("Expected 'in' but found " + tokText(peek()));
            next();
            n->a = parseExpr();
            expect(T_RP, "')'");
            n->b = parseBody();
            return n;
        }
        if (w == "switch") {
            next();
            Node* n = mk(N::Switch, line);
            n->a = parseExpr();
            expect(T_LB, "'{'");
            for (;;) {
                if (peek().k == T_RB) { next(); break; }
                if (isId("case")) {
                    int cl = next().line;
                    CaseC c;
                    bool isDefault = false;
                    for (;;) {
                        Node* v = parseExpr();
                        std::vector<Node*> alts;
                        flattenOr(v, alts);
                        for (Node* a : alts) {
                            if (a->k == N::Ident && a->s == "_") isDefault = true;
                            else c.values.push_back(a);
                        }
                        if (peek().k == T_COMMA) { next(); continue; }
                        break;
                    }
                    if (isId("if")) {
                        next();
                        expect(T_LP, "'('");
                        c.guard = parseExpr();
                        expect(T_RP, "')'");
                    }
                    expect(T_COLON, "':'");
                    c.body = parseCaseBody(cl);
                    if (isDefault && c.values.empty() && !c.guard) { if (n->b) err("Duplicate default", cl); n->b = c.body; }
                    else n->cases.push_back(std::move(c));
                } else if (isId("default")) {
                    int cl = next().line;
                    expect(T_COLON, "':'");
                    if (n->b) err("Duplicate default", cl);
                    n->b = parseCaseBody(cl);
                } else {
                    unexpected();
                }
            }
            return n;
        }
        if (w == "try") {
            next();
            Node* n = mk(N::Try, line);
            n->a = parseExpr();
            if (peek().k == T_SEMI && isId("catch", 1)) next();
            if (!isId("catch")) err("Expected 'catch' but found " + tokText(peek()));
            while (isId("catch")) {
                next();
                expect(T_LP, "'('");
                CatchC c;
                c.var = ident();
                if (peek().k == T_COLON) { next(); c.type = skipType(); }
                expect(T_RP, "')'");
                c.body = parseExpr();
                n->catches.push_back(c);
                if (peek().k == T_SEMI && isId("catch", 1)) next();
            }
            return n;
        }
        if (w == "return") {
            next();
            Node* n = mk(N::Return, line);
            TK k = peek().k;
            if (k != T_SEMI && k != T_RB && k != T_EOF) n->a = parseExpr();
            return n;
        }
        if (w == "break") { next(); return mk(N::Break, line); }
        if (w == "continue") { next(); return mk(N::Continue, line); }
        if (w == "throw") { next(); Node* n = mk(N::Throw, line); n->a = parseExpr(); return n; }
        if (w == "new") {
            next();
            Node* n = mk(N::New, line);
            n->s = ident();
            while (peek().k == T_DOT) { next(); n->s += "."; n->s += ident(); }
            if (peek().k == T_OP && peek().s[0] == '<') skipTypeParams();
            expect(T_LP, "'('");
            parseArgs(n->list);
            return n;
        }
        if (w == "cast") {
            next();
            if (peek().k == T_LP) {
                next();
                Node* e = parseExpr();
                if (peek().k == T_COMMA) {
                    next();
                    std::string ty = skipType();
                    expect(T_RP, "')'");
                    Node* c = mk(N::Cast, line);
                    c->a = e;
                    c->s = ty;
                    return c;
                }
                expect(T_RP, "')'");
                e->paren = true;
                return e;
            }
            return parseExpr();
        }
        if (w == "untyped") { next(); return parseExpr(); }
        if (w == "import" || w == "using" || w == "package") {
            next();
            Node* n = mk(w == "import" ? N::Import : N::Nop, line);
            std::string last, full;
            std::string alias;
            bool star = false;
            while (peek().k != T_SEMI && peek().k != T_EOF) {
                const Token& x = next();
                if (x.k == T_ID) {
                    if (x.s == "as" || x.s == "in") { alias = ident(); break; }
                    last = x.s;
                    if (!full.empty()) full += ".";
                    full += x.s;
                } else if (x.k == T_OP && x.s == "*") star = true;
            }
            n->s = last; n->s2 = alias;
            n->names.push_back(full);
            n->flag = (w == "using") || star;
            n->iv = star ? 1 : 0;
            return n;
        }
        if (w == "else") unexpected();
        if ((w == "public" || w == "private" || w == "static" || w == "inline" || w == "override" || w == "extern") &&
            peek(1).k == T_ID) {
            next();
            return parsePrimary();
        }
        Node* n = mk(N::Ident, line);
        n->s = w;
        next();
        return n;
    }
};

}  // namespace

void parseProgram(const std::string& src, const std::string& origin, Ast& ast, int startLine) {
    Lexer lx(src, origin, startLine);
    Parser ps(lx.run(), ast, origin);
    ast.root = ps.parseProgramNode();
}

}  // namespace ssvm
