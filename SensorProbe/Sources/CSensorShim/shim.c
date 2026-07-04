// Intentionally empty. CSensorShim is a header-only interop target — the
// declarations in include/CSensorShim.h are resolved at link/runtime (AppleSMC
// via IOKit; the private IOReport/IOHID symbols via -undefined dynamic_lookup).
// SwiftPM requires at least one compilation unit for a C target.
#include "CSensorShim.h"
