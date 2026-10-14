//! lua_fnmatch engine: the C interface of `include/fnmatch_engine.h`, over stellar-fnmatch.
//!
//! An image is an executable analysed exactly as `stellar-fnmatch extract` + `sigs` do, except
//! that no signature is dropped for being shared: every (signature, function) pair of every kind
//! is indexed, so a lookup tells how many functions carry a signature. Symbol relations (kinds
//! `s_*`) identify a neighbour by its name; they are computed from the image's PDB names and the
//! names given to its functions, and recomputed when those change.
//!
//! Panics never cross the C interface: they are caught and reported as errors.

use fnmatch::corpusdb::{compact, CBuild, NameNorm};
use fnmatch::model::{Build, BuildMeta};
use fnmatch::sigs::{self, kind, SigFile};
use md5::{Digest, Md5};
use rayon::prelude::*;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};

//////////////////////////////////////////////////
// images

pub struct Image {
    path: String,
    md5: String,
    image_base: u64,
    has_pdb: bool,
    c: CBuild,
    norm: NameNorm,
    /// normalized PDB names per function, sorted
    pdb_names: Vec<Vec<String>>,
    /// names given with `set_name`
    given: Vec<Option<String>>,
    /// (signature, function) of every kind except symbol relations, sorted, deduplicated
    free: Vec<(u64, u32)>,
    /// symbol relations from the current names, sorted; rebuilt when a name changes
    symbol: Vec<(u64, u32)>,
    symbol_dirty: bool,
    /// per-function views of `free` and `symbol`, built when signatures() first needs them
    free_rows: Option<ByFunction>,
    symbol_rows: Option<ByFunction>,
}

pub struct Options {
    pub pdb: Option<PathBuf>,
    pub cache_dir: Option<PathBuf>,
    pub threads: usize,
}

fn md5_hex(bytes: &[u8]) -> String {
    Md5::digest(bytes).iter().map(|b| format!("{:02x}", b)).collect()
}

fn is_symbol(s: u64) -> bool {
    (kind::SYMBOL..kind::SYMBOL + 12).contains(&sigs::sig_kind(s))
}

/// The pairs of a sorted index that carry signature `s`.
fn range(v: &[(u64, u32)], s: u64) -> &[(u64, u32)] {
    let lo = v.partition_point(|x| x.0 < s);
    let hi = lo + v[lo..].partition_point(|x| x.0 == s);
    &v[lo..hi]
}

/// Positions of the pairs of each function in an index sorted by signature (compressed rows), so
/// that a function's signatures are found without scanning the index.
struct ByFunction {
    off: Vec<u32>,
    pos: Vec<u32>,
}

impl ByFunction {
    fn new(funcs: impl Iterator<Item = u32> + Clone, n: usize) -> ByFunction {
        let mut off = vec![0u32; n + 1];
        for f in funcs.clone() {
            off[f as usize + 1] += 1;
        }
        for i in 0..n {
            off[i + 1] += off[i];
        }
        let mut next = off.clone();
        let mut pos = vec![0u32; off[n] as usize];
        for (k, f) in funcs.enumerate() {
            pos[next[f as usize] as usize] = k as u32;
            next[f as usize] += 1;
        }
        ByFunction { off, pos }
    }

    /// positions of function `f`, in index order (ascending signatures)
    fn row(&self, f: u32) -> &[u32] {
        &self.pos[self.off[f as usize] as usize..self.off[f as usize + 1] as usize]
    }
}

