package main

import "core:encoding/json"
import "core:fmt"

// Parses the `data` object of a Pi `get_session_stats` response:
//   {"tokens":{"input":N,"output":N,"cacheRead":N,"cacheWrite":N,"total":N},
//    "cost":N,"contextUsage":{"tokens":N,"contextWindow":N,"percent":N}}
Pi_Session_Stats :: struct {
	input:               i64,
	output:              i64,
	cache_read:          i64,
	cache_write:         i64,
	total:               i64,
	cost:                f64,
	has_cost:            bool,
	has_context_usage:   bool,
	context_tokens:      i64,
	context_window:      i64,
	context_percent:     f64,
}

pi_session_stats_parse :: proc(data: []byte) -> (stats: Pi_Session_Stats, ok: bool) {
	value, parse_err := json.parse(data, .JSON, false, context.temp_allocator)
	if parse_err != .None {
		return {}, false
	}
	defer json.destroy_value(value, context.temp_allocator)

	root, root_ok := value.(json.Object)
	if !root_ok {
		return {}, false
	}

	tokens_value, tokens_found := root["tokens"]
	tokens, tokens_ok := tokens_value.(json.Object)
	if !tokens_found || !tokens_ok {
		return {}, false
	}

	input, input_ok := pi_stats_int(tokens, "input")
	output, output_ok := pi_stats_int(tokens, "output")
	cache_read, cache_read_ok := pi_stats_int(tokens, "cacheRead")
	cache_write, cache_write_ok := pi_stats_int(tokens, "cacheWrite")
	total, total_ok := pi_stats_int(tokens, "total")
	cost, cost_ok := pi_stats_number(root, "cost")
	if !input_ok || !output_ok || !cache_read_ok || !cache_write_ok || !total_ok || !cost_ok {
		return {}, false
	}

	stats = Pi_Session_Stats {
		input       = input,
		output      = output,
		cache_read  = cache_read,
		cache_write = cache_write,
		total       = total,
		cost        = cost,
		// Pi reports 0 for a model its catalog cannot price.
		has_cost    = cost != 0,
	}

	context_value, context_found := root["contextUsage"]
	if !context_found {
		return stats, true
	}
	usage, usage_ok := context_value.(json.Object)
	if !usage_ok {
		return {}, false
	}
	context_tokens, context_tokens_ok := pi_stats_int(usage, "tokens")
	context_window, context_window_ok := pi_stats_int(usage, "contextWindow")
	context_percent, context_percent_ok := pi_stats_number(usage, "percent")
	if !context_tokens_ok || !context_window_ok || !context_percent_ok {
		return {}, false
	}
	stats.has_context_usage = true
	stats.context_tokens = context_tokens
	stats.context_window = context_window
	stats.context_percent = context_percent
	return stats, true
}

pi_session_stats_description :: proc(
	stats: Pi_Session_Stats,
	allocator := context.allocator,
) -> string {
	if !stats.has_cost {
		return fmt.aprintf(
			"input=%d output=%d cacheRead=%d cacheWrite=%d total=%d cost=unavailable",
			stats.input,
			stats.output,
			stats.cache_read,
			stats.cache_write,
			stats.total,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"input=%d output=%d cacheRead=%d cacheWrite=%d total=%d cost=%.4f",
		stats.input,
		stats.output,
		stats.cache_read,
		stats.cache_write,
		stats.total,
		stats.cost,
		allocator = allocator,
	)
}

pi_stats_int :: proc(object: json.Object, key: string) -> (value: i64, ok: bool) {
	raw, found := object[key]
	if !found {
		return 0, false
	}
	if integer, is_integer := raw.(json.Integer); is_integer {
		return i64(integer), true
	}
	if float, is_float := raw.(json.Float); is_float {
		return i64(float), true
	}
	return 0, false
}

pi_stats_number :: proc(object: json.Object, key: string) -> (value: f64, ok: bool) {
	raw, found := object[key]
	if !found {
		return 0, false
	}
	if float, is_float := raw.(json.Float); is_float {
		return f64(float), true
	}
	if integer, is_integer := raw.(json.Integer); is_integer {
		return f64(integer), true
	}
	return 0, false
}
