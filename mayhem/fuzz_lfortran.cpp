// libFuzzer harness for LFortran, built once per target with -DLF_MODE=<n>.
//
// Each mode drives the same public entry point the `lfortran` CLI uses for the matching
// command line (src/bin/lfortran.cpp): a FortranEvaluator over the input as one source file,
// then the diagnostics are rendered, as the CLI prints them.
//
//   LF_MODE_C            lfortran --show-c                (emit_c: get_asr2 + default passes + get_c3)
//   LF_MODE_ASR_CC       lfortran --continue-compilation --show-asr
//   LF_MODE_CPP_BACKEND  lfortran --show-cpp              (get_cpp)
//   LF_MODE_FIXEDFORM    lfortran --fixed-form --implicit-typing --show-asr
//   LF_MODE_FMT          lfortran fmt                     (get_fmt)
//   LF_MODE_FORTRAN      lfortran --show-fortran          (get_fortran)
//   LF_MODE_PREPROC      lfortran --cpp --show-asr        (C preprocessor, then the frontend)
//   LF_MODE_WAT          lfortran --show-wat              (get_wat)
//   LF_MODE_GFORTRAN_MOD lfortran mod --show-asr          (GFortran .mod reader, mod_to_asr)
//
// LCompilersException is how LFortran reports an input it rejects outside the diagnostics
// system (e.g. a corrupt .mod); the CLI's main() catches it and exits 1, so the harness
// does the same. Everything else (ASan/UBSan reports, other exceptions, aborts) is a finding.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

#include <lfortran/fortran_evaluator.h>
#include <lfortran/mod_to_asr.h>
#include <libasr/asr.h>
#include <libasr/exception.h>
#include <libasr/pickle.h>
#include <libasr/pass/pass_manager.h>
#include <libasr/utils.h>

#define LF_MODE_C 1
#define LF_MODE_ASR_CC 2
#define LF_MODE_CPP_BACKEND 3
#define LF_MODE_FIXEDFORM 4
#define LF_MODE_FMT 5
#define LF_MODE_FORTRAN 6
#define LF_MODE_PREPROC 7
#define LF_MODE_WAT 8
#define LF_MODE_GFORTRAN_MOD 9

#ifndef LF_MODE
#error "build with -DLF_MODE=<n>"
#endif

using namespace LCompilers;

static volatile size_t sink;

#if LF_MODE == LF_MODE_GFORTRAN_MOD
// mod_to_asr() takes a file name (it gunzips the file itself), as `lfortran mod` does.
static void run_mod(const uint8_t *data, size_t size) {
    const char *tmp = getenv("TMPDIR");
    std::string path = std::string(tmp && *tmp ? tmp : "/tmp") + "/lfortran-fuzz-XXXXXX";
    int fd = mkstemp(&path[0]);
    if (fd < 0) return;
    size_t off = 0;
    while (off < size) {
        ssize_t w = write(fd, data + off, size - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
    close(fd);
    try {
        Allocator al(1024 * 1024);
        ASR::TranslationUnit_t *asr = LFortran::mod_to_asr(al, path);
        sink = pickle(*asr, false, false, false, false).size();
    } catch (const LCompilersException &) {
    }
    unlink(path.c_str());
}
#endif

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
#if LF_MODE == LF_MODE_GFORTRAN_MOD
    run_mod(data, size);
#else
    std::string input(reinterpret_cast<const char *>(data), size);
    CompilerOptions compiler_options;
    compiler_options.use_colors = false;
#if LF_MODE == LF_MODE_ASR_CC
    compiler_options.continue_compilation = true;
#elif LF_MODE == LF_MODE_FIXEDFORM
    compiler_options.fixed_form = true;
    compiler_options.implicit_typing = true;
#elif LF_MODE == LF_MODE_PREPROC
    compiler_options.c_preprocessor = true;
#endif
    const char *infile =
#if LF_MODE == LF_MODE_FIXEDFORM
        "input.f";
#else
        "input.f90";
#endif
    try {
        FortranEvaluator fe(compiler_options);
        LocationManager lm;
        diag::Diagnostics diagnostics;
        {
            LocationManager::FileLocations fl;
            fl.in_filename = infile;
            lm.files.push_back(fl);
            lm.file_ends.push_back(LFortran::source_offset(input.size()));
        }
        PassManager pass_manager;
        std::string out;
#if LF_MODE == LF_MODE_C
        pass_manager.use_default_passes();
        Result<ASR::TranslationUnit_t *> r = fe.get_asr2(input, lm, diagnostics);
        out += diagnostics.render(lm, compiler_options);
        if (r.ok) {
            diagnostics.diagnostics.clear();
            Result<std::string> c = fe.get_c3(*r.result, diagnostics, pass_manager, 1);
            out += diagnostics.render(lm, compiler_options);
            if (c.ok) out += c.result;
        }
#elif LF_MODE == LF_MODE_ASR_CC || LF_MODE == LF_MODE_FIXEDFORM || LF_MODE == LF_MODE_PREPROC
        Result<ASR::TranslationUnit_t *> r = fe.get_asr2(input, lm, diagnostics);
        out += diagnostics.render(lm, compiler_options);
        if (r.ok) out += pickle(*r.result, false, false, false, false);
#elif LF_MODE == LF_MODE_CPP_BACKEND
        Result<std::string> r = fe.get_cpp(input, lm, diagnostics, 1);
        out += diagnostics.render(lm, compiler_options);
        if (r.ok) out += r.result;
#elif LF_MODE == LF_MODE_FMT
        Result<std::string> r = fe.get_fmt(input, lm, diagnostics);
        out += diagnostics.render(lm, compiler_options);
        if (r.ok) out += r.result;
#elif LF_MODE == LF_MODE_FORTRAN
        Result<std::string> r = fe.get_fortran(input, lm, diagnostics, pass_manager);
        out += diagnostics.render(lm, compiler_options);
        if (r.ok) out += r.result;
#elif LF_MODE == LF_MODE_WAT
        Result<std::string> r = fe.get_wat(input, lm, diagnostics);
        out += diagnostics.render(lm, compiler_options);
        if (r.ok) out += r.result;
#else
#error "unknown LF_MODE"
#endif
        sink = out.size();
    } catch (const LCompilersException &) {
    }
#endif
    return 0;
}
