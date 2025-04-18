package main

import shared "../shared"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"
import sdl_img "vendor:sdl3/image"

sdl_ok_panic :: proc(ok: bool) {
	if !ok do log.panicf("SDL Error: {}", sdl.GetError())
}
sdl_nil_panic :: proc(ptr: rawptr) {
	if ptr == nil do log.panicf("SDL Error: {}", sdl.GetError())
}

sdl_err :: proc {
	sdl_ok_panic,
	sdl_nil_panic,
}

MAX_DYNAMIC_BATCH :: 64
Vec3 :: [3]f32
Vertex_Data :: struct {
	pos:   Vec3,
	color: sdl.FColor,
}
main :: proc() {
	context.logger = log.create_console_logger()
	when ODIN_DEBUG == true {
		sdl.SetLogPriorities(.VERBOSE)
	}

	// init sdl
	ok := sdl.Init({.VIDEO});sdl_err(ok)
	window := sdl.CreateWindow(
		"Hello Triangle SDL3 Yay",
		1920,
		1080,
		{.FULLSCREEN},
	);sdl_err(window)
	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");sdl_err(gpu)
	ok = sdl.ClaimWindowForGPUDevice(gpu, window);sdl_err(ok)

	vertices := []Vertex_Data {
		{pos = {-0.5, 0.5, 0}, color = {1, 0, 0, 1}}, // tl
		{pos = {0.5, 0.5, 0}, color = {0, 1, 1, 1}}, // tr
		{pos = {-0.5, -0.5, 0}, color = {0, 1, 0, 1}}, // bl
		{pos = {0.5, -0.5, 0}, color = {1, 1, 0, 1}}, // br
	}
	vertices_byte_size := len(vertices) * size_of(Vertex_Data)
	vertices_byte_size_u32 := u32(vertices_byte_size)
	vertex_buf := sdl.CreateGPUBuffer(gpu, {usage = {.VERTEX}, size = vertices_byte_size_u32})

	indices := []u16{0, 1, 2, 2, 1, 3}
	indices_len := len(indices)
	indices_len_u32 := u32(indices_len)
	indices_byte_size := indices_len * size_of(u16)
	indices_byte_size_u32 := u32(indices_byte_size)
	indices_buf := sdl.CreateGPUBuffer(gpu, {usage = {.INDEX}, size = indices_byte_size_u32})
	//cpy to gpu
	{
		transfer_buf := sdl.CreateGPUTransferBuffer(
			gpu,
			{usage = .UPLOAD, size = vertices_byte_size_u32 + indices_byte_size_u32},
		)
		transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(gpu, transfer_buf, false)
		mem.copy(transfer_mem, raw_data(vertices), vertices_byte_size)
		mem.copy(transfer_mem[vertices_byte_size:], raw_data(indices), indices_byte_size)
		sdl.UnmapGPUTransferBuffer(gpu, transfer_buf)

		copy_cmd_buf := sdl.AcquireGPUCommandBuffer(gpu);sdl_err(copy_cmd_buf)
		defer {ok = sdl.SubmitGPUCommandBuffer(copy_cmd_buf);sdl_err(ok)}

		copy_pass := sdl.BeginGPUCopyPass(copy_cmd_buf)
		defer sdl.EndGPUCopyPass(copy_pass)

		sdl.UploadToGPUBuffer(
			copy_pass,
			{transfer_buffer = transfer_buf},
			{buffer = vertex_buf, size = vertices_byte_size_u32},
			false,
		)
		sdl.UploadToGPUBuffer(
			copy_pass,
			{transfer_buffer = transfer_buf, offset = vertices_byte_size_u32},
			{buffer = indices_buf, size = indices_byte_size_u32},
			false,
		)
	}

	vert_shader := load_shader(gpu, "default.spv.vert", {uniform_buffers = 1})
	frag_shader := load_shader(gpu, "default.spv.frag", {})

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, format = .FLOAT3, offset = u32(offset_of(Vertex_Data, pos))},
		{location = 1, format = .FLOAT4, offset = u32(offset_of(Vertex_Data, color))},
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(
		gpu,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
						slot = 0,
						pitch = size_of(Vertex_Data),
					}),
				num_vertex_attributes = u32(len(vertex_attrs)),
				vertex_attributes = raw_data(vertex_attrs),
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(gpu, window),
					}),
			},
		},
	)
	win_size: [2]i32
	ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y);sdl_err(ok)
	aspect := f32(win_size.x) / f32(win_size.y)
	proj_mat := lal.matrix4_perspective_f32(lal.to_radians(f32(90)), aspect, 0.0001, 1000)
	rotation := f32(0)
	rotation_speed := lal.to_radians(f32(90))
	position := lal.Vector3f32{0, 0, -5}

	Mvp_Ubo :: struct {
		mvps: [MAX_DYNAMIC_BATCH]matrix[4, 4]f32,
	}
	mvp_ubo: Mvp_Ubo
	last_ticks := sdl.GetTicks()
	main_loop: for {
		new_ticks := sdl.GetTicks()
		delta_time := f32(new_ticks - last_ticks) / 1000
		last_ticks = new_ticks
		// process events
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if ev.key.scancode == .ESCAPE do break main_loop
			}
		}
		// update game state

		// render
		{
			cmd_buf := sdl.AcquireGPUCommandBuffer(gpu);sdl_err(cmd_buf)
			defer {ok = sdl.SubmitGPUCommandBuffer(cmd_buf);sdl_err(ok)}

			swapchain_tex: ^sdl.GPUTexture
			ok = sdl.WaitAndAcquireGPUSwapchainTexture(
				cmd_buf,
				window,
				&swapchain_tex,
				nil,
				nil,
			);sdl_err(ok)
			if swapchain_tex == nil do continue

			color_target := sdl.GPUColorTargetInfo {
				texture     = swapchain_tex,
				load_op     = .CLEAR,
				clear_color = {0, 0, 0, 0},
				store_op    = .STORE,
			}
			render_pass := sdl.BeginGPURenderPass(cmd_buf, &color_target, 1, nil)
			defer sdl.EndGPURenderPass(render_pass)
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)

			// draw
			{
				num_instances := u32(2)
				model_mat := lal.matrix4_translate_f32(position)
				model_mat2 := model_mat * lal.matrix4_translate_f32({3, 0, 0})
				rotation += rotation_speed * delta_time
				model_mat *= lal.matrix4_rotate_f32(rotation, {1, 0, 0})
				model_mat2 *= lal.matrix4_rotate_f32(rotation, {0, 1, 0})
				mvp_ubo.mvps[0] = proj_mat * model_mat
				mvp_ubo.mvps[1] = proj_mat * model_mat2

				sdl.PushGPUVertexUniformData(
					cmd_buf,
					0,
					&(mvp_ubo),
					size_of(proj_mat) * num_instances,
				)
				sdl.BindGPUVertexBuffers(
					render_pass,
					0,
					&(sdl.GPUBufferBinding{buffer = vertex_buf}),
					1,
				)
				sdl.BindGPUIndexBuffer(
					render_pass,
					sdl.GPUBufferBinding{buffer = indices_buf},
					._16BIT,
				)
				sdl.DrawGPUIndexedPrimitives(render_pass, indices_len_u32, num_instances, 0, 0, 0)
			}
		}
	}
}

