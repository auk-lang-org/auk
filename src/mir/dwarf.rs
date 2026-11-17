//! DWARF debug info for native builds (`duck build -g`): a line table that maps machine code
//! back to Duck source lines, and a subprogram per function, so lldb, gdb and editor front ends
//! like CodeLLDB can set `file:line` breakpoints, step by source line and show where they are.
//!
//! Lowering marks every statement with `Stmt::Loc` (an index into `Program::locs`); the
//! Cranelift back end turns those into source locations on instructions and collects, per
//! compiled function, the code offsets where each location starts (`FnLines`). This module
//! writes `.debug_info`, `.debug_abbrev`, `.debug_line`, `.debug_str`, `.debug_ranges` with
//! gimli into the object file, with relocations against the functions' symbols. On Mach-O the
//! linker leaves DWARF in the object file, so `duck build` runs `dsymutil` to gather it into
//! `<out>.dSYM`.
//!
//! Variables are not described: the instrumented debugger (`duck run --debug`, `duck debug`,
//! `duck dap`) is the one that shows Duck values.

use std::collections::HashMap;
use std::path::Path;

use cranelift_module::FuncId as CFuncId;
use cranelift_object::ObjectProduct;
use gimli::constants::*;
use gimli::write::{
    Address, AttributeValue, DwarfUnit, EndianVec, LineProgram, LineString, Range, RangeList, RelocateWriter, Relocation, RelocationTarget, Sections, Writer,
};
use gimli::{Encoding, Format, LineEncoding, RunTimeEndian, SectionId};
use object::write::{Relocation as ObjReloc, StandardSegment};
use object::{BinaryFormat, RelocationEncoding, RelocationFlags, RelocationKind, SectionKind};

use super::Program;

/// The line information of one compiled function.
pub struct FnLines {
    pub func: CFuncId,
    pub name: String,
    /// The size of its machine code.
    pub size: u32,
    /// (code offset, index into `Program::locs`), sorted by offset.
    pub rows: Vec<(u32, u32)>,
}

/// A section being written, with the relocations it needs.
#[derive(Clone)]
struct Sect {
    w: EndianVec<RunTimeEndian>,
    relocs: Vec<Relocation>,
}

impl RelocateWriter for Sect {
    type Writer = EndianVec<RunTimeEndian>;
    fn writer(&self) -> &Self::Writer {
        &self.w
    }
    fn writer_mut(&mut self) -> &mut Self::Writer {
        &mut self.w
    }
    fn relocate(&mut self, r: Relocation) {
        self.relocs.push(r);
    }
}

