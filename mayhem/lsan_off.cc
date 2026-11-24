// Disable LeakSanitizer for the fuzz binaries (ASan and UBSan stay active).
extern "C" int __lsan_is_turned_off() { return 1; }
