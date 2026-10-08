package main

import "base:runtime"

// Frees every allocation owned by s, then zeroes s. Walks strings, dynamic arrays,
// fixed arrays and nested structs by reflection. It does not follow pointers: a
// pointer field may be borrowed, so it is never freed here.
//
// Only use it on values this program allocated in full, such as decoded JSON or
// clones. A string that points at a literal must not be passed in: freeing it crashes.
destroy_struct :: proc(s: ^$T, allocator := context.allocator) {
	if s == nil {
		return
	}
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator
	destroy_value(rawptr(s), type_info_of(T))
	s^ = T{}
}

@(private = "file")
destroy_value :: proc(ptr: rawptr, info: ^runtime.Type_Info) {
	if ptr == nil || info == nil {
		return
	}
	#partial switch variant in info.variant {
	case runtime.Type_Info_Struct:
		for index in 0 ..< int(variant.field_count) {
			destroy_value(rawptr(uintptr(ptr) + variant.offsets[index]), variant.types[index])
		}
	case runtime.Type_Info_Array:
		for index in 0 ..< variant.count {
			destroy_value(rawptr(uintptr(ptr) + uintptr(index * variant.elem_size)), variant.elem)
		}
	case runtime.Type_Info_Dynamic_Array:
		header := (^runtime.Raw_Dynamic_Array)(ptr)
		for index in 0 ..< header.len {
			destroy_value(rawptr(uintptr(header.data) + uintptr(index * variant.elem_size)), variant.elem)
		}
		if header.data != nil {
			_ = runtime.mem_free_with_size(header.data, header.cap * variant.elem_size, header.allocator)
		}
		header^ = runtime.Raw_Dynamic_Array{}
	case runtime.Type_Info_String:
		_ = runtime.delete_string((^string)(ptr)^)
	case runtime.Type_Info_Named:
		// Named struct and string types reach here; the base type holds the layout.
		destroy_value(ptr, variant.base)
	case runtime.Type_Info_Map:
		panic("destroy_struct: maps are not supported; add a case before using one")
	case:
		// Scalars, pointers and procedures own nothing this helper may free.
	}
}