/// Add the debug info of `fns` (the functions with source locations) to the object.
pub fn emit(product: &mut ObjectProduct, prog: &Program, fns: &[FnLines]) -> Result<(), String> {
    let fns: Vec<&FnLines> = fns.iter().filter(|f| !f.rows.is_empty()).collect();
    if fns.is_empty() {
        return Ok(());
    }
    let encoding = Encoding { format: Format::Dwarf32, version: 4, address_size: 8 };
    let mut dwarf = DwarfUnit::new(encoding);
    let cwd = std::env::current_dir().map(|d| d.display().to_string()).unwrap_or_else(|_| "/".into());
    let abs = |f: &str| std::fs::canonicalize(f).map(|p| p.display().to_string()).unwrap_or_else(|_| f.to_string());
    // the compile unit is named after the program's first source file
    let main_file = prog.locs.iter().map(|l| &l.0).find(|f| Path::new(f).is_file()).map_or_else(|| abs(&prog.locs[0].0), |f| abs(f));
    let ls = |s: &str| LineString::String(s.as_bytes().to_vec());
    let mut lp = LineProgram::new(encoding, LineEncoding::default(), ls(&cwd), None, ls(&main_file), None);
    // a file entry per source file
    let mut files = HashMap::new();
    let mut file_of = |lp: &mut LineProgram, f: &str| {
        *files.entry(f.to_string()).or_insert_with(|| {
            let p = abs(f);
            let path = Path::new(&p);
            let dir = path.parent().map(|d| d.display().to_string()).filter(|d| !d.is_empty()).unwrap_or_else(|| cwd.clone());
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(p.clone());
            let d = lp.add_directory(ls(&dir));
            lp.add_file(ls(&name), d, None)
        })
    };
    let mut ranges = Vec::new();
    let root = dwarf.unit.root();
    for (i, f) in fns.iter().enumerate() {
        let sym = Address::Symbol { symbol: i, addend: 0 };
        lp.begin_sequence(Some(sym));
        // the prologue (before the first statement) belongs to the function's first line; the
        // first statement ends it, which is where debuggers put a function breakpoint
        let mut rows = f.rows.clone();
        if rows[0].0 > 0 {
            rows.insert(0, (0, rows[0].1));
        }
        let mut prev = None;
        for (k, &(off, loc)) in rows.iter().enumerate() {
            if prev == Some(loc) && k > 1 {
                continue;
            }
            prev = Some(loc);
            let (file, line, col) = &prog.locs[loc as usize];
            let fid = file_of(&mut lp, file);
            let row = lp.row();
            row.address_offset = off as u64;
            row.file = fid;
            row.line = *line as u64;
            row.column = *col as u64;
            row.is_statement = true;
            row.prologue_end = k == 1 || (k == 0 && f.rows[0].0 == 0);
            lp.generate_row();
        }
        lp.end_sequence(f.size as u64);
        ranges.push(Range::StartLength { begin: sym, length: f.size as u64 });
        // the function, where its first statement is
        let (file, line, _) = &prog.locs[f.rows[0].1 as usize];
        let fid = file_of(&mut lp, file);
        let sp = dwarf.unit.add(root, DW_TAG_subprogram);
        let e = dwarf.unit.get_mut(sp);
        e.set(DW_AT_name, AttributeValue::String(f.name.as_bytes().to_vec()));
        e.set(DW_AT_low_pc, AttributeValue::Address(sym));
        e.set(DW_AT_high_pc, AttributeValue::Udata(f.size as u64));
        e.set(DW_AT_decl_file, AttributeValue::FileIndex(Some(fid)));
        e.set(DW_AT_decl_line, AttributeValue::Udata(*line as u64));
        e.set(DW_AT_external, AttributeValue::Flag(true));
    }
    let rl = dwarf.unit.ranges.add(RangeList(ranges));
    dwarf.unit.line_program = lp;
    let e = dwarf.unit.get_mut(root);
    e.set(DW_AT_producer, AttributeValue::String(format!("duck {}", env!("CARGO_PKG_VERSION")).into_bytes()));
    // no DWARF language code for Duck: C, so debuggers treat names and lines plainly
    e.set(DW_AT_language, AttributeValue::Language(DW_LANG_C99));
    e.set(DW_AT_name, AttributeValue::String(main_file.into_bytes()));
    e.set(DW_AT_comp_dir, AttributeValue::String(cwd.into_bytes()));
    e.set(DW_AT_low_pc, AttributeValue::Address(Address::Constant(0)));
    e.set(DW_AT_ranges, AttributeValue::RangeListRef(rl));

    // every target Duck builds for is little-endian (x86-64, AArch64)
    let endian = RunTimeEndian::Little;
    let mut sections = Sections::new(Sect { w: EndianVec::new(endian), relocs: Vec::new() });
    dwarf.write(&mut sections).map_err(|e| format!("writing DWARF: {e}"))?;

    // Mach-O: dsymutil reads a function's address in the object file from the relocated data
    // (section address + offset). The object crate assigns section addresses only when it
    // writes the file, in section order, so the code's addresses don't move when the DWARF
    // sections are appended: write it once to learn them.
    let macho = product.object.format() == BinaryFormat::MachO;
    let mut code_base: HashMap<Vec<u8>, u64> = HashMap::new();
    if macho {
        use object::{Object, ObjectSection};
        let bytes = product.object.write().map_err(|e| format!("DWARF: {e}"))?;
        let file = object::File::parse(&*bytes).map_err(|e| format!("DWARF: {e}"))?;
        for s in file.sections() {
            if let Ok(n) = s.name_bytes() {
                code_base.insert(n.to_vec(), s.address());
            }
        }
    }
    // the sections, then their relocations (which may refer to each other)
    let obj = &mut product.object;
    let mut written: Vec<(SectionId, object::write::SectionId, Vec<Relocation>)> = Vec::new();
    let mut ids: HashMap<SectionId, object::write::SectionId> = HashMap::new();
    sections
        .for_each_mut(|id, s| -> gimli::write::Result<()> {
            if s.w.len() == 0 {
                return Ok(());
            }
            let mut data = std::mem::replace(&mut s.w, EndianVec::new(endian)).into_vec();
            let relocs = std::mem::take(&mut s.relocs);
            // Mach-O: references between DWARF sections are plain offsets (no relocations)
            if macho {
                for r in &relocs {
                    if let RelocationTarget::Section(_) = r.target {
                        let v = (r.addend as u64).to_le_bytes();
                        data[r.offset..r.offset + r.size as usize].copy_from_slice(&v[..r.size as usize]);
                    }
                }
            }
            let segment = obj.segment_name(StandardSegment::Debug).to_vec();
            let name = if macho { id.name().replace('.', "__") } else { id.name().to_string() };
            let sid = obj.add_section(segment, name.into_bytes(), SectionKind::Debug);
            obj.section_mut(sid).set_data(data, 1);
            ids.insert(id, sid);
            written.push((id, sid, relocs));
            Ok(())
        })
        .map_err(|e| format!("writing DWARF: {e}"))?;
    for (_, sid, relocs) in written {
        for r in relocs {
            let (symbol, addend) = match r.target {
                // against the function's section at its offset: Mach-O turns a relocation
                // against a local symbol into a section-relative one without the offset
                RelocationTarget::Symbol(i) => {
                    let sym = product.object.symbol(product.function_symbol(fns[i].func));
                    let (section, value) = (sym.section, sym.value);
                    let object::write::SymbolSection::Section(sec) = section else { return Err(format!("DWARF: {} is not defined", fns[i].name)) };
                    let base = product.object.section(sec).name().and_then(|n| code_base.get(n.as_bytes())).copied().unwrap_or(0);
                    (product.object.section_symbol(sec), r.addend + (base + value) as i64)
                }
                RelocationTarget::Section(_) if macho => continue,
                RelocationTarget::Section(s) => {
                    let Some(&target) = ids.get(&s) else { continue };
                    (product.object.section_symbol(target), r.addend)
                }
            };
            let flags = RelocationFlags::Generic { kind: RelocationKind::Absolute, encoding: RelocationEncoding::Generic, size: r.size * 8 };
            product.object.add_relocation(sid, ObjReloc { offset: r.offset as u64, symbol, addend, flags }).map_err(|e| format!("DWARF relocation: {e}"))?;
        }
    }
    Ok(())
}
