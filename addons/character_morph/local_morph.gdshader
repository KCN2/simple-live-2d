shader_type canvas_item;

// ============================================================================
// CharacterMorph2D - Local UV Deformation, Freeform Mask & Layer Composite Shader
// - 기본 모드: 단일 PNG 이미지의 선택된 타원형/마스크 영역 내부만 C1 연속 감쇠로 UV 변형
// - 확장 모드(5단계): 1.원본 몸체(TEXTURE) + 2.변형 파츠(morph_part_tex) + 3.보호 외곽선(protected_outline_tex)
// ============================================================================

group_uniforms PrimaryRegion;
uniform bool region_enabled = true;
uniform vec2 region_center = vec2(0.5, 0.48);
uniform vec2 region_radius = vec2(0.16, 0.14);
uniform vec2 morph_direction = vec2(0.0, -1.0);
uniform float morph_strength : hint_range(0.0, 0.2, 0.001) = 0.018;
uniform float scale_strength : hint_range(-0.5, 0.5, 0.005) = 0.04;
uniform float falloff : hint_range(0.2, 5.0, 0.05) = 1.5;
uniform float phase : hint_range(-2.0, 2.0, 0.01) = 0.0;

group_uniforms ProtectionAndComparison;
uniform float outline_protect : hint_range(0.0, 1.0, 0.05) = 0.5;
uniform bool bypass_morph = false;

group_uniforms ExtraRegions;
uniform int extra_region_count : hint_range(0, 7) = 0;
uniform vec2 extra_centers[7];
uniform vec2 extra_radii[7];
uniform vec2 extra_offsets[7];
uniform float extra_scales[7];
uniform float extra_falloffs[7];

group_uniforms FreeformMask;
uniform bool use_freeform_mask = false;
uniform sampler2D freeform_mask_tex : hint_default_black, filter_linear;

group_uniforms LayerComposite;
uniform bool layer_composite_mode = false;
uniform sampler2D morph_part_tex : hint_default_transparent, filter_linear;
uniform sampler2D protected_outline_tex : hint_default_transparent, filter_linear;
uniform float ghost_suppress : hint_range(0.0, 1.0, 0.05) = 0.85;
uniform float outline_follow_ratio : hint_range(0.0, 1.0, 0.05) = 0.65;

// Godot 4의 fragment() 내장 COLOR는 이미 texture(TEXTURE, UV)가 곱해져 있으므로,
// 원본 이미지가 변형 이미지에 중복 곱셈(잔상/이중선)되지 않도록 vertex()에서 순수 modulate만 전달합니다.
varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

vec2 compute_region_delta(
	vec2 uv,
	vec2 center,
	vec2 radius,
	vec2 dir_offset,
	float scale_offset,
	float falloff_exp
) {
	vec2 safe_r = max(radius, vec2(0.001));
	vec2 rel = uv - center;
	vec2 norm_p = rel / safe_r;
	float dist = length(norm_p);

	if (dist >= 1.0) {
		return vec2(0.0);
	}

	float base_t = clamp(1.0 - dist, 0.0, 1.0);
	float curved_t = pow(base_t, max(falloff_exp, 0.2));
	float weight = curved_t * curved_t * (3.0 - 2.0 * curved_t);

	vec2 raw_delta = (dir_offset + rel * scale_offset) * weight;

	float max_allowed = min(safe_r.x, safe_r.y) * 0.65;
	float delta_len = length(raw_delta);
	if (delta_len > max_allowed && delta_len > 0.00001) {
		raw_delta = (raw_delta / delta_len) * max_allowed;
	}

	return raw_delta;
}

vec4 alpha_over(vec4 bottom, vec4 top) {
	float out_a = top.a + bottom.a * (1.0 - top.a);
	if (out_a <= 0.0001) {
		return vec4(0.0);
	}
	vec3 out_rgb = (top.rgb * top.a + bottom.rgb * bottom.a * (1.0 - top.a)) / out_a;
	return vec4(out_rgb, out_a);
}

