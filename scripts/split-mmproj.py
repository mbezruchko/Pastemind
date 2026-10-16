"""Splits EmbeddingGemma 2's mmproj into its two encoders, one file each, so the image encoder (226 MB) needn't come
with the audio one (328 MB) that few will use.

    python3 scripts/split-mmproj.py <mmproj-embeddinggemma-2-Q8_0.gguf> <out dir>

Writes mmproj-embeddinggemma-2-vision-Q8_0.gguf (v.* and mm.input_projection) and
mmproj-embeddinggemma-2-audio-Q8_0.gguf (a.* and mm.a.input_projection), each with the other encoder's metadata left
out and its has_*_encoder flag off. Tensors are copied byte for byte. Uses llama.cpp's gguf-py (Vendor/llama.cpp).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Vendor/llama.cpp/gguf-py"))
import gguf  # noqa: E402

PARTS = {
    "vision": {"tensors": ("v.", "mm.input_projection."), "drop": "clip.audio.", "off": "clip.has_audio_encoder"},
    "audio": {"tensors": ("a.", "mm.a."), "drop": "clip.vision.", "off": "clip.has_vision_encoder"},
}


def split(source: Path, out: Path, part: str) -> Path:
    spec = PARTS[part]
    reader = gguf.GGUFReader(source)
    target = out / source.name.replace("mmproj-embeddinggemma-2-", f"mmproj-embeddinggemma-2-{part}-")
    arch = reader.fields[gguf.Keys.General.ARCHITECTURE].contents()
    writer = gguf.GGUFWriter(target, arch=arch, endianess=reader.endianess)
    for field in reader.fields.values():
        if field.name == gguf.Keys.General.ARCHITECTURE or field.name.startswith("GGUF."):
            continue
        if field.name.startswith(spec["drop"]):
            continue
        value_type = field.types[0]
        sub_type = field.types[-1] if value_type == gguf.GGUFValueType.ARRAY else None
        value = False if field.name == spec["off"] else field.contents()
        writer.add_key_value(field.name, value, value_type, sub_type=sub_type)
    kept = [t for t in reader.tensors if t.name.startswith(spec["tensors"])]
    for tensor in kept:
        writer.add_tensor_info(tensor.name, tensor.data.shape, tensor.data.dtype, tensor.data.nbytes, tensor.tensor_type)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_ti_data_to_file()
    for tensor in kept:
        writer.write_tensor_data(tensor.data, tensor_endianess=reader.endianess)
    writer.close()
    print(f"{target.name}: {len(kept)} tensors, {target.stat().st_size / 1e6:.0f} MB")
    return target


if __name__ == "__main__":
    source, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for part in PARTS:
        split(source, out, part)
