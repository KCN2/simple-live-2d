class_name CharacterMorph2D
extends Node2D
## 2D 캐릭터의 특정 국소 영역에 호흡, 바스트 모핑, 머리카락/의상 흔들림 등의
## 미세한 UV 변형 애니메이션을 적용하는 독립형 재사용 모듈.
##
## - 1~3단계: 단일 PNG 국소 타원 변형, 사인파 호흡 애니메이션, JSON 프리셋 직렬화
## - 4단계: 다중 영역(최대 8개), 영역별 독립 감쇠 스프링, 자유형 브러시 마스크(Freeform Mask)
## - 5단계: 확장 모드 3레이어 합성 (1.원본 몸체 + 2.변형 부위 + 3.보호 외곽선) 및 이중선/밑그림 보정
## - 직접 조작 GUI 기즈모 핸들(_gizmo_overlay)을 캐릭터 이미지(Sprite2D)보다 항상 앞(위)에 렌더링

signal preset_changed
signal region_updated(region_index: int)
signal phase_updated(current_phase: float)

enum GizmoPart {
	NONE = 0,
	CENTER_MOVE = 1,
	HANDLE_RADIUS_X = 2,
	HANDLE_RADIUS_Y = 3,
	HANDLE_RADIUS_XY = 4,
	HANDLE_ARROW_TIP = 5,
	OTHER_REGION = 6,
}

const SHADER_PATH: String = "res://addons/character_morph/local_morph.gdshader"
const MASK_RESOLUTION: int = 128
const ARROW_VISUAL_SCALE: float = 4.5

@export_group("Character & Preset")
## 1. 캐릭터 원본(또는 기본 몸체) 텍스처
@export var character_texture: Texture2D:
	set(value):
		character_texture = value
		if _sprite != null:
			_sprite.texture = value
			_request_gizmo_redraw()

## 2. [5단계 레이어 합성용] 변형되는 부위 파츠 텍스처
@export var morph_part_texture: Texture2D:
	set(value):
		morph_part_texture = value
		_update_shader_uniforms()
		_request_gizmo_redraw()

## 3. [5단계 레이어 합성용] 보호할 외곽선 텍스처
@export var protected_outline_texture: Texture2D:
	set(value):
		protected_outline_texture = value
		_update_shader_uniforms()
		_request_gizmo_redraw()

## 시작 시 자동으로 불러올 JSON 프리셋 파일 경로
@export_file("*.json") var preset_json_path: String = ""

@export_group("Animation Control")
## 자동 호흡 애니메이션 재생 여부
@export var auto_play: bool = true:
	set(value):
		auto_play = value
		_request_gizmo_redraw()

## 수동 테스트용 위상 값 (-1.0 ~ 1.0)
@export_range(-1.0, 1.0, 0.01) var manual_phase: float = 0.0:
	set(value):
		manual_phase = clampf(value, -1.0, 1.0)
		if not auto_play:
			_current_phase = manual_phase
			for i in range(MorphPreset.MAX_REGIONS):
				_region_phases[i] = manual_phase
			_update_shader_uniforms()
			_request_gizmo_redraw()

## 원본 비교 모드 (true면 변형을 끄고 원본 상태를 그대로 표시)
@export var bypass_morph: bool = false:
	set(value):
		bypass_morph = value
		_update_shader_uniforms()
		_request_gizmo_redraw()

@export_group("Debug & Editor")
## 변형 영역 타원 및 직접 조작 GUI 핸들 표시 여부 (실게임에서는 false 권장)
@export var show_debug_gizmo: bool = false:
	set(value):
		show_debug_gizmo = value
		_request_gizmo_redraw()

## 자유형 마스크 오버레이 시각화 여부
var show_mask_overlay: bool = false:
	set(value):
		show_mask_overlay = value
		_request_gizmo_redraw()

var brush_preview_active: bool = false
var brush_preview_uv: Vector2 = Vector2(0.5, 0.5)
## 브러시 반지름 (화면 픽셀 단위 — 줌 배율과 무관하게 고정된 크기의 완전한 원)
var brush_screen_radius: float = 30.0
## true: 보호 지우개(빨간 커서), false: 변형 브러시(초록 커서)
var brush_is_eraser: bool = false

## 여러 노드가 동일한 변형 결과를 렌더링할 수 있도록 셰이더 머티리얼을 공유합니다.
func get_shader_material() -> ShaderMaterial:
	return _shader_material

## 현재 줌(노드 스케일)을 반영한 브러시 반지름 (텍스처 픽셀 단위)
func get_brush_radius_tex_px() -> float:
	return brush_screen_radius / maxf(global_scale.x, 0.01)

## 현재 마우스가 가리키거나 드래그 중인 기즈모 핸들 파트
var hovered_gizmo_part: int = GizmoPart.NONE:
	set(value):
		if hovered_gizmo_part != value:
			hovered_gizmo_part = value
			_request_gizmo_redraw()

var active_gizmo_part: int = GizmoPart.NONE:
	set(value):
		if active_gizmo_part != value:
			active_gizmo_part = value
			_request_gizmo_redraw()

## 현재 선택/편집 중인 변형 영역 인덱스
var selected_region_index: int = 0:
	set(value):
		var max_idx: int = maxi(0, preset.get_region_count() - 1) if preset != null else 0
		selected_region_index = clampi(value, 0, max_idx)
		_request_gizmo_redraw()

var preset: MorphPreset = MorphPreset.new()

var _sprite: Sprite2D = null
var _gizmo_overlay: Node2D = null
var _shader_material: ShaderMaterial = null
var _anim_time: float = 0.0
var _current_phase: float = 0.0
var _region_phases: Array[float] = []
var _region_velocities: Array[float] = []

var _mask_image: Image = null
var _mask_texture: ImageTexture = null
var _mask_visual_image: Image = null
var _mask_visual_texture: ImageTexture = null


func _ready() -> void:
	_init_spring_arrays()
	_init_freeform_mask()
	_ensure_sprite_and_material()

	if character_texture != null:
		_sprite.texture = character_texture
	elif _sprite.texture != null:
		character_texture = _sprite.texture

	if not preset_json_path.is_empty() and FileAccess.file_exists(preset_json_path):
		load_preset_file(preset_json_path)
	else:
		_update_shader_uniforms()


