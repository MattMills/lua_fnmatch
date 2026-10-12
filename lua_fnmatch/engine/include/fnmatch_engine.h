/* fnmatch_engine.h : C interface of the lua_fnmatch engine (Rust, over stellar-fnmatch).
 *
 * An image is an executable analysed the way stellar-fnmatch evaluates builds: its functions
 * (from .pdata, call targets, EH metadata) and every signature of every function, of every kind,
 * indexed so that any signature can be looked up. A sig file is a .sig file written by
 * `stellar-fnmatch sigs`: the signatures that are unique inside one reference build.
 *
 * Conventions:
 * - Functions that can fail return NULL / 0 / -1 and write a message into `err` (if not NULL).
 * - Strings are copied into caller buffers like snprintf: the return value is the full length,
 *   at most `size - 1` bytes are written, followed by a NUL when `size > 0`.
 * - Lists are copied into caller arrays: the return value is the full count, at most `max`
 *   elements are written.
 * - Functions are numbered from 0 in address order. Addresses are RVAs.
 * - Text arguments are UTF-8. Names are PDB procedure names; they are normalized like
 *   stellar-fnmatch does (lambda and anonymous-namespace hashes removed).
 * - Objects are not thread-safe: use one from one thread at a time.
 */

#ifndef FNMATCH_ENGINE_H
#define FNMATCH_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fnme_image fnme_image;
typedef struct fnme_sigfile fnme_sigfile;

typedef struct fnme_options
{
    const char *pdb;       /* PDB of the executable, for function names (NULL: none) */
    const char *cache_dir; /* keeps the extract of each executable, by md5 (NULL: no cache) */
    uint32_t threads;      /* worker threads for the analysis (0: one per core) */
} fnme_options;

typedef struct fnme_function
{
    uint32_t rva;
    uint32_t end_rva;      /* end of the primary code range */
    uint32_t size;         /* bytes of decoded instructions */
    uint32_t instructions;
    uint32_t funclet_of;   /* C++ EH funclets: index of the owning function, else UINT32_MAX */
    uint32_t names;        /* number of names */
    uint16_t flags;        /* stellar-fnmatch `model::ff` flags (0 in sig files) */
    uint8_t funclet_kind;  /* 1 unwind, 2 catch, 0 not a funclet */
} fnme_function;

/* the stellar-fnmatch version, NUL-terminated, static */
const char *fnme_version(void);

/* ---- images ---- */

/* Analyses the executable at `path` (x64 PE). */
fnme_image *fnme_image_open(const char *path, const fnme_options *options, char *err, size_t err_size);
/* Analyses an executable given as file contents. `name` is used in messages. */
fnme_image *fnme_image_from_memory(
    const uint8_t *data, size_t size, const char *name, const fnme_options *options, char *err, size_t err_size);
void fnme_image_free(fnme_image *image);

/* image base from the PE header */
uint64_t fnme_image_preferred_base(const fnme_image *image);
uint32_t fnme_image_count(const fnme_image *image);
int fnme_image_has_pdb(const fnme_image *image);
size_t fnme_image_md5(const fnme_image *image, char *buf, size_t size);
size_t fnme_image_path(const fnme_image *image, char *buf, size_t size);
/* number of signatures (function, signature pairs) in the index, without symbol relations */
size_t fnme_image_signature_count(const fnme_image *image);

int fnme_image_function(const fnme_image *image, uint32_t index, fnme_function *out);
/* the function whose code ranges contain `rva`, or -1 */
int64_t fnme_image_function_containing(const fnme_image *image, uint32_t rva);
/* name `k` of a function: its PDB names, then the name given with fnme_image_set_name */
size_t fnme_image_function_name(const fnme_image *image, uint32_t index, uint32_t k, char *buf, size_t size);
/* functions with this name */
size_t fnme_image_find_name(const fnme_image *image, const char *name, uint32_t *out, size_t max);

/* Functions that carry every signature of `sigs` (`count` >= 1), in address order. */
size_t fnme_image_find(fnme_image *image, const uint64_t *sigs, size_t count, uint32_t *out, size_t max);
/* Signatures of a function, sorted: only those that no other function has (`all` = 0) or all of
 * them. */
size_t fnme_image_signatures(fnme_image *image, uint32_t index, int all, uint64_t *out, size_t max);
/* Gives a function a name (NULL removes it), used by symbol-relation signatures (kinds s_*) of
 * the functions around it. Returns 0 on error. */
