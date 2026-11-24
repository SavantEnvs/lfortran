# lfortran-wat known findings

Each `.f90` here is a valid upstream test program (from `integration_tests/`) that crashes the WASM
backend (`lfortran --show-wat`, `FortranEvaluator::get_wat`) with an ASan SEGV on a near-NULL address:

    SEGV src/libasr/asr_base_visitor.h:131 in ASR::visit_expr_t<ASRToWASMVisitor>

Cause: `ASRToWASMVisitor` visits an `expr_t*` child that is NULL (an optional ASR field, e.g. a
missing dimension bound / dim argument / associate target expression it does not support) without
checking it, so `visit_expr` reads the node's `type` field through a NULL pointer.
Impact: denial of service (crash) on valid Fortran input to `--show-wat`.
Fix: in `src/libasr/codegen/asr_to_wasm.cpp`, check the optional `expr_t*` for NULL (and report
"not supported" through the diagnostics) before calling `visit_expr` on it.

They were moved out of `testsuite/` because seeds are replayed on every run.
Reproduce: `mayhem/build-fuzz/fuzz/lfortran-wat-standalone <file>`.