func _process(delta: float) -> void:
	if preset == null:
		return

	if auto_play:
		_anim_time += delta * preset.breathing_speed * PI
		if _anim_time > TAU * 1000.0:
			_anim_time = fmod(_anim_time, TAU)

	var total_regions: int = preset.get_region_count()
	for i in range(MorphPreset.MAX_REGIONS):
		var offset_rad: float = 0.0
		var spring_w: float = 1.0
		if i < total_regions:
			var reg: Dictionary = preset.get_region(i)
			offset_rad = float(reg.get("phase_offset", 0.0))
			spring_w = maxf(float(reg.get("spring_weight", 1.0)), 0.2)

		var target_p: float
		if auto_play:
			target_p = sin(_anim_time + offset_rad) * preset.breathing_amplitude
		else:
			target_p = manual_phase * preset.breathing_amplitude

		if preset.spring_enabled:
			var eff_stiffness: float = preset.spring_stiffness / spring_w
			var eff_damping: float = preset.spring_damping / sqrt(spring_w)
			var force: float = (target_p - _region_phases[i]) * eff_stiffness
			_region_velocities[i] += force * delta
			_region_velocities[i] *= exp(-eff_damping * delta)
			_region_phases[i] += _region_velocities[i] * delta
		else:
			_region_phases[i] = target_p
			_region_velocities[i] = 0.0

	var sel_idx: int = clampi(selected_region_index, 0, MorphPreset.MAX_REGIONS - 1)
	_current_phase = _region_phases[sel_idx]

	_update_shader_uniforms()
	phase_updated.emit(_current_phase)

	if show_debug_gizmo or show_mask_overlay:
		_request_gizmo_redraw()


func _init_spring_arrays() -> void:
	_region_phases.resize(MorphPreset.MAX_REGIONS)
	_region_velocities.resize(MorphPreset.MAX_REGIONS)
	for i in range(MorphPreset.MAX_REGIONS):
		_region_phases[i] = 0.0
		_region_velocities[i] = 0.0


func _request_gizmo_redraw() -> void:
	queue_redraw()
	if _gizmo_overlay != null:
		_gizmo_overlay.queue_redraw()


# ============================================================================
# 이미지 및 5단계 레이어 로드 API
# ============================================================================

func load_image_from_file(file_path: String) -> Error:
	var tex := _load_texture_any(file_path)
	if tex == null:
		return ERR_CANT_OPEN
	set_character_texture(tex)
	return OK


func load_morph_part_from_file(file_path: String) -> Error:
	var tex := _load_texture_any(file_path)
	if tex == null:
		return ERR_CANT_OPEN
	morph_part_texture = tex
	return OK


func load_protected_outline_from_file(file_path: String) -> Error:
	var tex := _load_texture_any(file_path)
	if tex == null:
		return ERR_CANT_OPEN
	protected_outline_texture = tex
	return OK


func _load_texture_any(file_path: String) -> Texture2D:
	if file_path.is_empty():
		return null

	# 1. 파일의 실제 헤더(매직 바이트)를 검사하여 확장자와 실제 포맷이 다른 이미지(예: JPG/WebP인데 확장자가 .png인 파일)도 정상 로드
	if FileAccess.file_exists(file_path):
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(file_path)
		if bytes.size() >= 12:
			var img := Image.new()
			var err: Error = ERR_FILE_UNRECOGNIZED

			# PNG: 89 50 4E 47
			if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
				err = img.load_png_from_buffer(bytes)
			# JPEG: FF D8 FF
			elif bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
				err = img.load_jpg_from_buffer(bytes)
			# WebP: "RIFF" .... "WEBP"
			elif (
				bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46
				and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50
			):
				err = img.load_webp_from_buffer(bytes)
			# BMP: "BM" (42 4D)
			elif bytes[0] == 0x42 and bytes[1] == 0x4D:
				err = img.load_bmp_from_buffer(bytes)
			# SVG: '<' (0x3C) 또는 UTF-8 BOM + '<' 또는 확장자 .svg
			elif bytes[0] == 0x3C or (bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) or file_path.get_extension().to_lower() == "svg":
				err = img.load_svg_from_buffer(bytes)
			else:
				err = img.load_png_from_buffer(bytes)
				if err != OK:
					err = img.load_jpg_from_buffer(bytes)
				if err != OK:
					err = img.load_webp_from_buffer(bytes)
				if err != OK:
					err = img.load_bmp_from_buffer(bytes)
				if err != OK:
					err = img.load_tga_from_buffer(bytes)

			if err == OK and not img.is_empty():
				return ImageTexture.create_from_image(img)

	# 2. 이미 임포트된 res:// 리소스 폴백
	if file_path.begins_with("res://") and ResourceLoader.exists(file_path):
		var res := ResourceLoader.load(file_path)
		if res is Texture2D:
			return res

	return null


func set_character_texture(tex: Texture2D) -> void:
	_ensure_sprite_and_material()
	character_texture = tex
	_sprite.texture = tex
	_update_shader_uniforms()
	_request_gizmo_redraw()


func get_texture_size() -> Vector2:
	if _sprite != null and _sprite.texture != null:
		return _sprite.texture.get_size()
	return Vector2.ZERO


func get_current_phase() -> float:
	return _current_phase


# ============================================================================
# 애니메이션 및 탄성 자극 API
# ============================================================================

func play() -> void:
	auto_play = true


func pause() -> void:
	auto_play = false


func stop() -> void:
	auto_play = false
	_anim_time = 0.0
	manual_phase = 0.0
	_current_phase = 0.0
	for i in range(MorphPreset.MAX_REGIONS):
		_region_phases[i] = 0.0
		_region_velocities[i] = 0.0
	_update_shader_uniforms()
	_request_gizmo_redraw()


func trigger_impulse(impulse: float = 1.2) -> void:
	if preset != null and not preset.spring_enabled:
		preset.spring_enabled = true
	for i in range(MorphPreset.MAX_REGIONS):
		var w: float = 1.0
		if preset != null and i < preset.get_region_count():
			w = maxf(float(preset.get_region(i).get("spring_weight", 1.0)), 0.2)
		_region_velocities[i] += (impulse * 9.0) / sqrt(w)


# ============================================================================
# 4단계: 자유형 마스크 (R채널: 보호 지우개, G채널: 변형 브러시) 및 개별 초기화 API
# ============================================================================

func _init_freeform_mask() -> void:
	_mask_image = Image.create(MASK_RESOLUTION, MASK_RESOLUTION, false, Image.FORMAT_RGBA8)
	_mask_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_mask_texture = ImageTexture.create_from_image(_mask_image)

	_mask_visual_image = Image.create(MASK_RESOLUTION, MASK_RESOLUTION, false, Image.FORMAT_RGBA8)
	_mask_visual_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_mask_visual_texture = ImageTexture.create_from_image(_mask_visual_image)


