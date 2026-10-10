class_name GifExporter
extends RefCounted
## 외부 플러그인 없이 순수 GDScript로 동작하는 GIF89a 애니메이션 인코더.
## 이미지에 맞춰 만든 적응형 255색 팔레트(Median Cut) + 투명 배경(Index 255) +
## 무한 반복(NETSCAPE2.0) + LZW 압축을 지원합니다.
## 계산량이 많으므로 Thread에서 호출해도 안전하도록 씬 노드에 접근하지 않습니다.

const CLEAR_CODE: int = 256
const EOI_CODE: int = 257
const TRANSPARENT_INDEX: int = 255
const ALPHA_THRESHOLD: int = 128


## Image 배열을 받아 움직이는 GIF89a 파일로 저장합니다.
## delay_centiseconds: 프레임당 지연 시간 (1/100초 단위, 예: 5 = 50ms = 20FPS)
## progress: 비어있지 않은 Array를 넘기면 progress[0]에 '인코딩 완료한 프레임 수'를 기록합니다.
static func save_animated_gif(
	file_path: String,
	frames: Array[Image],
	delay_centiseconds: int = 5,
	progress: Array = []
) -> Error:
	if frames.is_empty():
		return ERR_INVALID_PARAMETER

	var first_img: Image = frames[0]
	var width: int = first_img.get_width()
	var height: int = first_img.get_height()
	if width <= 0 or height <= 0:
		return ERR_INVALID_PARAMETER

	# 모든 프레임을 동일 크기 RGBA8로 정규화
	var prepared: Array[Image] = []
	for frame in frames:
		var img: Image = frame
		if img.get_width() != width or img.get_height() != height:
			img = img.duplicate() as Image
			img.resize(width, height, Image.INTERPOLATE_LANCZOS)
		if img.get_format() != Image.FORMAT_RGBA8:
			img = img.duplicate() as Image
			img.convert(Image.FORMAT_RGBA8)
		prepared.append(img)

	if progress.size() > 0:
		progress[0] = 0

	var out := PackedByteArray()

	# 1. GIF89a 헤더
	out.append_array("GIF89a".to_ascii_buffer())

	# 2. Logical Screen Descriptor
	_append_u16_le(out, width)
	_append_u16_le(out, height)
	out.append(0xF7) # Global Color Table(1) | Color Res(7) | Sort(0) | Size(7 -> 256 colors)
	out.append(TRANSPARENT_INDEX)
	out.append(0)

	# 3. Global Color Table: 모든 프레임에서 추출한 적응형 팔레트
	var pal_info: Dictionary = _build_adaptive_palette(prepared, width, height)
	var palette: PackedByteArray = pal_info["bytes"]
	var pal_count: int = pal_info["count"]
	out.append_array(palette)

	# 4. NETSCAPE2.0 무한 루프 확장 블록
	out.append_array(PackedByteArray([
		0x21, 0xFF, 0x0B,
		0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30,
		0x03, 0x01, 0x00, 0x00, 0x00
	]))

	var lzw_table := PackedInt32Array()
	lzw_table.resize(4096 * 256)

	var color_lut := PackedInt32Array()
	color_lut.resize(262144)
	color_lut.fill(-1)

	# 5. 각 프레임 인코딩
	var delay_cs: int = maxi(2, delay_centiseconds)
	for fi in range(prepared.size()):
		var img2: Image = prepared[fi]

		# Graphic Control Extension (Disposal 2 + Transparent Flag)
		out.append_array(PackedByteArray([0x21, 0xF9, 0x04, 0x09]))
		_append_u16_le(out, delay_cs)
		out.append(TRANSPARENT_INDEX)
		out.append(0x00)

		# Image Descriptor
		out.append(0x2C)
		_append_u16_le(out, 0)
		_append_u16_le(out, 0)
		_append_u16_le(out, width)
		_append_u16_le(out, height)
		out.append(0x00)

		var indexed_pixels: PackedByteArray = _quantize_frame(img2, width, height, palette, pal_count, color_lut)

		out.append(0x08) # LZW Minimum Code Size
		var compressed: PackedByteArray = _lzw_encode_8bit(indexed_pixels, lzw_table)
		_append_sub_blocks(out, compressed)

		if progress.size() > 0:
			progress[0] = fi + 1

	# 6. Trailer
	out.append(0x3B)

	var dir_path: String = file_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(out)
	file.close()
	return OK


