package oreo

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The default configuration file lives under the user's home directory.
DEFAULT_CONFIG_RELATIVE_PATH :: ".oreo/config.json"

// Built-in defaults, used when the configuration file is absent or omits a
// field.
DEFAULT_PROVIDER :: "opencode-go"
DEFAULT_MODEL :: "deepseek-v4.1-flash"
DEFAULT_THINKING :: "low"

@(private)
CONFIG_PATH_ENV :: "OREO_CONFIG"

@(private)
HOME_ENV :: "HOME"

// Provider and model values are one token with no whitespace or quotes, so
// they can be passed on to a provider request unchanged.
@(private)
MAX_PROVIDER_MODEL_LENGTH :: 80

@(private)
CONFIG_FIELD_NAMES :: [3]string{"provider", "model", "thinking"}

// Config_Error_Kind is the configuration failure surface. A missing config file
// is not a failure, so Not_Found is reserved and not currently returned.
Config_Error_Kind :: enum {
	None,
	Invalid_Argument,
	Not_Found,
	Malformed,
	Out_Of_Memory,
	Io,
}

// Config_Error owns its message text. Call config_error_destroy on every value,
// including a zero value, when it is no longer needed.
Config_Error :: struct {
	kind: Config_Error_Kind,
	message: string,
}

// Oreo_Config is the default provider, model, and thinking level for a session.
// The caller owns the three strings; call config_destroy to release them.
Oreo_Config :: struct {
	provider: string,
	model: string,
	thinking: string,
}

// default_config_path resolves the configuration file path: a non-empty
// OREO_CONFIG overrides the path under the user's home directory. The caller
// owns the returned string.
default_config_path :: proc(allocator := context.allocator) -> (string, Config_Error) {
	if override := os.get_env(CONFIG_PATH_ENV, allocator); len(override) > 0 {
		return override, Config_Error{}
	}
	home := os.get_env(HOME_ENV, allocator)
	defer delete(home, allocator)
	if len(home) == 0 {
		return "", config_error(.Invalid_Argument, "HOME is not set, so the default config path is unknown", allocator)
	}
	path, join_err := filepath.join({home, DEFAULT_CONFIG_RELATIVE_PATH}, allocator)
	if join_err != nil {
		return "", config_error(.Out_Of_Memory, "could not allocate the default config path", allocator)
	}
	return path, Config_Error{}
}

// config_load reads a configuration file. An empty path means the resolved
// default path. A missing file yields the built-in defaults with no error.
config_load :: proc(path: string, allocator := context.allocator) -> (Oreo_Config, Config_Error) {
	resolved := path
	owns_path := len(path) == 0
	if owns_path {
		default_path, path_err := default_config_path(allocator)
		if path_err.kind != .None {
			return {}, path_err
		}
		resolved = default_path
	}
	defer {
		if owns_path {
			delete(resolved, allocator)
		}
	}

	config, defaults_err := built_in_config(allocator)
	if defaults_err.kind != .None {
		return {}, defaults_err
	}
	if !os.exists(resolved) {
		return config, Config_Error{}
	}
	data, read_err := os.read_entire_file(resolved, allocator)
	if read_err != nil {
		config_destroy(&config)
		return {}, config_errorf(.Io, allocator, "could not read config file %s", resolved)
	}
	defer delete(data, allocator)

	value, parse_err := json.parse_string(string(data), spec = .JSON, allocator = allocator)
	if parse_err != .None {
		config_destroy(&config)
		return {}, config_errorf(.Malformed, allocator, "config file %s is not valid JSON", resolved)
	}
	defer json.destroy_value(value, allocator)

	object, is_object := value.(json.Object)
	if !is_object {
		config_destroy(&config)
		return {}, config_errorf(.Malformed, allocator, "config file %s must be a JSON object", resolved)
	}
	if override_err := apply_config_overrides(&config, object, allocator); override_err.kind != .None {
		config_destroy(&config)
		return {}, override_err
	}
	if !valid_provider_model(config.provider) || !valid_provider_model(config.model) {
		config_destroy(&config)
		return {}, config_error(
			.Invalid_Argument,
			"config provider and model must be 1-80 characters of letters, digits, /, ., -, _, or :",
			allocator,
		)
	}
	if !valid_thinking(config.thinking) {
		config_destroy(&config)
		return {}, config_error(
			.Invalid_Argument,
			"config thinking must be off, minimal, low, medium, high, xhigh, or max",
			allocator,
		)
	}
	return config, Config_Error{}
}

config_destroy :: proc(config: ^Oreo_Config, allocator := context.allocator) {
	delete(config.provider, allocator)
	delete(config.model, allocator)
	delete(config.thinking, allocator)
	config^ = Oreo_Config{}
}

config_error_destroy :: proc(err: ^Config_Error, allocator := context.allocator) {
	delete(err.message, allocator)
	err^ = Config_Error{}
}

@(private)
built_in_config :: proc(allocator: runtime.Allocator) -> (Oreo_Config, Config_Error) {
	config: Oreo_Config
	destinations := [3]^string{&config.provider, &config.model, &config.thinking}
	defaults := [3]string{DEFAULT_PROVIDER, DEFAULT_MODEL, DEFAULT_THINKING}
	for value, index in defaults {
		cloned, clone_err := strings.clone(value, allocator)
		if clone_err != nil {
			config_destroy(&config, allocator)
			return {}, config_error(.Out_Of_Memory, "could not allocate the built-in config", allocator)
		}
		destinations[index]^ = cloned
	}
	return config, Config_Error{}
}

// apply_config_overrides takes ownership of the recognized fields it replaces.
// A present field that is not a non-empty string is Malformed; unknown keys are
// ignored.
@(private)
apply_config_overrides :: proc(config: ^Oreo_Config, object: json.Object, allocator: runtime.Allocator) -> Config_Error {
	destinations := [3]^string{&config.provider, &config.model, &config.thinking}
	for name, index in CONFIG_FIELD_NAMES {
		field, present := object[name]
		if !present {
			continue
		}
		text, is_string := field.(json.String)
		if !is_string || len(string(text)) == 0 {
			return config_errorf(.Malformed, allocator, "%q must be a non-empty string", name)
		}
		replaced, clone_err := strings.clone(string(text), allocator)
		if clone_err != nil {
			return config_error(.Out_Of_Memory, "could not allocate a config value", allocator)
		}
		delete(destinations[index]^, allocator)
		destinations[index]^ = replaced
	}
	return Config_Error{}
}

@(private)
valid_provider_model :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) > MAX_PROVIDER_MODEL_LENGTH {
		return false
	}
	for character in value {
		switch {
		case 'a' <= character && character <= 'z':
		case 'A' <= character && character <= 'Z':
		case '0' <= character && character <= '9':
		case character == '/', character == '.', character == '-', character == '_', character == ':':
		case:
			return false
		}
	}
	return true
}

@(private)
valid_thinking :: proc(value: string) -> bool {
	switch value {
	case "off", "minimal", "low", "medium", "high", "xhigh", "max":
		return true
	}
	return false
}

@(private)
config_error :: proc(kind: Config_Error_Kind, message: string, allocator: runtime.Allocator) -> Config_Error {
	owned, _ := strings.clone(message, allocator)
	return Config_Error{kind = kind, message = owned}
}

@(private)
config_errorf :: proc(kind: Config_Error_Kind, allocator: runtime.Allocator, format: string, args: ..any) -> Config_Error {
	return Config_Error{kind = kind, message = fmt.aprintf(format, ..args, allocator = allocator)}
}
