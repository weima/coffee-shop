package main

import "core:strings"
import "core:testing"

@(test)
test_destroy_struct_frees_nested_owned_values :: proc(t: ^testing.T) {
	Item :: struct {
		name: string,
	}
	Bag :: struct {
		label: string,
		pair: [2]string,
		items: [dynamic]Item,
	}

	bag: Bag
	bag.label = strings.clone("bag")
	bag.pair[0] = strings.clone("a")
	bag.pair[1] = strings.clone("b")
	append(&bag.items, Item{name = strings.clone("x")})
	append(&bag.items, Item{name = strings.clone("y")})

	destroy_struct(&bag)
	testing.expect_value(t, bag.label, "")
	testing.expect_value(t, len(bag.items), 0)
	testing.expect(t, bag.items == nil, "the dynamic array must be released")
}

@(test)
test_destroy_struct_accepts_a_zero_value :: proc(t: ^testing.T) {
	Empty :: struct {
		name: string,
		items: [dynamic]string,
	}
	empty: Empty
	destroy_struct(&empty)
	testing.expect_value(t, empty.name, "")
}