func _rebuild_mask_visual() -> void:
	if _mask_image == null or _mask_visual_image == null:
		return
	for py in range(MASK_RESOLUTION):
		for px in range(MASK_RESOLUTION):
			var c: Color = _mask_image.get_pixel(px, py)
			var erase_w: float = c.r
			var brush_w: float = c.g
			if erase_w <= 0.01 and brush_w <= 0.01:
				_mask_visual_image.set_pixel(px, py, Color(0.0, 0.0, 0.0, 0.0))
			elif erase_w >= brush_w:
				_mask_visual_image.set_pixel(px, py, Color(1.0, 0.25, 0.35, erase_w * 0.48))
			else:
				_mask_visual_image.set_pixel(px, py, Color(0.15, 0.95, 0.55, brush_w * 0.48))
	_mask_visual_texture.update(_mask_visual_image)


## 보호 지우개(R채널)만 초기화합니다 (변형 브러시 내용은 유지).
func clear_protection_eraser() -> void:
	if _mask_image == null:
		_init_freeform_mask()
	for py in range(MASK_RESOLUTION):
		for px in range(MASK_RESOLUTION):
			var c: Color = _mask_image.get_pixel(px, py)
			_mask_image.set_pixel(px, py, Color(0.0, c.g, 0.0, 1.0))
	_mask_texture.update(_mask_image)
	_rebuild_mask_visual()
	_sync_mask_to_preset_base64()
	_update_shader_uniforms()
	_request_gizmo_redraw()


## 변형 브러시(G채널)만 초기화합니다 (보호 지우개 내용은 유지).
func clear_deform_brush() -> void:
	if _mask_image == null:
		_init_freeform_mask()
	for py in range(MASK_RESOLUTION):
		for px in range(MASK_RESOLUTION):
			var c: Color = _mask_image.get_pixel(px, py)
			_mask_image.set_pixel(px, py, Color(c.r, 0.0, 0.0, 1.0))
	_mask_texture.update(_mask_image)
	_rebuild_mask_visual()
	_sync_mask_to_preset_base64()
	_update_shader_uniforms()
	_request_gizmo_redraw()


func fill_freeform_mask(weight_value: float = 1.0) -> void:
	if _mask_image == null:
		_init_freeform_mask()
	var erase_v: float = clampf(1.0 - weight_value, 0.0, 1.0)
	_mask_image.fill(Color(erase_v, 0.0, 0.0, 1.0))
	_mask_texture.update(_mask_image)
	_rebuild_mask_visual()
	_sync_mask_to_preset_base64()
	_update_shader_uniforms()
	_request_gizmo_redraw()


## 보호 지우개 칠하기 (움직이면 안 되는 영역을 R채널에 칠하고, 겹치는 변형 브러시는 지움)
func paint_protection_eraser_uv(
	center_uv: Vector2,
	radius_uv: float,
	brush_strength: float = 0.7
) -> void:
	_paint_mask_channel_uv(center_uv, radius_uv, true, brush_strength)


## 변형 브러시 칠하기 (움직일 영역을 G채널에 칠하고, 겹치는 보호 지우개는 해제)
func paint_deform_brush_uv(
	center_uv: Vector2,
	radius_uv: float,
	brush_strength: float = 0.7
) -> void:
	_paint_mask_channel_uv(center_uv, radius_uv, false, brush_strength)


func paint_freeform_mask_uv(
	center_uv: Vector2,
	radius_uv: float,
	target_value: float,
	brush_strength: float = 0.65
) -> void:
	if target_value < 0.5:
		paint_protection_eraser_uv(center_uv, radius_uv, brush_strength)
	else:
		paint_deform_brush_uv(center_uv, radius_uv, brush_strength)


func _paint_mask_channel_uv(
	center_uv: Vector2,
	radius_uv: float,
	is_eraser: bool,
	brush_strength: float
) -> void:
	if _mask_image == null:
		_init_freeform_mask()

	var tex_size: Vector2 = get_texture_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return

	# radius_uv 인자는 이제 '텍스처 픽셀 단위 반지름'입니다 (종횡비와 무관한 완전한 원)
	var r_px: float = maxf(radius_uv, 1.0)
	var r_uv_x: float = r_px / tex_size.x
	var r_uv_y: float = r_px / tex_size.y
	var min_x: int = clampi(int(floor((center_uv.x - r_uv_x) * MASK_RESOLUTION)), 0, MASK_RESOLUTION - 1)
	var max_x: int = clampi(int(ceil((center_uv.x + r_uv_x) * MASK_RESOLUTION)), 0, MASK_RESOLUTION - 1)
	var min_y: int = clampi(int(floor((center_uv.y - r_uv_y) * MASK_RESOLUTION)), 0, MASK_RESOLUTION - 1)
	var max_y: int = clampi(int(ceil((center_uv.y + r_uv_y) * MASK_RESOLUTION)), 0, MASK_RESOLUTION - 1)

	var str_val: float = clampf(brush_strength, 0.05, 1.0)

	for py in range(min_y, max_y + 1):
		var uvy: float = (float(py) + 0.5) / float(MASK_RESOLUTION)
		for px in range(min_x, max_x + 1):
			var uvx: float = (float(px) + 0.5) / float(MASK_RESOLUTION)
			var dist: float = Vector2((uvx - center_uv.x) * tex_size.x, (uvy - center_uv.y) * tex_size.y).length() / r_px
			if dist < 1.0:
				var falloff_t: float = 1.0 - dist
				var w: float = falloff_t * falloff_t * (3.0 - 2.0 * falloff_t) * str_val
				var cur: Color = _mask_image.get_pixel(px, py)
				var next_r: float = cur.r
				var next_g: float = cur.g
				if is_eraser:
					next_r = lerpf(cur.r, 1.0, w)
					next_g = lerpf(cur.g, 0.0, w)
				else:
					next_g = lerpf(cur.g, 1.0, w)
					next_r = lerpf(cur.r, 0.0, w)
				_mask_image.set_pixel(px, py, Color(next_r, next_g, 0.0, 1.0))

				if next_r <= 0.01 and next_g <= 0.01:
					_mask_visual_image.set_pixel(px, py, Color(0.0, 0.0, 0.0, 0.0))
				elif next_r >= next_g:
					_mask_visual_image.set_pixel(px, py, Color(1.0, 0.25, 0.35, next_r * 0.48))
				else:
					_mask_visual_image.set_pixel(px, py, Color(0.15, 0.95, 0.55, next_g * 0.48))

	_mask_texture.update(_mask_image)
	_mask_visual_texture.update(_mask_visual_image)
	_update_shader_uniforms()
	_request_gizmo_redraw()


func finalize_freeform_mask_stroke() -> void:
	_sync_mask_to_preset_base64()