void fragment() {
	if (bypass_morph) {
		if (!layer_composite_mode) {
			COLOR = texture(TEXTURE, UV) * v_modulate;
		} else {
			vec4 body_c = texture(TEXTURE, UV);
			vec4 part_c = texture(morph_part_tex, UV);
			vec4 line_c = texture(protected_outline_tex, UV);
			vec4 comp = alpha_over(body_c, part_c);
			comp = alpha_over(comp, line_c);
			COLOR = comp * v_modulate;
		}
	} else {
		vec2 total_delta = vec2(0.0);

		// 1. 기본 변형 영역 (Region 0)
		if (region_enabled) {
			vec2 primary_offset = morph_direction * morph_strength * phase;
			float primary_scale = scale_strength * phase;
			total_delta += compute_region_delta(
				UV,
				region_center,
				region_radius,
				primary_offset,
				primary_scale,
				falloff
			);
		}

		// 2. 추가 다중 변형 영역 (Regions 1..7)
		int count = clamp(extra_region_count, 0, 7);
		for (int i = 0; i < count; i++) {
			total_delta += compute_region_delta(
				UV,
				extra_centers[i],
				extra_radii[i],
				extra_offsets[i],
				extra_scales[i],
				extra_falloffs[i]
			);
		}

		// 3. 4단계: 자유형 마스크 (R채널: 보호 지우개 고정, G채널: 변형 브러시 추가 변형)
		if (use_freeform_mask) {
			vec4 mask_sample = texture(freeform_mask_tex, UV);
			float erase_w = clamp(mask_sample.r, 0.0, 1.0);
			float brush_w = clamp(mask_sample.g, 0.0, 1.0);

			if (brush_w > 0.001 && region_enabled) {
				vec2 brush_delta = (morph_direction * morph_strength * phase) * brush_w;
				if (length(brush_delta) > length(total_delta)) {
					total_delta = mix(total_delta, brush_delta, brush_w);
				} else {
					total_delta += brush_delta * 0.5;
				}
			}

			// 보호 지우개로 문지른 부위(erase_w)는 변형량을 0으로 줄여 고정
			total_delta *= (1.0 - erase_w);
		}

		// 4. 외곽선/투명 경계 보호 보정
		if (outline_protect > 0.001 && length(total_delta) > 0.00001) {
			vec2 step_uv = TEXTURE_PIXEL_SIZE * 3.0;
			float a_center = texture(TEXTURE, UV).a;
			float a_right = texture(TEXTURE, clamp(UV + vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
			float a_left = texture(TEXTURE, clamp(UV - vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
			float a_down = texture(TEXTURE, clamp(UV + vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;
			float a_up = texture(TEXTURE, clamp(UV - vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;

			float min_alpha = min(a_center, min(min(a_right, a_left), min(a_down, a_up)));
			float edge_shield = smoothstep(0.05, 0.95, min_alpha);
			total_delta *= mix(1.0, edge_shield, outline_protect);
		}

		vec2 sample_uv = clamp(UV - total_delta, vec2(0.0), vec2(1.0));

		if (!layer_composite_mode) {
			// 기본 모드: 변형된 UV에서만 샘플링하여 원본 잔상 없이 순수 모핑 수행
			COLOR = texture(TEXTURE, sample_uv) * v_modulate;
		} else {
			// 확장 모드(5단계): 1.원본 몸체 + 2.변형 파츠 + 3.보호 외곽선 레이어 합성
			vec4 orig_part = texture(morph_part_tex, UV);
			vec4 moved_part = texture(morph_part_tex, sample_uv);

			float exposed_gap = clamp(orig_part.a - moved_part.a, 0.0, 1.0) * ghost_suppress;
			vec2 body_uv = mix(UV, clamp(UV + total_delta * 0.85, vec2(0.0), vec2(1.0)), exposed_gap);
			vec4 body_col = texture(TEXTURE, body_uv);

			if (exposed_gap > 0.01) {
				vec2 blur_step = TEXTURE_PIXEL_SIZE * 4.0;
				vec4 b1 = texture(TEXTURE, clamp(body_uv + vec2(blur_step.x, 0.0), vec2(0.0), vec2(1.0)));
				vec4 b2 = texture(TEXTURE, clamp(body_uv - vec2(blur_step.x, 0.0), vec2(0.0), vec2(1.0)));
				vec4 b3 = texture(TEXTURE, clamp(body_uv - vec2(0.0, blur_step.y), vec2(0.0), vec2(1.0)));
				vec4 smooth_body = (body_col + b1 + b2 + b3) * 0.25;
				body_col = mix(body_col, smooth_body, exposed_gap);
			}

			vec2 outline_uv = clamp(UV - total_delta * outline_follow_ratio, vec2(0.0), vec2(1.0));
			vec4 outline_col = texture(protected_outline_tex, outline_uv);

			vec4 composite = alpha_over(body_col, moved_part);
			composite = alpha_over(composite, outline_col);
			COLOR = composite * v_modulate;
		}
	}
}
