#!/usr/bin/env python3
"""Generate packages/llvm/src/*.auk from gen/bind.txt and LLVM's C headers.

    python3 packages/llvm/gen/gen.py [--llvm /opt/homebrew/opt/llvm@23] [--auk target/release/auk] [--check]

bind.txt lists LLVM C names (functions, `LLVM*Ref` types, enum values), one per line; `#` starts
a comment. Every name is looked up in `<llvm>/include/llvm-c/**/*.h`:

- a function becomes an `extern fn` with its C prototype (in the module of its area: the header
  and, for Core.h, its `@defgroup`), named in snake_case without `LLVM` (`LLVMBuildAdd` →
  `llvm.builder.build_add`);
- an opaque pointer typedef (`typedef struct X *LLVMFooRef`) becomes `pub extern type Foo` in
  `llvm` (lib.auk);
- an enum value becomes `pub let` constant in `llvm` (`LLVMIntEQ` → `llvm.INT_EQ`).

Types: `LLVM*Ref` → its extern type; `LLVMBool`, enums and integer typedefs → `int`; `const char *`
→ `str`; `char **` out-parameter → `var str?` (`+free(LLVMDisposeMessage)`); an owned `char *`
result → `str` (freed after the copy); `T *` with a count → a list `[T]`, without one → `var T?`
(an out-parameter); callbacks and other pointers → `ffi.Ptr`. A `const char *` followed by its
length, and a list followed by its count, get a wrapper without the length (`str` lengths are
bytes). The output is formatted with `auk fmt`. `--survey` tries every function in the headers
(writing nothing) and counts the ones the FFI can't express, by reason. `--check` lists the LLVM names `src/` uses that bind.txt is missing, and writes nothing.

The names the generator can't bind are printed with the reason, and listed in the README.
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PKG))

# ---- reading the headers -------------------------------------------------------------------

INT_TYPES = {
    "int", "unsigned", "unsigned int", "long", "unsigned long", "long long", "unsigned long long",
    "short", "unsigned short", "char", "unsigned char", "signed char", "int8_t", "uint8_t", "int16_t",
    "uint16_t", "int32_t", "uint32_t", "int64_t", "uint64_t", "size_t", "ssize_t", "intptr_t", "uintptr_t",
}


def blank(text, pattern, flags=0):
    """`text` with every match of `pattern` replaced by spaces (newlines kept): offsets stay."""
    return re.sub(pattern, lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=flags)


class Headers:
    def __init__(self, inc):
        self.funcs = {}      # name -> (ret, [(ctype, pname)], header, group)
        self.opaque = {}     # LLVMFooRef -> struct name
        self.ints = {}       # typedef name -> C integer type
        self.enums = {}      # enum typedef name -> [values]
        self.consts = {}     # enum value -> int
        self.callbacks = set()
        self.ptrs = set()    # typedefs of pointers to structs (`LLVMOrcCSymbolMapPairs`)
        self.structs = set()  # structs used by value
        for dirpath, _, files in os.walk(inc):
            for f in sorted(files):
                if f.endswith(".h"):
                    p = os.path.join(dirpath, f)
                    self.read(p, os.path.relpath(p, inc))

    def read(self, path, rel):
        raw = open(path, encoding="utf-8").read()
        groups = [(m.start(), m.group(1)) for m in re.finditer(r"@defgroup\s+(\w+)", raw)]
        t = blank(raw, r"/\*.*?\*/", re.S)
        t = blank(t, r"//[^\n]*")
        t = blank(t, r"^[ \t]*#(?:[^\n]*\\\n)*[^\n]*", re.M)
        for macro in ("LLVM_C_ABI", "LLVM_C_EXTERN_C_BEGIN", "LLVM_C_EXTERN_C_END"):
            t = t.replace(macro, " " * len(macro))
        # enums: `typedef enum { ... } Name;` and anonymous `enum { ... };`
        for m in re.finditer(r"(typedef\s+)?enum\s*(\w*)\s*\{([^}]*)\}\s*(\w*)\s*;", t):
            vals = self.enum_body(m.group(3))
            for n in (m.group(2), m.group(4)):
                if n:
                    self.enums[n] = vals
        for m in re.finditer(r"typedef\s+struct\s+\w+\s*\*\s*(\w+)\s*;", t):
            self.opaque[m.group(1)] = True
        for m in re.finditer(r"typedef\s+struct\s*\w*\s*\{[^}]*\}\s*(\w+)\s*;", t):
            self.structs.add(m.group(1))
        for m in re.finditer(r"typedef\s+struct\s+(\w+)\s+(\w+)\s*;", t):
            self.structs.add(m.group(2))
        for m in re.finditer(r"typedef\s+([A-Za-z_][\w ]*?)\s+(\w+)\s*;", t):
            base = " ".join(m.group(1).split())
            if base in INT_TYPES:
                self.ints[m.group(2)] = base
            elif base.startswith("struct") or base.startswith("enum"):
                pass
        for m in re.finditer(r"typedef\s+(?:const\s+)?(\w+)\s*\*\s*(\w+)\s*;", t):
            if m.group(1) != "struct":
                self.ptrs.add(m.group(2))
        for m in re.finditer(r"typedef\s+[\w\s\*]+\(\s*\*\s*(\w+)\s*\)", t):
            self.callbacks.add(m.group(1))
        # function declarations
        for m in re.finditer(r"([A-Za-z_][\w \t\n\*]*?)\b(LLVM\w+)\s*\(([^()]*)\)\s*;", t):
            ret = " ".join(w for w in m.group(1).split() if w != "extern")
            if not ret or ret.startswith("typedef") or "return" in ret.split():
                continue
            ret = ret.split("}")[-1].strip()
            name = m.group(2)
            params = []
            body = " ".join(m.group(3).split())
            if body and body != "void":
                for i, p in enumerate(body.split(",")):
                    params.append(split_param(p.strip()))
            group = ""
            for pos, g in groups:
                if pos < m.start():
                    group = g
            if name not in self.funcs:
                self.funcs[name] = (ret, params, rel, group)

    def enum_body(self, body):
        vals = []
        nxt = 0
        for item in body.split(","):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                n, e = item.split("=", 1)
                n = n.strip()
                try:
                    v = self.eval(e)
                except (SyntaxError, NameError, TypeError):
                    continue  # an expression this reader can't evaluate (none we bind)
            else:
                n, v = item, nxt
            self.consts[n] = v
            vals.append(n)
            nxt = v + 1
        return vals

    def eval(self, e):
        e = re.sub(r"\b(0[xX][0-9a-fA-F]+|\d+)[uUlL]+\b", r"\1", e.strip())
        return int(eval(e, {"__builtins__": {}}, dict(self.consts)))


def split_param(p):
    """`const char *Name` → ('const char *', 'Name'); an unnamed parameter has name ''. An
    array `T Name[]` is ('T *', 'Name[]')."""
    arr = p.endswith("[]")
    if arr:
        p = p[:-2] + " *"
        p = re.sub(r"(\w+)\s*\*$", r"* \1", p)
    toks = p.replace("*", " * ").split()
    kw = {"int", "char", "long", "short", "double", "float", "void", "unsigned", "signed", "const", "struct", "enum", "*"}
    name = ""
    if len(toks) >= 2 and toks[-1] not in kw and toks[-2] not in ("struct", "enum"):
        name = toks.pop()
    t = " ".join(toks).replace(" *", "*").replace("*", " *").replace("* *", "**").strip()
    return (t, name + "[]" if arr and name else name)


# ---- types ----------------------------------------------------------------------------------


class CT:
    """A C type: base name, pointer depth, whether the pointee is const."""

    def __init__(self, s):
        words = s.replace("*", " * ").split()
        self.stars = words.count("*")
        self.konst = "const" in words[: words.index("*")] if self.stars else "const" in words
        base = [w for w in words if w not in ("*", "const", "struct", "enum")]
        self.base = " ".join(base)

    def ptr(self):
        return self.stars > 0


def snake(name):
    s = name[4:] if name.startswith("LLVM") else name
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
    # a one-letter prefix joins the word after it (`FAdd` → `fadd`, `ICmp` → `icmp`, `AArch64`
    # → `aarch64`), except the `a` of `IsA...`
    ws = s.lower().split("_")
    out = []
    i = 0
    while i < len(ws):
        w = ws[i]
        if len(w) == 1 and w.isalpha() and i + 1 < len(ws) and not (w == "a" and out and out[-1] == "is"):
            ws[i + 1] = w + ws[i + 1]
        else:
            out.append(w)
        i += 1
    return "_".join(out)


def type_name(ref):
    """`LLVMOrcLLJITRef` → `OrcLLJIT`."""
    s = ref[4:] if ref.startswith("LLVM") else ref
    return s[:-3] if s.endswith("Ref") else s


def const_name(v):
    """`LLVMIntEQ` → `INT_EQ`, `LLVMDIFlagArtificial` → `DI_FLAG_ARTIFICIAL`."""
    return snake(v).upper()


KEYWORDS = {
    "fn", "let", "var", "if", "else", "match", "loop", "while", "for", "in", "break", "continue", "return",
    "true", "false", "struct", "enum", "pub", "async", "await", "catch", "is", "when", "uses", "requires",
    "ensures", "assert", "type", "test", "extern", "shape", "and", "or", "not", "none", "some", "self",
    "llvm", "ffi", "str", "int", "float", "bool",
}

UNNAMED = {"LLVMBuilderRef": "b", "LLVMModuleRef": "m", "LLVMValueRef": "v", "LLVMTypeRef": "ty", "LLVMContextRef": "c", "LLVMMetadataRef": "md", "LLVMDIBuilderRef": "d"}

# Functions whose `LLVM*Ref` result may be NULL (→ `T?`).
NULLABLE_RET = re.compile(r"^LLVM(GetFirst|GetNext|GetPrevious|GetLast|IsA|GetNamed|GetInitializer$|GetInsertBlock$|CreateTargetMachine$|GetPersonalityFn$|AliasGetAliasee$|GetTypeByName|GetEntryBasicBlock$|GetBasicBlockTerminator$|GetMetadata$|GetSubprogram$|GetCurrentDebugLocation2$|OrcAbsoluteSymbols$)")
# (function, parameter) pairs where NULL is a valid argument (→ `T?`).
NULLABLE_ARG = {
    ("LLVMSetInitializer", "ConstantVal"), ("LLVMSetCurrentDebugLocation2", "Loc"), ("LLVMOrcCreateLLJIT", "Builder"),
    ("LLVMRunPasses", "TM"), ("LLVMDIBuilderCreateDebugLocation", "InlinedAt"), ("LLVMDIBuilderCreateSubroutineType", "File"),
    ("LLVMDIBuilderCreateFunction", "Ty"), ("LLVMSetPersonalityFn", "PersonalityFn"), ("LLVMSetSubprogram", "SP"),
}
# Parameters that are byte buffers (`[int]`) rather than strings.
BYTES_ARG = {("LLVMCreateMemoryBufferWithMemoryRangeCopy", "InputData")}
# `T *` parameters that are arrays the callee fills (`var [T]`), with no count.
FILL_LIST = {("LLVMGetParams", "Params"), ("LLVMGetParamTypes", "Dest"), ("LLVMGetBasicBlocks", "BasicBlocksRefs"), ("LLVMGetStructElementTypes", "Dest")}
# `const char *` results that are bytes, not strings (→ `ffi.Ptr`; read them with `ffi.bytes`).
PTR_RET = {"LLVMGetBufferStart"}
COUNT = re.compile(r"^(Num[A-Z]\w*|N)$|(Count|Len|Length|Size)$")


class Binder:
    def __init__(self, h):
        self.h = h
        self.types = {}     # LLVMFooRef -> Auk name, the opaque types used
        self.skipped = []   # (name, why)

    def resolve(self, ct):
        """Typedefs that the FFI's prototype parser doesn't know, rewritten to C it does."""
        b = ct.base
        if b == "LLVMBool":
            return "int"
        if b in self.h.enums:
            return "int"
        if b in self.h.ints:
            return self.h.ints[b]
        return b

    def counted(self, rest):
        """Is the first parameter after a run of `T *` parameters in `rest` a count?"""
        for ctype, pname in rest:
            c = CT(ctype)
            if c.stars == 1 and c.base in self.h.opaque:
                continue
            return bool(COUNT.search(pname or "")) and c.stars == 0 and (self.resolve(c) in INT_TYPES)
        return False

    def param(self, fname, ct, pname, nxt):
        """(Auk type, C spelling, kind) for one parameter; kind: '', 'str', 'list', 'out'."""
        h = self.h
        base = ct.base
        if pname.endswith("[]"):
            rb = self.resolve(ct)
            if ct.stars == 1 and rb in INT_TYPES:
                return ("[int]", ("const " if ct.konst else "") + rb + " *", "list")
            if ct.stars == 1 and base in h.opaque:
                return (f"[{self.ref(base)}]", ("const " if ct.konst else "") + base + " *", "list")
            raise Skip(f"an array of `{base}`")
        if base in h.structs and not ct.ptr():
            raise Skip(f"`{base}` is a struct passed by value")
        if base in h.callbacks:
            return ("ffi.Ptr", "void *", "")
        if base in h.ptrs:
            return ("ffi.Ptr", "void *", "")
        if base in h.opaque:
            t = self.ref(base)
            if ct.stars == 0:
                opt = "?" if (fname, pname) in NULLABLE_ARG else ""
                return (t + opt, base, "")
            if ct.stars == 1:
                if (fname, pname) in FILL_LIST:
                    return (f"var [{t}]", base + " *", "fill")
                if self.counted(nxt):
                    return (f"[{t}]", ("const " if ct.konst else "") + base + " *", "list")
                return (f"var {t}?", base + " *", "out")
            raise Skip(f"`{base}` with {ct.stars} levels of pointer")
        if base in ("char",) and ct.stars == 1:
            if (fname, pname) in BYTES_ARG:
                return ("[int]", "const char *", "list")
            if ct.konst:
                return ("str", "const char *", "str")
            return ("ffi.Ptr", "char *", "")
        if base == "char" and ct.stars == 2:
            if ct.konst:
                raise Skip("`const char **` (an array of C strings)")
            return ("var str?", "char **", "msg")
        if base == "void" and ct.stars >= 1:
            return ("ffi.Ptr", "void *", "")
        rb = self.resolve(ct)
        if rb in INT_TYPES:
            if ct.stars == 0:
                return ("int", rb, "")
            if ct.stars == 1 and rb not in ("char",):
                if nxt and COUNT.search(nxt[0][1] or ""):
                    return ("[int]", ("const " if ct.konst else "") + rb + " *", "list")
                return ("var int", rb + " *", "out")
        if rb in ("double", "float") and ct.stars == 0:
            return ("float", rb, "")
        if base in h.structs and ct.stars == 1:
            return ("ffi.Ptr", ("const " if ct.konst else "") + "void *", "")
        raise Skip(f"parameter type `{base}{' ' + '*' * ct.stars if ct.stars else ''}`")

    def result(self, fname, ct):
        h = self.h
        base = ct.base
        if ct.stars == 0 and base == "void":
            return ("", "void", None)
        if base in h.structs and not ct.ptr():
            raise Skip(f"returns the struct `{base}` by value")
        if base in h.opaque and ct.stars == 0:
            t = self.ref(base)
            opt = base == "LLVMErrorRef" or NULLABLE_RET.match(fname)
            return (t + ("?" if opt else ""), base, None)
        if base == "char" and ct.stars == 1:
            if fname in PTR_RET:
                return ("ffi.Ptr", "const char *", None)
            if ct.konst:
                return ("str", "const char *", None)
            free = "LLVMDisposeErrorMessage" if fname == "LLVMGetErrorMessage" else "LLVMDisposeMessage"
            return ("str", "char *", free)
        if base in h.ptrs or base in h.callbacks or (base == "void" and ct.stars == 1):
            return ("ffi.Ptr", "void *", None)
        if ct.stars == 1 and (base in h.structs or base in h.opaque or self.resolve(ct) in INT_TYPES):
            # a pointer to structs or to an array LLVM owns: read it with `ffi.read_*`
            return ("ffi.Ptr", ("const " if ct.konst else "") + "void *", None)
        rb = self.resolve(ct)
        if rb in INT_TYPES and ct.stars == 0:
            return ("int", rb, None)
        if rb in ("double", "float") and ct.stars == 0:
            return ("float", rb, None)
        raise Skip(f"result type `{base}{' ' + '*' * ct.stars if ct.stars else ''}`")

    def ref(self, base):
        self.types[base] = type_name(base)
        return "llvm." + type_name(base)

    def bind(self, name):
        """The Auk text binding the function `name`."""
        ret, params, hdr, group = self.h.funcs[name]
        rt, rc, free = self.result(name, CT(ret))
        used = set()
        ps = []
        for i, (ctype, pname) in enumerate(params):
            nxt = params[i + 1 :]
            at, cs, kind = self.param(name, CT(ctype), pname, nxt)
            if kind == "msg":
                free = free or ("LLVMDisposeMessage" if not CT(ctype).konst else None)
            pname = pname.removesuffix("[]")
            an = snake("LLVM" + pname) if pname else UNNAMED.get(CT(ctype).base, "x")
            if an in KEYWORDS:
                an = {"fn": "func", "type": "ty", "in": "input", "is": "is_x", "if": "cond", "else": "otherwise", "str": "s"}.get(an, an + "_x")
            base_an = an
            k = 2
            while an in used:
                an = f"{base_an}{k}"
                k += 1
            used.add(an)
            ps.append({"auk": at, "c": cs, "kind": kind, "name": an, "cname": pname})
        def cparam(p):
            if not p["cname"]:
                return p["c"]
            return p["c"] + p["cname"] if p["c"].endswith("*") else p["c"] + " " + p["cname"]
        proto = f"{rc}{'' if rc.endswith('*') else ' '}{name}({', '.join(cparam(p) for p in ps) or 'void'})"
        if free and (rc == "char *" or any(p["kind"] == "msg" for p in ps)):
            proto += f" +free({free})"
        # wrappers drop a `str`'s byte length and a list's count
        drop = {}
        for i, p in enumerate(ps):
            if p["kind"] in ("str", "list") and i + 1 < len(ps) and ps[i + 1]["auk"] == "int" and COUNT.search(ps[i + 1]["cname"] or ""):
                j = i
                while j > 0 and ps[j - 1]["kind"] == "list" and p["kind"] == "list":
                    j -= 1
                src = ps[j]
                drop[i + 1] = f"{src['name']}.byte_len()" if src["kind"] == "str" else f"{src['name']}.len()"
        aname = snake(name)
        rsig = f": {rt}" if rt else ""
        sig = ", ".join(f"{p['name']}: {p['auk']}" for p in ps)
        if not drop:
            return f'pub extern fn {aname}({sig}){rsig} =\n  "{proto}"\n'
        keep = [p for i, p in enumerate(ps) if i not in drop]
        wsig = ", ".join(f"{p['name']}: {p['auk']}" for p in keep)
        args = ", ".join(drop.get(i, ("&" if p["auk"].startswith("var ") else "") + p["name"]) for i, p in enumerate(ps))
        return f'extern fn c_{aname}({sig}){rsig} =\n  "{proto}"\npub fn {aname}({wsig}){rsig} uses ffi = c_{aname}({args})\n'


class Skip(Exception):
    pass


# ---- areas ----------------------------------------------------------------------------------

AREAS = [
    ("ir", "Contexts, modules, types, attributes, module flags, verification and printing."),
    ("values", "Values: constants, globals, functions, parameters, basic blocks, instructions."),
    ("builder", "The instruction builder."),
    ("debug", "Debug info: the DIBuilder and debug locations."),
    ("target", "Targets, target machines, data layouts and object-file emission."),
    ("orc", "ORC LLJIT (compiling in memory), and LLVM errors."),
    ("bitcode", "Memory buffers, bitcode reading and writing, and the module linker."),
    ("passes", "The new pass manager (`run_passes`)."),
]


def area(name, hdr, group):
    if hdr.startswith("Transforms/"):
        return "passes"
    stem = hdr[:-2]
    if stem == "DebugInfo":
        return "debug"
    if stem in ("Target", "TargetMachine"):
        return "target"
    if stem in ("Orc", "LLJIT", "Error", "OrcEE", "LLJITUtils"):
        return "orc"
    if stem in ("BitReader", "BitWriter", "Linker", "IRReader"):
        return "bitcode"
    if stem == "Analysis":
        return "ir"
    if group == "LLVMCCoreInstructionBuilder":
        return "builder"
    if group == "LLVMCCoreMemoryBuffers":
        return "bitcode"
    if group.startswith("LLVMCCoreValue") or group.startswith("LLVMCoreValue") or group == "LLVMCCoreOperandBundle":
        return "values"
    return "ir"


# ---- main -----------------------------------------------------------------------------------


def read_list():
    names = []
    for line in open(os.path.join(HERE, "bind.txt"), encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            names.extend(line.split())
    return names


# llvm-sys spellings in src/ that differ from the C headers' (bind.txt has the C name).
RUST_NAMES = {"LLVMDWARFEmissionKindFull": "LLVMDWARFEmissionFull"}


def src_names():
    out = set()
    for d, _, fs in os.walk(os.path.join(ROOT, "src")):
        for f in fs:
            if f.endswith(".rs"):
                out |= set(re.findall(r"LLVM[A-Z][A-Za-z0-9]+", open(os.path.join(d, f), encoding="utf-8").read()))
    return out


HEADER = "// Generated by packages/llvm/gen/gen.py from gen/bind.txt and the LLVM {v} C headers; don't edit.\n"


def main():
    args = sys.argv[1:]
    llvm = "/opt/homebrew/opt/llvm@23"
    if "--llvm" in args:
        llvm = args[args.index("--llvm") + 1]
    names = read_list()
    if "--check" in args:
        missing = sorted(src_names() - set(names) - set(RUST_NAMES))
        print("\n".join(missing) if missing else "bind.txt covers every LLVM name in src/")
        sys.exit(1 if missing else 0)
    try:
        version = subprocess.run([os.path.join(llvm, "bin/llvm-config"), "--version"], capture_output=True, text=True).stdout.strip()
    except OSError:
        version = "?"
    h = Headers(os.path.join(llvm, "include/llvm-c"))
    b = Binder(h)
    if "--survey" in args:
        why = {}
        n = 0
        for f in sorted(h.funcs):
            if "Deprecated" in h.funcs[f][2] or h.funcs[f][2] == "lto.h":
                continue
            n += 1
            try:
                b.bind(f)
            except Skip as e:
                key = re.sub(r"`LLVM\w+`", "`LLVM...`", str(e))
                why.setdefault(key, []).append(f)
        bad = sum(len(v) for v in why.values())
        print(f"{n - bad} of {n} LLVM C functions bindable")
        for k, fs in sorted(why.items(), key=lambda kv: -len(kv[1])):
            print(f"  {len(fs):4} {k}: {', '.join(fs[:4])}{', ...' if len(fs) > 4 else ''}")
        return
    mods = {a: [] for a, _ in AREAS}
    consts = []
    other = []  # (name, what): bound as int / by hand / not bound
    seen = set()
    for n in names:
        if n in seen:
            continue
        seen.add(n)
        if n not in h.funcs and re.match(r"^LLVMIsA[A-Z]\w+$", n):
            # declared by LLVM_DECLARE_VALUE_CAST over every value subclass (Core.h)
            h.funcs[n] = ("LLVMValueRef", [("LLVMValueRef", "Val")], "Core.h", "LLVMCCoreValueGeneral")
        if n not in h.funcs and re.match(r"^LLVMInitialize\w+$", n):
            # declared by macros over the configured targets (Target.h): `void f(void)`
            h.funcs[n] = ("void", [], "Target.h", "")
        if n in h.funcs:
            try:
                ret, params, hdr, group = h.funcs[n]
                mods[area(n, hdr, group)].append(b.bind(n))
            except Skip as e:
                b.skipped.append((n, str(e)))
        elif n in h.opaque:
            b.ref(n)
        elif n in h.consts:
            consts.append(n)
        elif n in h.enums or n in h.ints or n == "LLVMBool":
            other.append((n, "a C integer type: `int`"))
        elif n in h.structs:
            other.append((n, "a struct: not bound (by value); see `llvm.kit` for the ones laid out by hand"))
        else:
            b.skipped.append((n, "not declared in the LLVM C headers (a Rust-only or inline name)"))
    os.makedirs(os.path.join(PKG, "src"), exist_ok=True)
    hdr = HEADER.format(v=version)
    for a, doc in AREAS:
        body = "".join(sorted(mods[a], key=lambda s: re.search(r"fn (?:c_)?(\w+)", s).group(1)))
        text = f"{hdr}\n/// {doc}\n\n{body}"
        open(os.path.join(PKG, "src", f"{a}.auk"), "w", encoding="utf-8").write(text)
    # lib.auk: the types and constants, then the hand-written head (gen/lib_head.auk)
    head = open(os.path.join(HERE, "lib_head.auk"), encoding="utf-8").read()
    lines = [hdr, head.rstrip() + "\n", "\n// ---- opaque C types (one per `LLVM*Ref`) ----\n\n"]
    for ref in sorted(b.types):
        lines.append(f'pub extern type {b.types[ref]} = "{ref}"\n')
    lines.append("\n// ---- enum values ----\n\n")
    for c in consts:
        lines.append(f"pub let {const_name(c)} = {h.consts[c]}  // {c}\n")
    open(os.path.join(PKG, "src", "lib.auk"), "w", encoding="utf-8").write("".join(lines))
    auk = os.path.join(ROOT, "target/release/auk")
    if "--auk" in args:
        auk = args[args.index("--auk") + 1]
    outs = [os.path.join(PKG, "src", f"{a}.auk") for a, _ in AREAS] + [os.path.join(PKG, "src", "lib.auk")]
    subprocess.run([auk, "fmt", *outs], check=True, stdout=subprocess.DEVNULL)
    # the summary (for the README)
    total = sum(len(v) for v in mods.values())
    report = [f"{total} functions, {len(b.types)} types, {len(consts)} constants"]
    for a, _ in AREAS:
        report.append(f"  {a}: {len(mods[a])}")
    for n, why in other:
        report.append(f"  type {n}: {why}")
    for n, why in b.skipped:
        report.append(f"  NOT BOUND {n}: {why}")
    print("\n".join(report))


if __name__ == "__main__":
    main()
