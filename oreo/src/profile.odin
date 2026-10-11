package oreo

import "core:strings"

// Resolved_Profile is the effective provider, model, and thinking level for a
// work item. The caller owns the three strings; call profile_resolved_destroy
// to release them.
Resolved_Profile :: struct {
	provider: string,
	model: string,
	thinking: string,
}

// profile_resolve loads the default configuration and fills each empty caller
// value from it. A non-empty caller value wins unchanged. Every resolved value
// passes the same validation the configuration applies. The returned error owns
// its message; call config_error_destroy on every value.
profile_resolve :: proc(provider, model, thinking: string, allocator := context.allocator) -> (Resolved_Profile, Config_Error) {
	config, config_err := config_load("", allocator)
	if config_err.kind != .None {
		// Ownership of the message moves to the caller.
		return {}, config_err
	}
	defer config_destroy(&config, allocator)

	profile: Resolved_Profile
	sources := [3]string{provider, model, thinking}
	fallbacks := [3]string{config.provider, config.model, config.thinking}
	destinations := [3]^string{&profile.provider, &profile.model, &profile.thinking}
	for source, index in sources {
		chosen := source
		if len(chosen) == 0 {
			chosen = fallbacks[index]
		}
		owned, clone_err := strings.clone(chosen, allocator)
		if clone_err != nil {
			profile_resolved_destroy(&profile, allocator)
			return {}, config_error(.Out_Of_Memory, "could not allocate the resolved profile", allocator)
		}
		destinations[index]^ = owned
	}

	if !valid_provider_model(profile.provider) || !valid_provider_model(profile.model) {
		profile_resolved_destroy(&profile, allocator)
		return {}, config_error(
			.Invalid_Argument,
			"resolved provider and model must be 1-80 characters of letters, digits, /, ., -, _, or :",
			allocator,
		)
	}
	if !valid_thinking(profile.thinking) {
		profile_resolved_destroy(&profile, allocator)
		return {}, config_error(
			.Invalid_Argument,
			"resolved thinking must be off, minimal, low, medium, high, xhigh, or max",
			allocator,
		)
	}
	return profile, Config_Error{}
}

profile_resolved_destroy :: proc(profile: ^Resolved_Profile, allocator := context.allocator) {
	delete(profile.provider, allocator)
	delete(profile.model, allocator)
	delete(profile.thinking, allocator)
	profile^ = Resolved_Profile{}
}
