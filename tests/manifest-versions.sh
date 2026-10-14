#!/usr/bin/env bash
# CI-гейт: запись плагина в .claude-plugin/marketplace.json согласована с его
# integrations/<plugin>/.claude-plugin/plugin.json.
#
# Зачем: версия — это ключ кеша установки (~/.claude/plugins/cache/<marketplace>/
# <plugin>/<version>/). Каталог маркетплейса говорит, что зарелизено, а plugin.json
# лежит внутри плагина, и правят их разными коммитами. Расхождение молча делает
# ответ на вопрос «какая версия зарелизена» неверным: установка не падает, просто
# каталог рекламирует не то. К сентябрю 2026 так разъехались семь плагинов, самое
# старое расхождение — с апреля.
#
# Пару «запись каталога ↔ plugin.json» гейт ищет по имени, поэтому имя и проверяется
# первым: plugin.json.name должен совпадать с именем каталога, а source записи —
# указывать на ./integrations/<name>. Иначе опечатка в имени уводит пару из-под
# сверки версий и выглядит безобидным warning'ом «не опубликован».
#
# Плагин, которого нет в каталоге, — предупреждение, а не провал: непубликация
# бывает намеренной, и решают это владельцы плагина, а не этот гейт.
#
# Любой провал → exit≠0 → CI красный.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - <<'PY'
import glob
import json
import os
import sys

with open(".claude-plugin/marketplace.json", encoding="utf-8") as f:
    entries = json.load(f)["plugins"]
catalog = {p["name"]: p.get("version") for p in entries}

mismatched, unpublished, misnamed = [], [], []
for path in sorted(glob.glob("integrations/*/.claude-plugin/plugin.json")):
    with open(path, encoding="utf-8") as f:
        plugin = json.load(f)
    name, version, directory = plugin["name"], plugin.get("version"), path.split("/")[1]
    if name != directory:
        misnamed.append((name, directory, path))
    if name not in catalog:
        unpublished.append((name, version, path))
    elif catalog[name] != version:
        mismatched.append((name, catalog[name], version, path))

orphaned, mis_sourced = [], []
for entry in entries:
    name, source = entry["name"], entry.get("source")
    if not os.path.isfile(f"integrations/{name}/.claude-plugin/plugin.json"):
        orphaned.append((name, source))
    elif source != f"./integrations/{name}":
        mis_sourced.append((name, source))

for name, version, path in unpublished:
    print(f"warning: {name} {version} нет в каталоге ({path}) — "
          f"добавьте в marketplace.json или оставьте, если не публикуется")

def block(header, lines, hint):
    print()
    print(header)
    for line in lines:
        print(f"  {line}")
    print()
    print(hint)

if misnamed:
    block("Имя в plugin.json не совпадает с каталогом плагина:",
          [f"{path}: name {name} / каталог {directory}"
           for name, directory, path in misnamed],
          "Переименуйте name или каталог. По имени ищется пара в marketplace.json —\n"
          "пока они разойдутся, версия плагина не сверяется вовсе.")

if orphaned:
    block("В каталоге есть запись, но plugin.json у неё нет:",
          [f"{name}: source {source} → integrations/{name}/.claude-plugin/plugin.json не найден"
           for name, source in orphaned],
          "Опечатка в name или плагин удалён из репозитория, а запись осталась.\n"
          "Поправьте имя или уберите запись из marketplace.json.")

if mis_sourced:
    block("source записи каталога ведёт не в каталог плагина:",
          [f"{name}: source {source}, ожидали ./integrations/{name}"
           for name, source in mis_sourced],
          "Каталог рекламирует одно имя, а ставит другой каталог. Приведите source\n"
          "к ./integrations/<name>.")

if mismatched:
    block("Версии разошлись между каталогом и плагином:",
          [f"{name}: marketplace.json {cat_v} / plugin.json {plug_v}  ({path})"
           for name, cat_v, plug_v, path in mismatched],
          "Приведите обе записи к одной версии. Если непонятно, какая верна, —\n"
          "берите бо́льшую: на неё уже могли завязаться установки, а понижение\n"
          "версии не доедет до тех, у кого стоит старшая.")

if misnamed or orphaned or mis_sourced or mismatched:
    sys.exit(1)

print(f"манифесты согласованы: проверено плагинов — {len(catalog)}, "
      f"не опубликовано — {len(unpublished)}")
PY