impl Image {
    /// Analyses the contents of an executable. `path` names it in messages (and in the cache).
    pub fn analyse(bytes: &[u8], path: &str, o: &Options) -> Result<Image, String> {
        let md5 = md5_hex(bytes);
        let pool = rayon::ThreadPoolBuilder::new().num_threads(o.threads).build().map_err(|e| e.to_string())?;
        pool.install(|| {
            let cache = o.cache_dir.as_ref().map(|d| d.join(format!("{}{}.fnx", md5, if o.pdb.is_some() { "-pdb" } else { "" })));
            let cached = cache
                .as_ref()
                .filter(|p| p.is_file())
                .and_then(|p| Build::load(p).ok())
                .filter(|b| b.meta.exe_md5 == md5 && b.has_pdb() == o.pdb.is_some());
            let build = match cached {
                Some(b) => b,
                None => {
                    let meta = BuildMeta {
                        id: Path::new(path).file_name().map_or_else(|| path.to_string(), |n| n.to_string_lossy().into_owned()),
                        version: "?".into(),
                        exe_path: path.to_string(),
                        pdb_path: o.pdb.as_ref().map(|p| p.to_string_lossy().into_owned()),
                        exe_md5: md5.clone(),
                        exe_size: bytes.len() as u64,
                        ..Default::default()
                    };
                    let b = fnmatch::extract::extract(bytes, o.pdb.as_deref(), meta).map_err(|e| format!("{}: {:#}", path, e))?;
                    if let Some(p) = &cache {
                        if !o.pdb.is_some() || b.has_pdb() {
                            // a cache that cannot be written only costs time
                            let _ = p.parent().map(std::fs::create_dir_all);
                            let _ = b.save(p);
                        }
                    }
                    b
                }
            };
            if let Some(pdb) = &o.pdb {
                if !build.has_pdb() {
                    let why = build.stats.pdb_error.clone().unwrap_or_else(|| "no procedures in the PDB".into());
                    return Err(format!("{}: {}", pdb.display(), why));
                }
            }
            let image_base = build.image_base;
            let has_pdb = build.has_pdb();
            let norm = NameNorm::new();
            let (c, names) = compact(build, 0, &norm);
            let pdb_names: Vec<Vec<String>> = if has_pdb {
                names
                    .into_iter()
                    .map(|mut v| {
                        v.sort();
                        v.dedup();
                        v
                    })
                    .collect()
            } else {
                vec![Vec::new(); c.n]
            };
            let mut free = sigs::free_signatures(&c);
            free.par_sort_unstable();
            free.dedup();
            let n = c.n;
            Ok(Image {
                path: path.to_string(),
                md5,
                image_base,
                has_pdb,
                c,
                norm,
                pdb_names,
                given: vec![None; n],
                free,
                symbol: Vec::new(),
                symbol_dirty: true,
                free_rows: None,
                symbol_rows: None,
            })
        })
    }

    pub fn count(&self) -> usize {
        self.c.n
    }

    /// The names of a function: its PDB names, then the given name.
    pub fn names(&self, f: usize) -> Vec<&str> {
        let mut v: Vec<&str> = self.pdb_names[f].iter().map(|s| s.as_str()).collect();
        if let Some(g) = &self.given[f] {
            if !v.contains(&g.as_str()) {
                v.push(g);
            }
        }
        v
    }

    fn normalize(&self, name: &str) -> Result<String, String> {
        self.norm.norm(name.trim()).ok_or_else(|| format!("'{}' is not a function name", name))
    }

    pub fn set_name(&mut self, f: usize, name: Option<&str>) -> Result<(), String> {
        let name = name.map(|n| self.normalize(n)).transpose()?;
        if self.given[f] != name {
            self.given[f] = name;
            self.symbol_dirty = true;
        }
        Ok(())
    }

    pub fn find_name(&self, name: &str) -> Vec<u32> {
        let Ok(name) = self.normalize(name) else { return Vec::new() };
        (0..self.c.n).filter(|&f| self.pdb_names[f].binary_search(&name).is_ok() || self.given[f].as_deref() == Some(name.as_str())).map(|f| f as u32).collect()
    }

    fn symbol_index(&mut self) -> &[(u64, u32)] {
        if self.symbol_dirty {
            // the neighbour's id is the hash of its smallest name, as in .sig files
            let ids: Vec<u64> = (0..self.c.n)
                .map(|f| self.pdb_names[f].iter().map(|s| s.as_str()).chain(self.given[f].as_deref()).min().map_or(0, sigs::name_hash))
                .collect();
            let mut v = Vec::new();
            if ids.iter().any(|&x| x != 0) {
                sigs::relations(&self.c, &ids, kind::SYMBOL, sigs::REACH, &mut v);
            }
            v.sort_unstable();
            v.dedup();
            self.symbol = v;
            self.symbol_dirty = false;
            self.symbol_rows = None;
        }
        &self.symbol
    }