int fnme_image_set_name(fnme_image *image, uint32_t index, const char *name, char *err, size_t err_size);

/* ---- sig files ---- */

fnme_sigfile *fnme_sigfile_open(const char *path, char *err, size_t err_size);
void fnme_sigfile_free(fnme_sigfile *sigfile);

/* build metadata: 0 id, 1 platform, 2 version, 3 build string, 4 exe md5 */
size_t fnme_sigfile_meta(const fnme_sigfile *sigfile, int field, char *buf, size_t size);
uint32_t fnme_sigfile_count(const fnme_sigfile *sigfile);
size_t fnme_sigfile_signature_count(const fnme_sigfile *sigfile);
int fnme_sigfile_function(const fnme_sigfile *sigfile, uint32_t index, fnme_function *out);
/* the function whose primary range contains `rva`, or -1 */
int64_t fnme_sigfile_function_containing(const fnme_sigfile *sigfile, uint32_t rva);
size_t fnme_sigfile_function_name(const fnme_sigfile *sigfile, uint32_t index, uint32_t k, char *buf, size_t size);
size_t fnme_sigfile_find_name(const fnme_sigfile *sigfile, const char *name, uint32_t *out, size_t max);
/* the signatures of a function (all unique in that build), sorted */
size_t fnme_sigfile_signatures(const fnme_sigfile *sigfile, uint32_t index, uint64_t *out, size_t max);
/* the function carrying a signature, or -1 */
int64_t fnme_sigfile_find(const fnme_sigfile *sigfile, uint64_t sig);

/* ---- signatures ---- */

/* `kind:hash` (15 hex digits) or 16 hex digits of the whole value. Returns 0 on error. */
int fnme_sig_parse(const char *text, uint64_t *out, char *err, size_t err_size);
size_t fnme_sig_format(uint64_t sig, char *buf, size_t size);
uint32_t fnme_sig_kind(uint64_t sig);
/* name of a kind, 0 if `kind` is not one */
size_t fnme_sig_kind_name(uint32_t kind, char *buf, size_t size);

/* Signatures written from facts (see stellar-fnmatch `sigs::facts`). Text is UTF-8; they return
 * 0 on error. */
int fnme_sig_string(const char *text, size_t len, uint64_t *out, char *err, size_t err_size);
int fnme_sig_indirect_string(const char *text, size_t len, uint64_t *out, char *err, size_t err_size);
int fnme_sig_export(const char *name, size_t len, uint64_t *out, char *err, size_t err_size);
int fnme_sig_thunk_to(const char *name, size_t len, uint64_t *out, char *err, size_t err_size);
uint64_t fnme_sig_immediate(uint64_t value);
int fnme_sig_constant(const uint8_t *bytes, size_t len, uint64_t *out, char *err, size_t err_size);

/* ---- instructions ---- */

/* flow control of an instruction (iced-x86 FlowControl) */
#define FNME_FLOW_NEXT 0
#define FNME_FLOW_BRANCH 1
#define FNME_FLOW_INDIRECT_BRANCH 2
#define FNME_FLOW_CONDITIONAL_BRANCH 3
#define FNME_FLOW_RETURN 4
#define FNME_FLOW_CALL 5
#define FNME_FLOW_INDIRECT_CALL 6
#define FNME_FLOW_INTERRUPT 7
#define FNME_FLOW_XBEGIN 8    /* xbegin, xabort, xend */
#define FNME_FLOW_EXCEPTION 9 /* ud2 and the like */

typedef struct fnme_instruction
{
    uint64_t target;      /* near branch or call target, or the address a RIP-relative operand
                             refers to; 0 otherwise */
    uint32_t length;
    uint8_t flow;         /* FNME_FLOW_* */
    uint8_t rip_relative; /* 1 when a memory operand is relative to RIP */
} fnme_instruction;

/* Decodes the x64 instruction at the start of `code` (`size` bytes), at address `ip`. Returns its
 * length, 0 if the bytes do not start with a whole valid instruction. `out` and `text` (Intel
 * syntax, copied like snprintf) may be NULL. */
uint32_t fnme_decode(const uint8_t *code, size_t size, uint64_t ip, fnme_instruction *out, char *text, size_t text_size);

#ifdef __cplusplus
}
#endif

#endif