## 모든 프레임의 색 분포(5비트 히스토그램)에 Median Cut을 적용해 최대 255색 팔레트를 만듭니다.
static func _build_adaptive_palette(frames: Array[Image], width: int, height: int) -> Dictionary:
	var cnt := PackedInt32Array()
	var sum_r := PackedInt32Array()
	var sum_g := PackedInt32Array()
	var sum_b := PackedInt32Array()
	cnt.resize(32768)
	sum_r.resize(32768)
	sum_g.resize(32768)
	sum_b.resize(32768)

	var total_px: int = width * height
	var stride: int = maxi(1, (total_px * frames.size()) / 400000)
	if stride > 1 and stride % 2 == 0:
		stride += 1

	for img in frames:
		var raw: PackedByteArray = img.get_data()
		var p: int = 0
		while p < total_px:
			var base: int = p * 4
			if raw[base + 3] >= ALPHA_THRESHOLD:
				var r: int = raw[base]
				var g: int = raw[base + 1]
				var b: int = raw[base + 2]
				var key: int = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
				cnt[key] += 1
				sum_r[key] += r
				sum_g[key] += g
				sum_b[key] += b
			p += stride

	var all_keys: Array = []
	var total_pop: int = 0
	for k in range(32768):
		if cnt[k] > 0:
			all_keys.append(k)
			total_pop += cnt[k]

	var result := PackedByteArray()
	result.resize(256 * 3)
	result.fill(0)
	if all_keys.is_empty():
		return {"bytes": result, "count": 0}

	var boxes: Array = [all_keys]
	var pops: Array = [total_pop]

	while boxes.size() < 255:
		var best: int = -1
		var best_pop: int = 0
		for i in range(boxes.size()):
			if (boxes[i] as Array).size() > 1 and int(pops[i]) > best_pop:
				best = i
				best_pop = int(pops[i])
		if best == -1:
			break

		var box: Array = boxes[best]
		var rmin: int = 31
		var rmax: int = 0
		var gmin: int = 31
		var gmax: int = 0
		var bmin: int = 31
		var bmax: int = 0
		for key in box:
			var kr: int = (int(key) >> 10) & 31
			var kg: int = (int(key) >> 5) & 31
			var kb: int = int(key) & 31
			rmin = mini(rmin, kr)
			rmax = maxi(rmax, kr)
			gmin = mini(gmin, kg)
			gmax = maxi(gmax, kg)
			bmin = mini(bmin, kb)
			bmax = maxi(bmax, kb)

		var r_range: int = rmax - rmin
		var g_range: int = gmax - gmin
		var b_range: int = bmax - bmin
		var shift: int = 5
		if r_range >= g_range and r_range >= b_range:
			shift = 10
		elif b_range > g_range:
			shift = 0

		box.sort_custom(func(a: int, b: int) -> bool:
			return ((a >> shift) & 31) < ((b >> shift) & 31)
		)

		var half: int = best_pop / 2
		var acc: int = 0
		var split_i: int = 1
		for i in range(box.size()):
			acc += cnt[int(box[i])]
			if acc >= half:
				split_i = clampi(i + 1, 1, box.size() - 1)
				break

		var part_a: Array = box.slice(0, split_i)
		var part_b: Array = box.slice(split_i)
		var pop_a: int = 0
		for key in part_a:
			pop_a += cnt[int(key)]
		boxes[best] = part_a
		pops[best] = pop_a
		boxes.append(part_b)
		pops.append(best_pop - pop_a)

	for i in range(boxes.size()):
		var sr: int = 0
		var sg: int = 0
		var sb: int = 0
		var pop: int = 0
		for key in (boxes[i] as Array):
			var kk: int = int(key)
			sr += sum_r[kk]
			sg += sum_g[kk]
			sb += sum_b[kk]
			pop += cnt[kk]
		pop = maxi(pop, 1)
		result[i * 3] = clampi(int(round(float(sr) / float(pop))), 0, 255)
		result[i * 3 + 1] = clampi(int(round(float(sg) / float(pop))), 0, 255)
		result[i * 3 + 2] = clampi(int(round(float(sb) / float(pop))), 0, 255)

	return {"bytes": result, "count": boxes.size()}