func _sync_mask_to_preset_base64() -> void:
	if preset == null or _mask_image == null:
		return
	if not preset.freeform_mask_enabled:
		return
	var png_buf: PackedByteArray = _mask_image.save_png_to_buffer()
	preset.freeform_mask_base64 = Marshalls.raw_to_base64(png_buf)


func _restore_mask_from_preset_base64() -> void:
	if _mask_image == null:
		_init_freeform_mask()
	if preset == null or preset.freeform_mask_base64.is_empty():
		_mask_image.fill(Color(0.0, 0.0, 0.0, 1.0))
		_mask_texture.update(_mask_image)
		_rebuild_mask_visual()
		return
	var raw: PackedByteArray = Marshalls.base64_to_raw(preset.freeform_mask_base64)
	var loaded_img := Image.new()
	if loaded_img.load_png_from_buffer(raw) == OK:
		loaded_img.convert(Image.FORMAT_RGBA8)
		loaded_img.resize(MASK_RESOLUTION, MASK_RESOLUTION, Image.INTERPOLATE_BILINEAR)
		# 구버전(흰색 배경 B=1.0) 마스크 호환 변환
		if loaded_img.get_pixel(0, 0).b > 0.5:
			for py in range(MASK_RESOLUTION):
				for px in range(MASK_RESOLUTION):
					var old_c: Color = loaded_img.get_pixel(px, py)
					loaded_img.set_pixel(px, py, Color(clampf(1.0 - old_c.r, 0.0, 1.0), 0.0, 0.0, 1.0))
		_mask_image = loaded_img
		_mask_texture = ImageTexture.create_from_image(_mask_image)
		_rebuild_mask_visual()


# ============================================================================
# 움직이는 GIF(.gif) 내보내기 API
# ============================================================================

## 현재 캐릭터와 모핑 설정으로 호흡 1주기(무한 루프)를 렌더링하여 움직이는 .gif 파일로 저장합니다.
func export_animated_gif(
	file_path: String,
	fps: int = 20,
	max_dimension: int = 1024,
	progress_callback: Callable = Callable()
) -> Error:
	if _sprite == null or _sprite.texture == null or preset == null:
		return ERR_UNCONFIGURED

	var tex_size: Vector2 = _sprite.texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return ERR_UNCONFIGURED

	# max_dimension <= 0 이면 원본 해상도 그대로 (GIF 한계를 고려해 최대 2048px)
	var max_side: float = maxf(tex_size.x, tex_size.y)
	var limit: float = 2048.0 if max_dimension <= 0 else float(max_dimension)
	var scale_factor: float = minf(1.0, limit / max_side)
	var gif_w: int = maxi(16, int(round(tex_size.x * scale_factor)))
	var gif_h: int = maxi(16, int(round(tex_size.y * scale_factor)))

	var safe_fps: int = clampi(fps, 8, 30)
	var speed: float = maxf(preset.breathing_speed, 0.25)
	var cycle_duration: float = clampf(2.0 / speed, 0.8, 3.0)
	var frame_count: int = clampi(int(round(cycle_duration * float(safe_fps))), 12, 36)
	var delay_cs: int = maxi(3, int(round(100.0 / float(safe_fps))))

	var sub_vp := SubViewport.new()
	sub_vp.size = Vector2i(gif_w, gif_h)
	sub_vp.transparent_bg = true
	sub_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	sub_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var cap_sprite := Sprite2D.new()
	cap_sprite.centered = false
	cap_sprite.position = Vector2.ZERO
	cap_sprite.texture = _sprite.texture
	cap_sprite.scale = Vector2(float(gif_w) / tex_size.x, float(gif_h) / tex_size.y)

	_update_shader_uniforms()
	var cap_mat: ShaderMaterial = _shader_material.duplicate() as ShaderMaterial
	cap_mat.set_shader_parameter("bypass_morph", false)
	cap_sprite.material = cap_mat

	sub_vp.add_child(cap_sprite)
	add_child(sub_vp)

	var frames: Array[Image] = []
	var total_regions: int = preset.get_region_count()
	var extra_count: int = clampi(total_regions - 1, 0, 7)

	for f in range(frame_count):
		var theta: float = (float(f) / float(frame_count)) * TAU

		if total_regions > 0:
			var r0: Dictionary = preset.get_region(0)
			var r0_off: float = float(r0.get("phase_offset", 0.0))
			var r0_phase: float = sin(theta + r0_off) * preset.breathing_amplitude if bool(r0.get("enabled", true)) else 0.0
			cap_mat.set_shader_parameter("phase", r0_phase)

		var offsets: Array[Vector2] = []
		var scales: Array[float] = []
		for i in range(7):
			if i < extra_count:
				var reg: Dictionary = preset.get_region(i + 1)
				var is_on: bool = bool(reg.get("enabled", true))
				var ri_off: float = float(reg.get("phase_offset", 0.0))
				var ri_phase: float = sin(theta + ri_off) * preset.breathing_amplitude if is_on else 0.0
				var dir_v: Vector2 = reg.get("direction", Vector2(0.0, -1.0))
				var str_v: float = float(reg.get("strength", 0.018))
				var scl_v: float = float(reg.get("scale_strength", 0.04))
				offsets.append(dir_v * str_v * ri_phase)
				scales.append(scl_v * ri_phase)
			else:
				offsets.append(Vector2.ZERO)
				scales.append(0.0)

		cap_mat.set_shader_parameter("extra_offsets", offsets)
		cap_mat.set_shader_parameter("extra_scales", scales)

		if progress_callback.is_valid():
			progress_callback.call(f + 1, frame_count, false)

		await RenderingServer.frame_post_draw
		var img: Image = sub_vp.get_texture().get_image()
		if img != null and not img.is_empty():
			frames.append(img)

	remove_child(sub_vp)
	sub_vp.queue_free()

	if frames.is_empty():
		return ERR_CANT_CREATE

	# 고화질 인코딩은 계산량이 크므로 별도 스레드에서 수행하고, UI는 멈추지 않게 프레임마다 진행률만 확인합니다.
	var progress: Array = [0]
	var thread := Thread.new()
	thread.start(GifExporter.save_animated_gif.bind(file_path, frames, delay_cs, progress))
	while thread.is_alive():
		if progress_callback.is_valid():
			progress_callback.call(int(progress[0]), frame_count, true)
		await get_tree().process_frame
	return thread.wait_to_finish() as Error


# ============================================================================
# 프리셋 저장/불러오기 및 영역 제어 API
# ============================================================================