    /// Functions carrying every signature of `sigs`, in address order.
    pub fn find(&mut self, sigs: &[u64]) -> Vec<u32> {
        let mut acc: Option<Vec<u32>> = None;
        for &s in sigs {
            let index: &[(u64, u32)] = if is_symbol(s) { self.symbol_index() } else { &self.free };
            // sorted by (signature, function): the functions of one signature are ascending
            let fs: Vec<u32> = range(index, s).iter().map(|x| x.1).collect();
            let next = match acc {
                None => fs,
                Some(a) => a.into_iter().filter(|f| fs.binary_search(f).is_ok()).collect(),
            };
            let empty = next.is_empty();
            acc = Some(next);
            if empty {
                break;
            }
        }
        acc.unwrap_or_default()
    }

    /// Signatures of a function, sorted: those no other function has, or all.
    pub fn signatures(&mut self, f: u32, all: bool) -> Vec<u64> {
        self.symbol_index();
        let n = self.c.n;
        if self.free_rows.is_none() {
            self.free_rows = Some(ByFunction::new(self.free.iter().map(|x| x.1), n));
        }
        if self.symbol_rows.is_none() {
            self.symbol_rows = Some(ByFunction::new(self.symbol.iter().map(|x| x.1), n));
        }
        let mut out = Vec::new();
        for (index, rows) in [(&self.free, &self.free_rows), (&self.symbol, &self.symbol_rows)] {
            for &k in rows.as_ref().unwrap().row(f) {
                let (k, s) = (k as usize, index[k as usize].0);
                let unique = (k == 0 || index[k - 1].0 != s) && (k + 1 == index.len() || index[k + 1].0 != s);
                if all || unique {
                    out.push(s);
                }
            }
        }
        out.sort_unstable();
        out.dedup();
        out
    }

    pub fn function(&self, f: usize) -> Function {
        let c = &self.c;
        Function {
            rva: c.rva[f],
            end_rva: c.ranges.row(f).first().map_or(c.rva[f], |r| r.1),
            size: c.size[f],
            instructions: c.n_insn[f],
            funclet_of: c.eh_parent[f],
            names: self.names(f).len() as u32,
            flags: c.flags[f],
            funclet_kind: c.eh_kind[f],
        }
    }
}

//////////////////////////////////////////////////
// sig files

pub struct SigSet {
    sf: SigFile,
    norm: NameNorm,
    by_name: HashMap<String, Vec<u32>>,
    rows: std::sync::OnceLock<ByFunction>,
}

impl SigSet {
    pub fn open(path: &Path) -> Result<SigSet, String> {
        let sf = SigFile::load(path).map_err(|e| format!("{:#}", e))?;
        if sf.funcs.len() != sf.sigs.len() || [sf.end.len(), sf.size.len(), sf.n_insn.len(), sf.eh_parent.len(), sf.eh_kind.len()].iter().any(|&l| l != sf.rva.len()) {
            return Err(format!("{}: corrupt sig file", path.display()));
        }
        if sf.funcs.iter().any(|&f| f as usize >= sf.rva.len()) || (!sf.names.is_empty() && sf.names.len() != sf.rva.len()) {
            return Err(format!("{}: corrupt sig file", path.display()));
        }
        let mut by_name: HashMap<String, Vec<u32>> = HashMap::new();
        for (f, ns) in sf.names.iter().enumerate() {
            for n in ns {
                by_name.entry(n.clone()).or_default().push(f as u32);
            }
        }
        Ok(SigSet { sf, norm: NameNorm::new(), by_name, rows: std::sync::OnceLock::new() })
    }

    pub fn count(&self) -> usize {
        self.sf.rva.len()
    }

    pub fn names(&self, f: usize) -> &[String] {
        self.sf.names.get(f).map_or(&[], |v| v.as_slice())
    }

    pub fn find_name(&self, name: &str) -> Vec<u32> {
        self.norm.norm(name.trim()).and_then(|n| self.by_name.get(&n).cloned()).unwrap_or_default()
    }