static func _quantize_frame(
	img: Image,
	width: int,
	height: int,
	palette: PackedByteArray,
	pal_count: int,
	lut: PackedInt32Array
) -> PackedByteArray:
	var raw: PackedByteArray = img.get_data()
	var total_px: int = width * height
	var result := PackedByteArray()
	result.resize(total_px)

	for p in range(total_px):
		var base: int = p * 4
		if raw[base + 3] < ALPHA_THRESHOLD or pal_count <= 0:
			result[p] = TRANSPARENT_INDEX
			continue
		var r: int = raw[base]
		var g: int = raw[base + 1]
		var b: int = raw[base + 2]
		var key: int = ((r >> 2) << 12) | ((g >> 2) << 6) | (b >> 2)
		var idx: int = lut[key]
		if idx < 0:
			idx = _nearest_palette_index(r, g, b, palette, pal_count)
			lut[key] = idx
		result[p] = idx

	return result


static func _nearest_palette_index(r: int, g: int, b: int, palette: PackedByteArray, pal_count: int) -> int:
	var best_i: int = 0
	var best_d: int = 1 << 30
	for i in range(pal_count):
		var dr: int = r - palette[i * 3]
		var dg: int = g - palette[i * 3 + 1]
		var db: int = b - palette[i * 3 + 2]
		var d: int = 2 * dr * dr + 4 * dg * dg + 3 * db * db
		if d < best_d:
			best_d = d
			best_i = i
			if d == 0:
				break
	return best_i


static func _lzw_encode_8bit(indices: PackedByteArray, table: PackedInt32Array) -> PackedByteArray:
	var out := PackedByteArray()
	if indices.is_empty():
		return out

	table.fill(-1)
	var code_size: int = 9
	var next_code: int = 258

	var bit_buf: int = 0
	var bit_cnt: int = 0

	# 시작 CLEAR_CODE 기록
	bit_buf |= (CLEAR_CODE << bit_cnt)
	bit_cnt += code_size
	while bit_cnt >= 8:
		out.append(bit_buf & 0xFF)
		bit_buf >>= 8
		bit_cnt -= 8

	var prefix: int = indices[0]
	var count: int = indices.size()

	for i in range(1, count):
		var k: int = indices[i]
		var key: int = (prefix << 8) | k
		var hit: int = table[key]
		if hit != -1:
			prefix = hit
		else:
			bit_buf |= (prefix << bit_cnt)
			bit_cnt += code_size
			while bit_cnt >= 8:
				out.append(bit_buf & 0xFF)
				bit_buf >>= 8
				bit_cnt -= 8

			table[key] = next_code
			if next_code == (1 << code_size) and code_size < 12:
				code_size += 1
			next_code += 1

			if next_code >= 4096:
				bit_buf |= (CLEAR_CODE << bit_cnt)
				bit_cnt += code_size
				while bit_cnt >= 8:
					out.append(bit_buf & 0xFF)
					bit_buf >>= 8
					bit_cnt -= 8
				table.fill(-1)
				code_size = 9
				next_code = 258

			prefix = k

	bit_buf |= (prefix << bit_cnt)
	bit_cnt += code_size
	while bit_cnt >= 8:
		out.append(bit_buf & 0xFF)
		bit_buf >>= 8
		bit_cnt -= 8

	bit_buf |= (EOI_CODE << bit_cnt)
	bit_cnt += code_size
	while bit_cnt >= 8:
		out.append(bit_buf & 0xFF)
		bit_buf >>= 8
		bit_cnt -= 8

	if bit_cnt > 0:
		out.append(bit_buf & 0xFF)

	return out


static func _append_sub_blocks(out: PackedByteArray, data: PackedByteArray) -> void:
	var pos: int = 0
	var total: int = data.size()
	while pos < total:
		var chunk_len: int = mini(255, total - pos)
		out.append(chunk_len)
		out.append_array(data.slice(pos, pos + chunk_len))
		pos += chunk_len
	out.append(0x00)


static func _append_u16_le(out: PackedByteArray, val: int) -> void:
	out.append(val & 0xFF)
	out.append((val >> 8) & 0xFF)
