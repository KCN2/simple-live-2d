class_name MorphPreset
extends RefCounted
## 캐릭터 국소 변형(Morph) 설정을 관리하고 JSON으로 직렬화/역직렬화하는 프리셋 클래스.
## 모든 영역 좌표와 반경은 이미지 해상도와 무관하도록 정규화 UV 좌표(0.0 ~ 1.0)를 사용합니다.
## 4단계(다중 영역·영역별 감쇠 스프링·자유형 마스크) 및 5단계(3레이어 합성 보정) 설정을 포함합니다.

const FORMAT_VERSION: int = 2
const MAX_REGIONS: int = 8

var preset_name: String = "Default Breathing"
var breathing_speed: float = 1.2
var breathing_amplitude: float = 1.0
var outline_protect: float = 0.5

# 4단계: 감쇠 스프링 및 자유형 마스크 설정
var spring_enabled: bool = false
var spring_stiffness: float = 140.0
var spring_damping: float = 10.0
var freeform_mask_enabled: bool = false
var freeform_mask_base64: String = ""

# 5단계: 확장 모드(레이어 합성: 1.원본 몸체 + 2.변형 파츠 + 3.보호 외곽선) 설정
var layer_composite_enabled: bool = false
## 원본 몸체와 변형 파츠 중복 시 발생하는 밑그림 비침/이중선 제거 보정 강도 (0.0 ~ 1.0)
var ghost_suppress: float = 0.85
## 보호 외곽선 레이어가 변형량을 따라가는 비율 (0.0 = 완전 고정, 1.0 = 파츠와 함께 이동)
var outline_follow_ratio: float = 0.65

## 각 원소는 다음 키를 가지는 Dictionary:
## - name: String (영역 이름)
## - enabled: bool (활성화 여부)
## - center: Vector2 (정규화 중심 UV 0.0 ~ 1.0)
## - radius: Vector2 (정규화 가로/세로 반경 0.01 ~ 0.8)
## - direction: Vector2 (변형 이동 방향 벡터 -1.0 ~ 1.0)
## - strength: float (UV 이동 변형 강도 0.0 ~ 0.2)
## - scale_strength: float (방사형 팽창/수축 강도 -0.5 ~ 0.5)
## - falloff: float (가장자리 감쇠 곡선 지수 0.2 ~ 5.0)
## - phase_offset: float (영역별 사인파 위상 지연 라디안 -PI ~ PI)
## - spring_weight: float (영역별 탄성 관성 배율 0.2 ~ 3.0)
var regions: Array[Dictionary] = []


func _init() -> void:
	reset_to_default()


## 기본 호흡 프리셋 상태로 초기화합니다.
func reset_to_default() -> void:
	preset_name = "Default Breathing"
	breathing_speed = 1.2
	breathing_amplitude = 1.0
	outline_protect = 0.5
	spring_enabled = false
	spring_stiffness = 140.0
	spring_damping = 10.0
	freeform_mask_enabled = false
	freeform_mask_base64 = ""
	layer_composite_enabled = false
	ghost_suppress = 0.85
	outline_follow_ratio = 0.65
	regions.clear()
	regions.append(create_default_region("호흡/흉부 영역 1", Vector2(0.5, 0.48), Vector2(0.16, 0.14)))


## 새 기본 변형 영역 Dictionary를 생성합니다.
static func create_default_region(
	region_name: String = "변형 영역",
	center_uv: Vector2 = Vector2(0.5, 0.5),
	radius_uv: Vector2 = Vector2(0.15, 0.15)
) -> Dictionary:
	return {
		"name": region_name,
		"enabled": true,
		"center": center_uv.clamp(Vector2.ZERO, Vector2.ONE),
		"radius": radius_uv.clamp(Vector2(0.01, 0.01), Vector2(0.8, 0.8)),
		"direction": Vector2(0.0, -1.0),
		"strength": 0.018,
		"scale_strength": 0.04,
		"falloff": 1.5,
		"phase_offset": 0.0,
		"spring_weight": 1.0,
	}


