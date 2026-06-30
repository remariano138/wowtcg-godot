import json
from pathlib import Path

JSON_PATH = Path(__file__).parent.parent / "Tools" / "PNJfromTTSmod" / "2236124562.json"
OUTPUT_PATH = Path(__file__).parent / "unique_face_urls.txt"


def collect_face_urls(obj, found: set):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == "FaceURL" and isinstance(value, str):
                found.add(value)
            else:
                collect_face_urls(value, found)
    elif isinstance(obj, list):
        for item in obj:
            collect_face_urls(item, found)


with open(JSON_PATH, encoding="utf-8") as f:
    data = json.load(f)

face_urls: set = set()
collect_face_urls(data, face_urls)

sorted_urls = sorted(face_urls)

print(f"Unique FaceURLs found: {len(sorted_urls)}")
for url in sorted_urls:
    print(url)

OUTPUT_PATH.write_text("\n".join(sorted_urls) + "\n", encoding="utf-8")
print(f"\nWritten to {OUTPUT_PATH}")
