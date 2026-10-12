package main

import "core:testing"

@(test)
test_pi_session_stats_parses_full_response :: proc(t: ^testing.T) {
	line := `{"tokens":{"input":100,"output":50,"cacheRead":10,` +
		`"cacheWrite":5,"total":165},"cost":0.1234,` +
		`"contextUsage":{"tokens":1000,"contextWindow":200000,"percent":0.5}}`
	stats, ok := pi_session_stats_parse(transmute([]byte)line)
	testing.expect(t, ok)
	testing.expect_value(t, stats.input, i64(100))
	testing.expect_value(t, stats.output, i64(50))
	testing.expect_value(t, stats.cache_read, i64(10))
	testing.expect_value(t, stats.cache_write, i64(5))
	testing.expect_value(t, stats.total, i64(165))
	testing.expect_value(t, stats.cost, 0.1234)
	testing.expect(t, stats.has_cost)
	testing.expect(t, stats.has_context_usage)
	testing.expect_value(t, stats.context_tokens, i64(1000))
	testing.expect_value(t, stats.context_window, i64(200000))
	testing.expect_value(t, stats.context_percent, 0.5)

	description := pi_session_stats_description(stats)
	defer delete(description)
	testing.expect_value(
		t,
		description,
		"input=100 output=50 cacheRead=10 cacheWrite=5 total=165 cost=0.1234",
	)
}

@(test)
test_pi_session_stats_reports_zero_cost_as_unavailable :: proc(t: ^testing.T) {
	line := `{"tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,` +
		`"total":10},"cost":0}`
	stats, ok := pi_session_stats_parse(transmute([]byte)line)
	testing.expect(t, ok)
	testing.expect(t, !stats.has_cost)

	description := pi_session_stats_description(stats)
	defer delete(description)
	testing.expect_value(
		t,
		description,
		"input=1 output=2 cacheRead=3 cacheWrite=4 total=10 cost=unavailable",
	)
}

@(test)
test_pi_session_stats_requires_readable_tokens :: proc(t: ^testing.T) {
	for line in ([]string{
		`{"cost":1,"contextUsage":{"tokens":1,"contextWindow":2,"percent":0.5}}`,
		`{"tokens":"not an object","cost":1}`,
		`{"tokens":{"input":1,"output":2,"cacheRead":3,"total":10},"cost":1}`,
		`{"tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,` +
		`"total":"many"},"cost":1}`,
	}) {
		stats, ok := pi_session_stats_parse(transmute([]byte)line)
		testing.expect(t, !ok, line)
		testing.expect_value(t, stats, Pi_Session_Stats{})
	}
}

@(test)
test_pi_session_stats_tolerates_malformed_json :: proc(t: ^testing.T) {
	for line in ([]string{
		``,
		`{`,
		`{"tokens":{"input":1,`,
		`not json at all`,
		`[]`,
	}) {
		stats, ok := pi_session_stats_parse(transmute([]byte)line)
		testing.expect(t, !ok, line)
		testing.expect_value(t, stats, Pi_Session_Stats{})
	}
}

@(test)
test_pi_session_stats_context_usage_is_optional :: proc(t: ^testing.T) {
	line := `{"tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,` +
		`"total":10},"cost":0.5}`
	stats, ok := pi_session_stats_parse(transmute([]byte)line)
	testing.expect(t, ok)
	testing.expect(t, !stats.has_context_usage)
	testing.expect_value(t, stats.context_tokens, i64(0))
	testing.expect_value(t, stats.context_window, i64(0))
	testing.expect_value(t, stats.context_percent, 0.0)
}