## 영역 개수를 반환합니다.
func get_region_count() -> int:
	return regions.size()


## 지정한 인덱스의 영역 데이터를 반환합니다.
func get_region(index: int) -> Dictionary:
	if regions.is_empty():
		regions.append(create_default_region())
	var safe_idx: int = clampi(index, 0, regions.size() - 1)
	return regions[safe_idx]


## 새로운 영역을 추가하고 추가된 인덱스를 반환합니다.
func add_region(custom_name: String = "") -> int:
	if regions.size() >= MAX_REGIONS:
		return regions.size() - 1
	var idx: int = regions.size() + 1
	var r_name: String = custom_name if not custom_name.is_empty() else "변형 영역 %d" % idx
	var offset_y: float = clampf(0.35 + float(regions.size()) * 0.1, 0.15, 0.85)
	var reg := create_default_region(r_name, Vector2(0.5, offset_y), Vector2(0.14, 0.12))
	reg["phase_offset"] = clampf(-0.45 * float(regions.size()), -PI, PI)
	reg["spring_weight"] = clampf(1.0 + 0.2 * float(regions.size()), 0.2, 3.0)
	regions.append(reg)
	return regions.size() - 1


## 지정한 인덱스의 영역을 삭제합니다 (최소 1개 영역은 유지).
func remove_region(index: int) -> void:
	if regions.size() <= 1:
		regions[0] = create_default_region("호흡/흉부 영역 1")
		return
	if index >= 0 and index < regions.size():
		regions.remove_at(index)


## 복제본을 생성하여 반환합니다.
func duplicate_preset() -> MorphPreset:
	var copy := MorphPreset.new()
	copy.from_dict(to_dict())
	return copy


## 프리셋 데이터를 JSON 호환 Dictionary로 변환합니다.
func to_dict() -> Dictionary:
	var serialized_regions: Array[Dictionary] = []
	for reg in regions:
		var c: Vector2 = reg.get("center", Vector2(0.5, 0.5))
		var r: Vector2 = reg.get("radius", Vector2(0.15, 0.15))
		var d: Vector2 = reg.get("direction", Vector2(0.0, -1.0))
		serialized_regions.append({
			"name": String(reg.get("name", "변형 영역")),
			"enabled": bool(reg.get("enabled", true)),
			"center": {"x": snappedf(c.x, 0.0001), "y": snappedf(c.y, 0.0001)},
			"radius": {"x": snappedf(r.x, 0.0001), "y": snappedf(r.y, 0.0001)},
			"direction": {"x": snappedf(d.x, 0.0001), "y": snappedf(d.y, 0.0001)},
			"strength": snappedf(float(reg.get("strength", 0.018)), 0.0001),
			"scale_strength": snappedf(float(reg.get("scale_strength", 0.04)), 0.0001),
			"falloff": snappedf(float(reg.get("falloff", 1.5)), 0.001),
			"phase_offset": snappedf(float(reg.get("phase_offset", 0.0)), 0.001),
			"spring_weight": snappedf(float(reg.get("spring_weight", 1.0)), 0.01),
		})

	var result: Dictionary = {
		"version": FORMAT_VERSION,
		"preset_name": preset_name,
		"breathing_speed": snappedf(breathing_speed, 0.001),
		"breathing_amplitude": snappedf(breathing_amplitude, 0.001),
		"outline_protect": snappedf(outline_protect, 0.001),
		"spring_enabled": spring_enabled,
		"spring_stiffness": snappedf(spring_stiffness, 0.01),
		"spring_damping": snappedf(spring_damping, 0.01),
		"freeform_mask_enabled": freeform_mask_enabled,
		"layer_composite_enabled": layer_composite_enabled,
		"ghost_suppress": snappedf(ghost_suppress, 0.001),
		"outline_follow_ratio": snappedf(outline_follow_ratio, 0.001),
		"regions": serialized_regions,
	}
	if not freeform_mask_base64.is_empty():
		result["freeform_mask_base64"] = freeform_mask_base64
	return result