func apply_preset(new_preset: MorphPreset) -> void:
	if new_preset == null:
		return
	preset = new_preset
	selected_region_index = clampi(selected_region_index, 0, maxi(0, preset.get_region_count() - 1))
	_restore_mask_from_preset_base64()
	_update_shader_uniforms()
	preset_changed.emit()
	_request_gizmo_redraw()


func load_preset_file(file_path: String) -> Error:
	var err: Error = preset.load_from_json(file_path)
	if err == OK:
		selected_region_index = clampi(selected_region_index, 0, maxi(0, preset.get_region_count() - 1))
		_restore_mask_from_preset_base64()
		_update_shader_uniforms()
		preset_changed.emit()
		_request_gizmo_redraw()
	return err


func save_preset_file(file_path: String) -> Error:
	if preset == null:
		return ERR_UNCONFIGURED
	_sync_mask_to_preset_base64()
	return preset.save_to_json(file_path)


func reset_preset() -> void:
	preset.reset_to_default()
	selected_region_index = 0
	_anim_time = 0.0
	for i in range(MorphPreset.MAX_REGIONS):
		_region_phases[i] = 0.0
		_region_velocities[i] = 0.0
	clear_protection_eraser()
	clear_deform_brush()
	_update_shader_uniforms()
	preset_changed.emit()
	_request_gizmo_redraw()


func get_active_region() -> Dictionary:
	return preset.get_region(selected_region_index)