    pub fn signatures(&self, f: u32) -> Vec<u64> {
        if f as usize >= self.count() {
            return Vec::new();
        }
        let rows = self.rows.get_or_init(|| ByFunction::new(self.sf.funcs.iter().copied(), self.count()));
        rows.row(f).iter().map(|&k| self.sf.sigs[k as usize]).collect()
    }

    pub fn find(&self, sig: u64) -> Option<u32> {
        self.sf.sigs.binary_search(&sig).ok().map(|k| self.sf.funcs[k])
    }

    pub fn function_containing(&self, rva: u32) -> Option<u32> {
        let i = self.sf.rva.partition_point(|&r| r <= rva);
        (i > 0 && rva < self.sf.end[i - 1]).then(|| (i - 1) as u32)
    }

    pub fn function(&self, f: usize) -> Function {
        let s = &self.sf;
        Function {
            rva: s.rva[f],
            end_rva: s.end[f],
            size: s.size[f],
            instructions: s.n_insn[f],
            funclet_of: s.eh_parent[f],
            names: self.names(f).len() as u32,
            flags: 0,
            funclet_kind: s.eh_kind[f],
        }
    }
}

//////////////////////////////////////////////////
// C interface

#[repr(C)]
pub struct FnmeOptions {
    pub pdb: *const c_char,
    pub cache_dir: *const c_char,
    pub threads: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct Function {
    pub rva: u32,
    pub end_rva: u32,
    pub size: u32,
    pub instructions: u32,
    pub funclet_of: u32,
    pub names: u32,
    pub flags: u16,
    pub funclet_kind: u8,
}

/// Copies `s` into a caller buffer (snprintf style); returns its full length.
fn put_str(s: &str, buf: *mut c_char, size: usize) -> usize {
    if !buf.is_null() && size > 0 {
        let n = s.len().min(size - 1);
        // SAFETY: the caller provides `size` writable bytes at `buf`
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), buf as *mut u8, n);
            *buf.add(n) = 0;
        }
    }
    s.len()
}

/// Copies a list into a caller array; returns its full length.
fn put_list<T: Copy>(v: &[T], out: *mut T, max: usize) -> usize {
    if !out.is_null() {
        let n = v.len().min(max);
        // SAFETY: the caller provides `max` writable elements at `out`
        unsafe { std::ptr::copy_nonoverlapping(v.as_ptr(), out, n) };
    }
    v.len()
}

/// Runs `body`, turning errors and panics into a message in `err` and the value `fail`.
fn guard<T>(err: *mut c_char, err_size: usize, fail: T, body: impl FnOnce() -> Result<T, String>) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => {
            put_str(&e, err, err_size);
            fail
        }
        Err(p) => {
            let what = p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned()).unwrap_or_default();
            put_str(&format!("internal error: {}", what), err, err_size);
            fail
        }
    }
}

/// Like `guard` for functions without an error message.
fn quiet<T>(fail: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fail)
}

/// SAFETY: `p` is null or a NUL-terminated string.
unsafe fn text<'a>(p: *const c_char, what: &str) -> Result<Option<&'a str>, String> {
    if p.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(p).to_str().map(Some).map_err(|_| format!("{} is not UTF-8", what))
}

/// SAFETY: `p` is null or points to `len` bytes.
unsafe fn bytes<'a>(p: *const c_char, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p as *const u8, len)
    }
}

/// SAFETY: `p` is null or a valid `FnmeOptions` with valid strings.
unsafe fn options(p: *const FnmeOptions) -> Result<Options, String> {
    let mut o = Options { pdb: None, cache_dir: None, threads: 0 };
    if let Some(p) = p.as_ref() {
        o.pdb = text(p.pdb, "pdb path")?.map(PathBuf::from);
        o.cache_dir = text(p.cache_dir, "cache directory")?.map(PathBuf::from);
        o.threads = p.threads as usize;
    }
    Ok(o)
}