## Dictionary로부터 프리셋 설정을 복원합니다.
func from_dict(data: Dictionary) -> void:
	preset_name = String(data.get("preset_name", "Default Breathing"))
	breathing_speed = clampf(float(data.get("breathing_speed", 1.2)), 0.05, 10.0)
	breathing_amplitude = clampf(float(data.get("breathing_amplitude", 1.0)), 0.0, 3.0)
	outline_protect = clampf(float(data.get("outline_protect", 0.5)), 0.0, 1.0)
	spring_enabled = bool(data.get("spring_enabled", false))
	spring_stiffness = clampf(float(data.get("spring_stiffness", 140.0)), 10.0, 500.0)
	spring_damping = clampf(float(data.get("spring_damping", 10.0)), 0.5, 50.0)
	freeform_mask_enabled = bool(data.get("freeform_mask_enabled", false))
	freeform_mask_base64 = String(data.get("freeform_mask_base64", ""))
	layer_composite_enabled = bool(data.get("layer_composite_enabled", false))
	ghost_suppress = clampf(float(data.get("ghost_suppress", 0.85)), 0.0, 1.0)
	outline_follow_ratio = clampf(float(data.get("outline_follow_ratio", 0.65)), 0.0, 1.0)

	regions.clear()
	var raw_regions: Variant = data.get("regions", [])
	if raw_regions is Array:
		for item in raw_regions:
			if item is Dictionary and regions.size() < MAX_REGIONS:
				var center_uv := _parse_vec2(item.get("center"), Vector2(0.5, 0.5))
				var radius_uv := _parse_vec2(item.get("radius"), Vector2(0.15, 0.15))
				var dir_vec := _parse_vec2(item.get("direction"), Vector2(0.0, -1.0))
				regions.append({
					"name": String(item.get("name", "변형 영역 %d" % (regions.size() + 1))),
					"enabled": bool(item.get("enabled", true)),
					"center": center_uv.clamp(Vector2.ZERO, Vector2.ONE),
					"radius": radius_uv.clamp(Vector2(0.01, 0.01), Vector2(0.8, 0.8)),
					"direction": dir_vec.clamp(Vector2(-1.0, -1.0), Vector2(1.0, 1.0)),
					"strength": clampf(float(item.get("strength", 0.018)), 0.0, 0.2),
					"scale_strength": clampf(float(item.get("scale_strength", 0.04)), -0.5, 0.5),
					"falloff": clampf(float(item.get("falloff", 1.5)), 0.2, 5.0),
					"phase_offset": clampf(float(item.get("phase_offset", 0.0)), -PI, PI),
					"spring_weight": clampf(float(item.get("spring_weight", 1.0)), 0.2, 3.0),
				})

	if regions.is_empty():
		regions.append(create_default_region("호흡/흉부 영역 1", Vector2(0.5, 0.48), Vector2(0.16, 0.14)))


## JSON 파일로 프리셋을 저장합니다.
func save_to_json(file_path: String) -> Error:
	var dir_path: String = file_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	var json_str: String = JSON.stringify(to_dict(), "\t")
	file.store_string(json_str)
	file.close()
	return OK


## JSON 파일에서 프리셋을 불러옵니다.
func load_from_json(file_path: String) -> Error:
	if not FileAccess.file_exists(file_path):
		return ERR_FILE_NOT_FOUND

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()

	var text: String = file.get_as_text()
	file.close()

	var json := JSON.new()
	var err: Error = json.parse(text)
	if err != OK:
		return err

	if json.data is Dictionary:
		from_dict(json.data)
		return OK
	return ERR_INVALID_DATA


static func _parse_vec2(val: Variant, fallback: Vector2) -> Vector2:
	if val is Vector2:
		return val
	if val is Dictionary:
		return Vector2(float(val.get("x", fallback.x)), float(val.get("y", fallback.y)))
	if val is Array and val.size() >= 2:
		return Vector2(float(val[0]), float(val[1]))
	return fallback
