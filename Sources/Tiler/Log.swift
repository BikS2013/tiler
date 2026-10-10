import os

/// Unified-log channel. Read with:
/// `log stream --predicate 'subsystem == "com.giorgosmarinos.tiler"' --level debug`
let log = Logger(subsystem: "com.giorgosmarinos.tiler", category: "tiler")
