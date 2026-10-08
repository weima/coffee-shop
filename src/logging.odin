package main

import "core:log"
import "core:os"
import "core:strings"

// Logging for development. Messages below the level chosen by CS_LOG_LEVEL are
// dropped, so debug messages can stay in the code at no cost. Levels, lowest first:
// debug, info, warning, error. The default is info, which hides debug messages.
//
// CS_LOG_FILE, when set, appends messages to that file instead of stderr. A server
// started in the background sends its stderr to /dev/null, so use the file to
// see what a server did.
setup_logging :: proc() -> log.Logger {
	level := log.Level.Info
	switch strings.to_lower(os.get_env("CS_LOG_LEVEL", context.temp_allocator), context.temp_allocator) {
	case "debug":
		level = .Debug
	case "info", "":
		level = .Info
	case "warning":
		level = .Warning
	case "error":
		level = .Error
	}
	path := os.get_env("CS_LOG_FILE", context.temp_allocator)
	if path != "" {
		handle, err := os.open(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, os.Permissions{.Read_User, .Write_User})
		if err == nil {
			return log.create_file_logger(handle, level)
		}
	}
	return log.create_console_logger(level)
}