#[no_mangle]
pub extern "C" fn fnme_version() -> *const c_char {
    concat!(env!("STELLAR_FNMATCH_VERSION"), "\0").as_ptr() as *const c_char
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_open(path: *const c_char, opts: *const FnmeOptions, err: *mut c_char, err_size: usize) -> *mut Image {
    guard(err, err_size, std::ptr::null_mut(), || {
        let path = text(path, "path")?.ok_or("no path")?;
        let o = options(opts)?;
        let bytes = std::fs::read(path).map_err(|e| format!("{}: {}", path, e))?;
        Ok(Box::into_raw(Box::new(Image::analyse(&bytes, path, &o)?)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_from_memory(data: *const u8, size: usize, name: *const c_char, opts: *const FnmeOptions, err: *mut c_char, err_size: usize) -> *mut Image {
    guard(err, err_size, std::ptr::null_mut(), || {
        let name = text(name, "name")?.unwrap_or("(memory)");
        let o = options(opts)?;
        let data = bytes(data as *const c_char, size);
        Ok(Box::into_raw(Box::new(Image::analyse(data, name, &o)?)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_free(image: *mut Image) {
    if !image.is_null() {
        quiet((), || drop(Box::from_raw(image)));
    }
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_preferred_base(image: *const Image) -> u64 {
    image.as_ref().map_or(0, |i| i.image_base)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_count(image: *const Image) -> u32 {
    image.as_ref().map_or(0, |i| i.count() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_has_pdb(image: *const Image) -> c_int {
    image.as_ref().map_or(0, |i| i.has_pdb as c_int)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_md5(image: *const Image, buf: *mut c_char, size: usize) -> usize {
    image.as_ref().map_or(0, |i| put_str(&i.md5, buf, size))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_path(image: *const Image, buf: *mut c_char, size: usize) -> usize {
    image.as_ref().map_or(0, |i| put_str(&i.path, buf, size))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_signature_count(image: *const Image) -> usize {
    image.as_ref().map_or(0, |i| i.free.len())
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_function(image: *const Image, index: u32, out: *mut Function) -> c_int {
    let (Some(i), Some(out)) = (image.as_ref(), out.as_mut()) else { return 0 };
    if index as usize >= i.count() {
        return 0;
    }
    quiet(0, || {
        *out = i.function(index as usize);
        1
    })
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_function_containing(image: *const Image, rva: u32) -> i64 {
    image.as_ref().map_or(-1, |i| quiet(-1, || i.c.func_containing(rva).map_or(-1, |f| f as i64)))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_function_name(image: *const Image, index: u32, k: u32, buf: *mut c_char, size: usize) -> usize {
    let Some(i) = image.as_ref() else { return 0 };
    if index as usize >= i.count() {
        return 0;
    }
    quiet(0, || i.names(index as usize).get(k as usize).map_or(0, |n| put_str(n, buf, size)))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_find_name(image: *const Image, name: *const c_char, out: *mut u32, max: usize) -> usize {
    let Some(i) = image.as_ref() else { return 0 };
    let Ok(Some(name)) = text(name, "name") else { return 0 };
    quiet(0, || put_list(&i.find_name(name), out, max))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_find(image: *mut Image, sigs: *const u64, count: usize, out: *mut u32, max: usize) -> usize {
    let Some(i) = image.as_mut() else { return 0 };
    if sigs.is_null() || count == 0 {
        return 0;
    }
    let sigs = std::slice::from_raw_parts(sigs, count);
    quiet(0, || put_list(&i.find(sigs), out, max))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_signatures(image: *mut Image, index: u32, all: c_int, out: *mut u64, max: usize) -> usize {
    let Some(i) = image.as_mut() else { return 0 };
    if index as usize >= i.count() {
        return 0;
    }
    quiet(0, || put_list(&i.signatures(index, all != 0), out, max))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_image_set_name(image: *mut Image, index: u32, name: *const c_char, err: *mut c_char, err_size: usize) -> c_int {
    guard(err, err_size, 0, || {
        let i = image.as_mut().ok_or("no image")?;
        if index as usize >= i.count() {
            return Err(format!("no function {}", index));
        }
        i.set_name(index as usize, text(name, "name")?)?;
        Ok(1)
    })
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_open(path: *const c_char, err: *mut c_char, err_size: usize) -> *mut SigSet {
    guard(err, err_size, std::ptr::null_mut(), || {
        let path = text(path, "path")?.ok_or("no path")?;
        Ok(Box::into_raw(Box::new(SigSet::open(Path::new(path))?)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_free(sigfile: *mut SigSet) {
    if !sigfile.is_null() {
        quiet((), || drop(Box::from_raw(sigfile)));
    }
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_meta(sigfile: *const SigSet, field: c_int, buf: *mut c_char, size: usize) -> usize {
    let Some(s) = sigfile.as_ref() else { return 0 };
    let m = &s.sf.meta;
    let v = match field {
        0 => &m.id,
        1 => &m.platform,
        2 => &m.version,
        3 => &m.build_string,
        4 => &m.exe_md5,
        _ => return 0,
    };
    put_str(v, buf, size)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_count(sigfile: *const SigSet) -> u32 {
    sigfile.as_ref().map_or(0, |s| s.count() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_signature_count(sigfile: *const SigSet) -> usize {
    sigfile.as_ref().map_or(0, |s| s.sf.sigs.len())
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_function(sigfile: *const SigSet, index: u32, out: *mut Function) -> c_int {
    let (Some(s), Some(out)) = (sigfile.as_ref(), out.as_mut()) else { return 0 };
    if index as usize >= s.count() {
        return 0;
    }
    *out = s.function(index as usize);
    1
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_function_containing(sigfile: *const SigSet, rva: u32) -> i64 {
    sigfile.as_ref().and_then(|s| s.function_containing(rva)).map_or(-1, |f| f as i64)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_function_name(sigfile: *const SigSet, index: u32, k: u32, buf: *mut c_char, size: usize) -> usize {
    let Some(s) = sigfile.as_ref() else { return 0 };
    s.names(index as usize).get(k as usize).map_or(0, |n| put_str(n, buf, size))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_find_name(sigfile: *const SigSet, name: *const c_char, out: *mut u32, max: usize) -> usize {
    let Some(s) = sigfile.as_ref() else { return 0 };
    let Ok(Some(name)) = text(name, "name") else { return 0 };
    quiet(0, || put_list(&s.find_name(name), out, max))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_signatures(sigfile: *const SigSet, index: u32, out: *mut u64, max: usize) -> usize {
    let Some(s) = sigfile.as_ref() else { return 0 };
    put_list(&s.signatures(index), out, max)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sigfile_find(sigfile: *const SigSet, sig: u64) -> i64 {
    sigfile.as_ref().and_then(|s| s.find(sig)).map_or(-1, |f| f as i64)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_parse(text_: *const c_char, out: *mut u64, err: *mut c_char, err_size: usize) -> c_int {
    guard(err, err_size, 0, || {
        let t = text(text_, "signature")?.ok_or("no signature")?;
        let s = sigs::parse(t)?;
        if let Some(o) = out.as_mut() {
            *o = s;
        }
        Ok(1)
    })
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_format(sig: u64, buf: *mut c_char, size: usize) -> usize {
    put_str(&sigs::format(sig), buf, size)
}

#[no_mangle]
pub extern "C" fn fnme_sig_kind(sig: u64) -> u32 {
    sigs::sig_kind(sig) as u32
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_kind_name(k: u32, buf: *mut c_char, size: usize) -> usize {
    if k >= 64 {
        return 0;
    }
    let name = kind::name(k as u8);
    if kind::from_name(&name).is_none() {
        return 0;
    }
    put_str(&name, buf, size)
}

/// A fact signature from UTF-8 text.
unsafe fn fact(t: *const c_char, len: usize, out: *mut u64, err: *mut c_char, err_size: usize, what: &str, f: impl FnOnce(&str) -> Result<u64, String>) -> c_int {
    guard(err, err_size, 0, || {
        let s = std::str::from_utf8(bytes(t, len)).map_err(|_| format!("{} is not UTF-8", what))?;
        let v = f(s)?;
        if let Some(o) = out.as_mut() {
            *o = v;
        }
        Ok(1)
    })
}

fn function_name(s: &str) -> Result<String, String> {
    NameNorm::new().norm(s.trim()).ok_or_else(|| format!("'{}' is not a function name", s))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_string(t: *const c_char, len: usize, out: *mut u64, err: *mut c_char, err_size: usize) -> c_int {
    fact(t, len, out, err, err_size, "string", |s| Ok(sigs::facts::string(s)))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_indirect_string(t: *const c_char, len: usize, out: *mut u64, err: *mut c_char, err_size: usize) -> c_int {
    fact(t, len, out, err, err_size, "string", |s| Ok(sigs::facts::indirect_string(s)))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_export(t: *const c_char, len: usize, out: *mut u64, err: *mut c_char, err_size: usize) -> c_int {
    fact(t, len, out, err, err_size, "export name", |s| Ok(sigs::facts::export(s)))
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_thunk_to(t: *const c_char, len: usize, out: *mut u64, err: *mut c_char, err_size: usize) -> c_int {
    fact(t, len, out, err, err_size, "name", |s| Ok(sigs::facts::thunk_to(&function_name(s)?)))
}

#[no_mangle]
pub extern "C" fn fnme_sig_immediate(value: u64) -> u64 {
    sigs::facts::immediate(value)
}

#[no_mangle]
pub unsafe extern "C" fn fnme_sig_constant(b: *const u8, len: usize, out: *mut u64, err: *mut c_char, err_size: usize) -> c_int {
    guard(err, err_size, 0, || {
        let v = sigs::facts::constant(bytes(b as *const c_char, len)).ok_or("a constant is 1 to 32 bytes")?;
        if let Some(o) = out.as_mut() {
            *o = v;
        }
        Ok(1)
    })
}

// ---- instructions ----

/// One x64 instruction, from `fnme_decode`.
#[repr(C)]
pub struct FnmeInstruction {
    /// the target of a near branch or call, or the address a RIP-relative memory operand refers
    /// to; 0 otherwise
    pub target: u64,
    pub length: u32,
    /// FNME_FLOW_*: iced-x86's flow control
    pub flow: u8,
    /// 1 when a memory operand is relative to RIP
    pub rip_relative: u8,
}

/// Decodes the instruction at the start of `code` (`size` bytes) at address `ip`. Returns its
/// length, 0 if the bytes do not start with a whole valid instruction. `text` (if not null) gets
/// it in Intel syntax.
#[no_mangle]
pub unsafe extern "C" fn fnme_decode(code: *const u8, size: usize, ip: u64, out: *mut FnmeInstruction, text: *mut c_char, text_size: usize) -> u32 {
    use iced_x86::{Decoder, DecoderOptions, FlowControl, Formatter, IntelFormatter};
    quiet(0, || {
        let bytes = if code.is_null() || size == 0 { &[][..] } else { std::slice::from_raw_parts(code, size.min(15)) };
        let instruction = Decoder::with_ip(64, bytes, ip, DecoderOptions::NONE).decode();
        if instruction.is_invalid() {
            return 0;
        }
        let flow = match instruction.flow_control() {
            FlowControl::Next => 0,
            FlowControl::UnconditionalBranch => 1,
            FlowControl::IndirectBranch => 2,
            FlowControl::ConditionalBranch => 3,
            FlowControl::Return => 4,
            FlowControl::Call => 5,
            FlowControl::IndirectCall => 6,
            FlowControl::Interrupt => 7,
            FlowControl::XbeginXabortXend => 8,
            _ => 9,
        };
        let rip_relative = instruction.is_ip_rel_memory_operand();
        if let Some(o) = out.as_mut() {
            *o = FnmeInstruction {
                target: if rip_relative { instruction.ip_rel_memory_address() } else { instruction.near_branch_target() },
                length: instruction.len() as u32,
                flow,
                rip_relative: rip_relative as u8,
            };
        }
        if !text.is_null() {
            let mut s = String::new();
            IntelFormatter::new().format(&instruction, &mut s);
            put_str(&s, text, text_size);
        }
        instruction.len() as u32
    })
}
