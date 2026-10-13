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

// profile_resolve resolves the effective provider, model, and thinking level for
// a work item. Provider and model are one unit: the caller may supply both, or
// neither and take both from the config, but a lone provider or model is
// rejected. Thinking is resolved per field: the caller's value, then the
// config, then the built-in default. Every resolved value passes the same
// validation the configuration applies. The returned error owns its message;
// call config_error_destroy on every value.
profile_resolve :: proc(provider, model, thinking: string, allocator := context.allocator) -> (Resolved_Profile, Config_Error) {
	caller_provider := len(provider) > 0
	caller_model := len(model) > 0
	if caller_provider != caller_model {
		if caller_provider {
			return {}, config_errorf(.Invalid_Argument, allocator, "model is missing; provider %q was supplied without one", provider)
		}
		return {}, config_errorf(.Invalid_Argument, allocator, "provider is missing; model %q was supplied without one", model)
	}

	config, config_err := config_load("", allocator)
	have_config := config_err.kind == .None
	if !have_config && config_err.kind != .Not_Found {
		return {}, config_err
	}
	if !have_config && !caller_provider {
		// Neither the caller nor a config file supplies provider and model.
		return {}, config_err
	}
	if !have_config {
		config_error_destroy(&config_err, allocator)
	}
	// The defer is at procedure scope: an Odin defer runs when its block exits,
	// so one inside the branch above would free the config before it is read.
	defer config_destroy(&config, allocator)

	chosen_provider := provider
	chosen_model := model
	if !caller_provider {
		chosen_provider = config.provider
		chosen_model = config.model
	}
	chosen_thinking := thinking
	if len(chosen_thinking) == 0 {
		if have_config {
			chosen_thinking = config.thinking
		} else {
			chosen_thinking = DEFAULT_THINKING
		}
	}

	profile: Resolved_Profile
	chosen := [3]string{chosen_provider, chosen_model, chosen_thinking}
	destinations := [3]^string{&profile.provider, &profile.model, &profile.thinking}
	for value, index in chosen {
		owned, clone_err := strings.clone(value, allocator)
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