func set_region_center(center_uv: Vector2, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["center"] = center_uv.clamp(Vector2.ZERO, Vector2.ONE)
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


func set_region_radius(radius_uv: Vector2, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["radius"] = radius_uv.clamp(Vector2(0.015, 0.015), Vector2(0.65, 0.65))
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


func set_region_direction(direction_vec: Vector2, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["direction"] = direction_vec.clamp(Vector2(-1.0, -1.0), Vector2(1.0, 1.0))
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


func set_region_strength(strength_val: float, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["strength"] = clampf(strength_val, 0.0, 0.12)
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


func set_region_scale_strength(scale_val: float, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["scale_strength"] = clampf(scale_val, -0.35, 0.35)
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


func set_region_falloff(falloff_val: float, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["falloff"] = clampf(falloff_val, 0.2, 5.0)
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


func set_region_phase_offset(offset_rad: float, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["phase_offset"] = clampf(offset_rad, -PI, PI)
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


func set_region_spring_weight(weight_val: float, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["spring_weight"] = clampf(weight_val, 0.2, 3.0)
	region_updated.emit(idx)


func set_region_enabled(enabled_val: bool, region_idx: int = -1) -> void:
	var idx: int = selected_region_index if region_idx < 0 else region_idx
	var reg: Dictionary = preset.get_region(idx)
	reg["enabled"] = enabled_val
	_update_shader_uniforms()
	region_updated.emit(idx)
	_request_gizmo_redraw()


# ============================================================================
# 좌표 변환 및 직접 조작 GUI 기즈모 핸들 판정(Hit-Test)
# ============================================================================

func global_pos_to_uv(global_pos: Vector2) -> Vector2:
	var tex_size: Vector2 = get_texture_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return Vector2(0.5, 0.5)

	var local_pos: Vector2 = to_local(global_pos)
	var top_left: Vector2 = -tex_size * 0.5 if (_sprite == null or _sprite.centered) else Vector2.ZERO
	return (local_pos - top_left) / tex_size


func uv_to_local_pos(uv: Vector2) -> Vector2:
	var tex_size: Vector2 = get_texture_size()
	var top_left: Vector2 = -tex_size * 0.5 if (_sprite == null or _sprite.centered) else Vector2.ZERO
	return top_left + uv * tex_size


func is_uv_in_bounds(uv: Vector2) -> bool:
	return uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0


func hit_test_gizmo(global_pos: Vector2) -> Dictionary:
	var tex_size: Vector2 = get_texture_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0 or preset == null:
		return {"part": GizmoPart.NONE, "region_index": selected_region_index}

	var local_pos: Vector2 = to_local(global_pos)
	var top_left: Vector2 = -tex_size * 0.5 if (_sprite == null or _sprite.centered) else Vector2.ZERO
	var grab_radius: float = 16.0 / maxf(global_scale.x, 0.2)

	var reg: Dictionary = get_active_region()
	var center_px: Vector2 = top_left + Vector2(reg.get("center", Vector2(0.5, 0.48))) * tex_size
	var radius_px: Vector2 = Vector2(reg.get("radius", Vector2(0.16, 0.14))) * tex_size
	var dir_vec: Vector2 = reg.get("direction", Vector2(0.0, -1.0))
	var strength_val: float = float(reg.get("strength", 0.018))

	var arrow_vec_px: Vector2 = dir_vec * (strength_val * tex_size * ARROW_VISUAL_SCALE)
	if arrow_vec_px.length() < 20.0:
		var fallback_dir: Vector2 = dir_vec.normalized() if dir_vec.length() > 0.01 else Vector2(0.0, -1.0)
		arrow_vec_px = fallback_dir * 20.0
	var arrow_tip_px: Vector2 = center_px + arrow_vec_px

	var right_handle_px: Vector2 = center_px + Vector2(radius_px.x, 0.0)
	var bottom_handle_px: Vector2 = center_px + Vector2(0.0, radius_px.y)
	var corner_handle_px: Vector2 = center_px + Vector2(radius_px.x, radius_px.y) * 0.70710678

	# 1순위: 방향·강도 화살표 끝 핸들
	if local_pos.distance_to(arrow_tip_px) <= grab_radius * 1.2:
		return {"part": GizmoPart.HANDLE_ARROW_TIP, "region_index": selected_region_index}

	# 2순위: 가로/세로/대각선 반경 조절 핸들
	if local_pos.distance_to(right_handle_px) <= grab_radius:
		return {"part": GizmoPart.HANDLE_RADIUS_X, "region_index": selected_region_index}
	if local_pos.distance_to(bottom_handle_px) <= grab_radius:
		return {"part": GizmoPart.HANDLE_RADIUS_Y, "region_index": selected_region_index}
	if local_pos.distance_to(corner_handle_px) <= grab_radius:
		return {"part": GizmoPart.HANDLE_RADIUS_XY, "region_index": selected_region_index}

	# 3순위: 중심 핸들
	if local_pos.distance_to(center_px) <= grab_radius * 1.25:
		return {"part": GizmoPart.CENTER_MOVE, "region_index": selected_region_index}

	# 4순위: 다른 영역의 중심/타원 클릭 시 해당 영역으로 전환
	var total_regions: int = preset.get_region_count()
	for i in range(total_regions):
		if i == selected_region_index:
			continue
		var other_reg: Dictionary = preset.get_region(i)
		var oc_px: Vector2 = top_left + Vector2(other_reg.get("center", Vector2(0.5, 0.5))) * tex_size
		var or_px: Vector2 = Vector2(other_reg.get("radius", Vector2(0.15, 0.15))) * tex_size
		var norm_d: Vector2 = (local_pos - oc_px) / Vector2(maxf(or_px.x, 1.0), maxf(or_px.y, 1.0))
		if norm_d.length() <= 1.0:
			return {"part": GizmoPart.OTHER_REGION, "region_index": i}

	# 5순위: 현재 선택 타원 내부 또는 캔버스 클릭 시 중심 이동
	return {"part": GizmoPart.CENTER_MOVE, "region_index": selected_region_index}


func drag_arrow_tip_to_global_pos(global_pos: Vector2) -> void:
	var tex_size: Vector2 = get_texture_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var top_left: Vector2 = -tex_size * 0.5 if (_sprite == null or _sprite.centered) else Vector2.ZERO
	var local_pos: Vector2 = to_local(global_pos)
	var reg: Dictionary = get_active_region()
	var center_px: Vector2 = top_left + Vector2(reg.get("center", Vector2(0.5, 0.48))) * tex_size
	var delta_px: Vector2 = local_pos - center_px

	if delta_px.length() < 3.0:
		reg["strength"] = 0.0
	else:
		var dir_norm: Vector2 = delta_px.normalized()
		var avg_size: float = (tex_size.x + tex_size.y) * 0.5
		var new_strength: float = clampf(delta_px.length() / (avg_size * ARROW_VISUAL_SCALE), 0.0, 0.08)
		reg["direction"] = dir_norm
		reg["strength"] = new_strength

	_update_shader_uniforms()
	region_updated.emit(selected_region_index)
	_request_gizmo_redraw()


# ============================================================================
# 내부 구현: Sprite2D/ShaderMaterial 동기화 및 전면(_gizmo_overlay) 렌더링
# ============================================================================

func _ensure_sprite_and_material() -> void:
	if _sprite == null:
		_sprite = get_node_or_null("Sprite2D") as Sprite2D
		if _sprite == null:
			_sprite = Sprite2D.new()
			_sprite.name = "Sprite2D"
			_sprite.centered = true
			add_child(_sprite)

	# 조종 기즈모(원, 네모 핸들, 화살표)가 항상 캐릭터 그림(Sprite2D)보다 앞(위)에 그려지도록 전용 오버레이 자식 노드 생성
	if _gizmo_overlay == null:
		_gizmo_overlay = get_node_or_null("GizmoOverlay") as Node2D
		if _gizmo_overlay == null:
			_gizmo_overlay = Node2D.new()
			_gizmo_overlay.name = "GizmoOverlay"
			_gizmo_overlay.z_index = 10
			add_child(_gizmo_overlay)
			_gizmo_overlay.draw.connect(_on_gizmo_overlay_draw)
		move_child(_gizmo_overlay, -1)

	if _sprite.material is ShaderMaterial:
		if _shader_material == null:
			_shader_material = (_sprite.material as ShaderMaterial).duplicate() as ShaderMaterial
			_sprite.material = _shader_material
	else:
		_shader_material = ShaderMaterial.new()
		if ResourceLoader.exists(SHADER_PATH):
			_shader_material.shader = load(SHADER_PATH) as Shader
		_sprite.material = _shader_material


func _get_region_live_phase(region_idx: int) -> float:
	if _region_phases.is_empty():
		return _current_phase
	var safe_i: int = clampi(region_idx, 0, _region_phases.size() - 1)
	return _region_phases[safe_i]


func _update_shader_uniforms() -> void:
	if _shader_material == null or preset == null:
		return

	_shader_material.set_shader_parameter("bypass_morph", bypass_morph)
	_shader_material.set_shader_parameter("outline_protect", preset.outline_protect)

	_shader_material.set_shader_parameter("use_freeform_mask", preset.freeform_mask_enabled)
	if _mask_texture != null:
		_shader_material.set_shader_parameter("freeform_mask_tex", _mask_texture)

	var use_layers: bool = preset.layer_composite_enabled and (morph_part_texture != null)
	_shader_material.set_shader_parameter("layer_composite_mode", use_layers)
	_shader_material.set_shader_parameter("ghost_suppress", preset.ghost_suppress)
	_shader_material.set_shader_parameter("outline_follow_ratio", preset.outline_follow_ratio)
	if morph_part_texture != null:
		_shader_material.set_shader_parameter("morph_part_tex", morph_part_texture)
	if protected_outline_texture != null:
		_shader_material.set_shader_parameter("protected_outline_tex", protected_outline_texture)

	var total_regions: int = preset.get_region_count()
	if total_regions <= 0:
		_shader_material.set_shader_parameter("region_enabled", false)
		_shader_material.set_shader_parameter("extra_region_count", 0)
		return

	var r0: Dictionary = preset.get_region(0)
	var r0_phase: float = _get_region_live_phase(0)
	_shader_material.set_shader_parameter("region_enabled", bool(r0.get("enabled", true)))
	_shader_material.set_shader_parameter("region_center", r0.get("center", Vector2(0.5, 0.48)))
	_shader_material.set_shader_parameter("region_radius", r0.get("radius", Vector2(0.16, 0.14)))
	_shader_material.set_shader_parameter("morph_direction", r0.get("direction", Vector2(0.0, -1.0)))
	_shader_material.set_shader_parameter("morph_strength", float(r0.get("strength", 0.018)))
	_shader_material.set_shader_parameter("scale_strength", float(r0.get("scale_strength", 0.04)))
	_shader_material.set_shader_parameter("falloff", float(r0.get("falloff", 1.5)))
	_shader_material.set_shader_parameter("phase", r0_phase)

	var extra_count: int = clampi(total_regions - 1, 0, 7)
	var centers: Array[Vector2] = []
	var radii: Array[Vector2] = []
	var offsets: Array[Vector2] = []
	var scales: Array[float] = []
	var falloffs: Array[float] = []

	for i in range(7):
		if i < extra_count:
			var reg: Dictionary = preset.get_region(i + 1)
			var is_on: bool = bool(reg.get("enabled", true))
			var reg_phase: float = _get_region_live_phase(i + 1) if is_on else 0.0
			var dir_v: Vector2 = reg.get("direction", Vector2(0.0, -1.0))
			var str_v: float = float(reg.get("strength", 0.018))
			var scl_v: float = float(reg.get("scale_strength", 0.04))

			centers.append(reg.get("center", Vector2(0.5, 0.5)))
			radii.append(reg.get("radius", Vector2(0.15, 0.15)))
			offsets.append(dir_v * str_v * reg_phase)
			scales.append(scl_v * reg_phase)
			falloffs.append(float(reg.get("falloff", 1.5)))
		else:
			centers.append(Vector2.ZERO)
			radii.append(Vector2(0.1, 0.1))
			offsets.append(Vector2.ZERO)
			scales.append(0.0)
			falloffs.append(1.5)

	_shader_material.set_shader_parameter("extra_region_count", extra_count)
	_shader_material.set_shader_parameter("extra_centers", centers)
	_shader_material.set_shader_parameter("extra_radii", radii)
	_shader_material.set_shader_parameter("extra_offsets", offsets)
	_shader_material.set_shader_parameter("extra_scales", scales)
	_shader_material.set_shader_parameter("extra_falloffs", falloffs)


func _draw() -> void:
	if _gizmo_overlay != null:
		_gizmo_overlay.queue_redraw()


func _on_gizmo_overlay_draw() -> void:
	if _sprite == null or _sprite.texture == null or preset == null:
		return

	var tex_size: Vector2 = get_texture_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return

	var top_left: Vector2 = -tex_size * 0.5 if _sprite.centered else Vector2.ZERO
	var inv_zoom: float = 1.0 / maxf(global_scale.x, 0.2)

	# 4단계: 자유형 마스크 오버레이 표시 (보호지우개: 빨간색, 변형브러시: 초록색, 안 칠한 곳: 투명)
	if show_mask_overlay and preset.freeform_mask_enabled and _mask_visual_texture != null:
		_gizmo_overlay.draw_texture_rect(_mask_visual_texture, Rect2(top_left, tex_size), false, Color.WHITE)

	if brush_preview_active:
		var b_center: Vector2 = top_left + brush_preview_uv * tex_size
		var b_r: float = brush_screen_radius * inv_zoom
		var b_rad: Vector2 = Vector2(b_r, b_r)
		var cur_col: Color = Color(1.0, 0.22, 0.28) if brush_is_eraser else Color(0.2, 1.0, 0.45)
		_draw_ellipse_filled(_gizmo_overlay, b_center, b_rad, Color(cur_col.r, cur_col.g, cur_col.b, 0.16))
		_draw_ellipse_outline(_gizmo_overlay, b_center, b_rad, Color(0.0, 0.0, 0.0, 0.85), 4.0 * inv_zoom, false)
		_draw_ellipse_outline(_gizmo_overlay, b_center, b_rad, cur_col, 2.2 * inv_zoom, false)
		_gizmo_overlay.draw_circle(b_center, 2.0 * inv_zoom, cur_col)

	if not show_debug_gizmo:
		return

	# 이미지 외곽 경계선 표시
	_gizmo_overlay.draw_rect(Rect2(top_left, tex_size), Color(1.0, 1.0, 1.0, 0.25), false, 1.2 * inv_zoom)

	var total_regions: int = preset.get_region_count()
	for idx in range(total_regions):
		var reg: Dictionary = preset.get_region(idx)
		var is_selected: bool = (idx == selected_region_index)
		var is_enabled: bool = bool(reg.get("enabled", true))

		var center_uv: Vector2 = reg.get("center", Vector2(0.5, 0.5))
		var radius_uv: Vector2 = reg.get("radius", Vector2(0.15, 0.15))
		var dir_vec: Vector2 = reg.get("direction", Vector2(0.0, -1.0))
		var strength_val: float = float(reg.get("strength", 0.018))
		var falloff_val: float = float(reg.get("falloff", 1.5))

		var center_px: Vector2 = top_left + center_uv * tex_size
		var radius_px: Vector2 = radius_uv * tex_size

		var main_color: Color
		if not is_enabled:
			main_color = Color(0.65, 0.65, 0.65, 0.65)
		elif is_selected:
			main_color = Color(0.15, 0.95, 1.0, 1.0)
		else:
			main_color = Color(0.45, 0.75, 1.0, 0.65)

		if is_selected and is_enabled:
			_draw_ellipse_filled(_gizmo_overlay, center_px, radius_px, Color(0.15, 0.95, 1.0, 0.10))

		# 어떤 밝기/색상의 그림 위에서도 잘 보이도록 어두운 외곽선 + 밝은 중심선 이중 렌더링
		_draw_ellipse_outline(
			_gizmo_overlay,
			center_px,
			radius_px,
			Color(0.05, 0.08, 0.12, 0.85 if is_selected else 0.5),
			(4.2 if is_selected else 2.6) * inv_zoom,
			false
		)
		_draw_ellipse_outline(
			_gizmo_overlay,
			center_px,
			radius_px,
			main_color,
			(2.4 if is_selected else 1.4) * inv_zoom,
			false
		)

		# 안쪽 감쇠(Falloff) 가이드 점선 타원
		var inner_ratio: float = clampf(pow(0.5, 1.0 / maxf(falloff_val, 0.2)), 0.15, 0.85)
		_draw_ellipse_outline(
			_gizmo_overlay,
			center_px,
			radius_px * inner_ratio,
			Color(main_color.r, main_color.g, main_color.b, main_color.a * 0.55),
			1.4 * inv_zoom,
			true
		)

		if not is_selected:
			_gizmo_overlay.draw_circle(center_px, 6.0 * inv_zoom, Color(0.05, 0.08, 0.12, 0.8))
			_gizmo_overlay.draw_circle(center_px, 4.5 * inv_zoom, main_color)
			continue

		# ====================================================================
		# 선택된 영역의 직접 조작 GUI 핸들 (캐릭터 그림 위에 선명하게 표시)
		# ====================================================================
		var handle_size: float = 7.0 * inv_zoom
		var active_or_hover: int = active_gizmo_part if active_gizmo_part != GizmoPart.NONE else hovered_gizmo_part

		# 1. 가로 반경 조절 핸들 (우측 네모 ■)
		var right_pt: Vector2 = center_px + Vector2(radius_px.x, 0.0)
		var rx_highlight: bool = (active_or_hover == GizmoPart.HANDLE_RADIUS_X)
		_draw_square_handle(
			_gizmo_overlay,
			right_pt,
			handle_size * (1.3 if rx_highlight else 1.0),
			Color(1.0, 1.0, 0.3) if rx_highlight else Color(0.2, 0.95, 1.0),
			inv_zoom
		)

		# 2. 세로 반경 조절 핸들 (하단 네모 ■)
		var bottom_pt: Vector2 = center_px + Vector2(0.0, radius_px.y)
		var ry_highlight: bool = (active_or_hover == GizmoPart.HANDLE_RADIUS_Y)
		_draw_square_handle(
			_gizmo_overlay,
			bottom_pt,
			handle_size * (1.3 if ry_highlight else 1.0),
			Color(1.0, 1.0, 0.3) if ry_highlight else Color(0.2, 0.95, 1.0),
			inv_zoom
		)

		# 3. 대각선 전체 크기 조절 핸들 (우하단 네모 ■)
		var corner_pt: Vector2 = center_px + Vector2(radius_px.x, radius_px.y) * 0.70710678
		var rxy_highlight: bool = (active_or_hover == GizmoPart.HANDLE_RADIUS_XY)
		_draw_square_handle(
			_gizmo_overlay,
			corner_pt,
			handle_size * (1.25 if rxy_highlight else 0.95),
			Color(1.0, 1.0, 0.3) if rxy_highlight else Color(0.65, 0.95, 1.0),
			inv_zoom
		)

		# 4. 변형 방향 및 강도 화살표 + 끝점 드래그 핸들 (노란 원 ●)
		var arrow_vec_px: Vector2 = dir_vec * (strength_val * tex_size * ARROW_VISUAL_SCALE)
		if arrow_vec_px.length() < 20.0:
			var fallback_dir: Vector2 = dir_vec.normalized() if dir_vec.length() > 0.01 else Vector2(0.0, -1.0)
			arrow_vec_px = fallback_dir * 20.0
		var tip_px: Vector2 = center_px + arrow_vec_px
		var arrow_highlight: bool = (active_or_hover == GizmoPart.HANDLE_ARROW_TIP)
		var arrow_col: Color = Color(1.0, 0.95, 0.25, 1.0) if arrow_highlight else Color(1.0, 0.80, 0.15, 1.0)

		_gizmo_overlay.draw_line(center_px, tip_px, Color(0.05, 0.08, 0.12, 0.9), 5.0 * inv_zoom, true)
		_gizmo_overlay.draw_line(center_px, tip_px, arrow_col, 3.0 * inv_zoom, true)
		var dir_n: Vector2 = arrow_vec_px.normalized()
		var perp: Vector2 = Vector2(-dir_n.y, dir_n.x)
		var head_len: float = 11.0 * inv_zoom
		_gizmo_overlay.draw_line(tip_px, tip_px - dir_n * head_len + perp * (head_len * 0.55), arrow_col, 2.8 * inv_zoom, true)
		_gizmo_overlay.draw_line(tip_px, tip_px - dir_n * head_len - perp * (head_len * 0.55), arrow_col, 2.8 * inv_zoom, true)

		# 화살표 끝 드래그 노브
		_gizmo_overlay.draw_circle(tip_px, (9.0 if arrow_highlight else 7.0) * inv_zoom, Color(0.08, 0.10, 0.14, 0.95))
		_gizmo_overlay.draw_circle(tip_px, (7.0 if arrow_highlight else 5.2) * inv_zoom, arrow_col)

		# 5. 실시간 호흡 움직임 위치 표시 점 (분홍/빨간 점)
		if is_enabled:
			var reg_phase: float = _get_region_live_phase(idx)
			var live_offset_px: Vector2 = dir_vec * (strength_val * reg_phase * tex_size * ARROW_VISUAL_SCALE)
			_gizmo_overlay.draw_circle(center_px + live_offset_px, 6.0 * inv_zoom, Color(0.08, 0.10, 0.14, 0.9))
			_gizmo_overlay.draw_circle(center_px + live_offset_px, 4.5 * inv_zoom, Color(1.0, 0.35, 0.5, 1.0))

		# 6. 중심 이동 핸들 (중앙 원 + 십자선)
		var center_highlight: bool = (active_or_hover == GizmoPart.CENTER_MOVE)
		var cross_len: float = 10.0 * inv_zoom
		_gizmo_overlay.draw_line(center_px - Vector2(cross_len, 0), center_px + Vector2(cross_len, 0), Color(0.05, 0.08, 0.12, 0.9), 3.6 * inv_zoom)
		_gizmo_overlay.draw_line(center_px - Vector2(0, cross_len), center_px + Vector2(0, cross_len), Color(0.05, 0.08, 0.12, 0.9), 3.6 * inv_zoom)
		_gizmo_overlay.draw_line(center_px - Vector2(cross_len, 0), center_px + Vector2(cross_len, 0), Color.WHITE, 2.0 * inv_zoom)
		_gizmo_overlay.draw_line(center_px - Vector2(0, cross_len), center_px + Vector2(0, cross_len), Color.WHITE, 2.0 * inv_zoom)
		_gizmo_overlay.draw_circle(center_px, (8.5 if center_highlight else 6.5) * inv_zoom, Color(0.08, 0.10, 0.14, 0.95))
		_gizmo_overlay.draw_circle(
			center_px,
			(6.5 if center_highlight else 4.8) * inv_zoom,
			Color(1.0, 0.95, 0.3) if center_highlight else Color(0.2, 0.95, 1.0)
		)


func _draw_square_handle(canvas: Node2D, pos: Vector2, half_size: float, fill_col: Color, inv_zoom: float) -> void:
	var r := Rect2(pos - Vector2(half_size, half_size), Vector2(half_size * 2.0, half_size * 2.0))
	canvas.draw_rect(r, Color(0.06, 0.08, 0.12, 0.95), true)
	canvas.draw_rect(r.grow(-1.6 * inv_zoom), fill_col, true)
	canvas.draw_rect(r, Color(1.0, 1.0, 1.0, 0.9), false, 1.3 * inv_zoom)


func _draw_ellipse_outline(
	canvas: Node2D,
	center: Vector2,
	radius: Vector2,
	color: Color,
	width: float = 1.5,
	dashed: bool = false
) -> void:
	const SEGMENTS: int = 64
	var pts := PackedVector2Array()
	pts.resize(SEGMENTS + 1)
	for i in range(SEGMENTS + 1):
		var angle: float = float(i) / float(SEGMENTS) * TAU
		pts[i] = center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y)

	if not dashed:
		canvas.draw_polyline(pts, color, width, true)
	else:
		for i in range(0, SEGMENTS, 2):
			canvas.draw_line(pts[i], pts[i + 1], color, width, true)


func _draw_ellipse_filled(canvas: Node2D, center: Vector2, radius: Vector2, color: Color) -> void:
	const SEGMENTS: int = 48
	var pts := PackedVector2Array()
	pts.resize(SEGMENTS)
	for i in range(SEGMENTS):
		var angle: float = float(i) / float(SEGMENTS) * TAU
		pts[i] = center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y)
	canvas.draw_colored_polygon(pts, color)
