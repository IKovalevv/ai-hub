#!/bin/bash
# Buildin Pages — операции со страницами и блоками через UI API
# Usage: ./buildin-pages.sh <command> [args...]
#
# Принимает page_id как UUID или URL:
#   ./buildin-pages.sh read <page_id>
#   ./buildin-pages.sh read https://buildin.ai/<space_id>/<page_id>
#
# Commands:
#   get <page_id>                          — получить страницу (JSON, все блоки)
#   title <page_id>                        — получить заголовок страницы
#   read <page_id>                         — прочитать страницу как markdown
#   create <parent_page_id> <title>        — создать дочернюю страницу
#   update <page_id> <title>               — обновить заголовок страницы
#   archive <page_id>                      — архивировать страницу (status: -1)
#   get-blocks <page_id>                   — получить блоки страницы (JSON)
#   comments <page_id|url[#block_id]> [block_id] — комментарии страницы или конкретного блока
#                                                  (URL с якорем #block-uuid фильтрует по блоку)
#   comment <page_id|url[#block_id]> [block_id] <anchor> <text>
#           [--dry-run] [--occurrence=N] [--rollback-out=<path>] [--mention=<user_uuid>]...
#                                                — создать комментарий к фразе <anchor> внутри блока
#                                                  <anchor>/<text>: строка, «@путь» — файл, «-» — stdin
#                                                  («@@текст» — литеральный «@текст»; значение с ведущими
#                                                   дефисами — после разделителя «--»)
#                                                  якорь должен быть однозначен: несколько вхождений —
#                                                  отказ, нужное выбирается через --occurrence=N
#                                                  только прозаические блоки (абзац, списки, заголовок,
#                                                  цитата, callout) — у картинки, таблицы и кода
#                                                  подсветки не будет, поэтому отказ
#                                                  дату и инлайн-формулу внутри блока — только
#                                                  целиком: разрез формулу ломает
#                                                  --mention — @-упоминание участника в начале текста
#                                                  (можно несколько; uuid сверяется с участниками)
#   comment-reply <page_id|url> <discussion_id> <text> [--dry-run] [--rollback-out=<path>]
#                 [--mention=<user_uuid>]...
#                                                — ответить в тред; <text> и --mention — как у comment;
#                                                  в закрытый тред — отказ, сначала comment-unresolve
#   comment-resolve <page_id|url> <discussion_id> [--dry-run]
#                                                — закрыть тред (резолв); уже закрытый — без записи
#   comment-unresolve <page_id|url> <discussion_id> [--dry-run]
#                                                — открыть закрытый тред заново
#   comment-rollback <file> [--narrow]           — применить файл отката comment/comment-reply;
#                                                  файл становится <file>.applied, повтор — отказ;
#                                                  блок меняли после комментария — полный откат
#                                                  отвергается, --narrow снимает только свой тред
#   publish-md <page_id> <file.md> [--replace]          — опубликовать markdown-файл
#                                                        (по умолчанию дописывает в конец;
#                                                         --replace заменяет содержимое)
#   append-blocks <page_id> <json_blocks>              — добавить блоки на страницу (transaction)
#                                                        блоки могут иметь "children" (таблицы/toggle/вложенные списки)
#   insert-blocks-after <page_id> <after_block_id> <json_blocks>   — вставить блоки после конкретного блока
#   insert-blocks-before <page_id> <before_block_id> <json_blocks> — вставить блоки перед конкретным блоком
#                                                        (block_id берётся из поля "uuid" в выводе get-blocks)
#   append-text <page_id> <text>                       — добавить текстовый параграф
#   append-image <page_id> <image_file> [caption]      — загрузить картинку в S3 Buildin и добавить image-блок
#                                                        (JPEG: размеры из SOF, EXIF Orientation не учитывается)
#   delete-block <block_id> <parent_id>                — удалить блок

# pipefail обязателен вместе с JSON-отказом из buildin.sh: без него сбой клиента
# в конвейере `buildin ... | python3` маскируется нулевым статусом питона,
# который теперь честно разбирает тело ошибки и завершается успешно.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

buildin() {
    "$SCRIPT_DIR/buildin.sh" "$@"
}

# Формат UUID — одной константой на файл: три копии пришлось бы держать в
# синхроне руками, ровно от этого уходили при выносе parse_page_and_block_id.
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# Извлечь UUID из URL или вернуть как есть
parse_id() {
    local input="$1"
    local uuid
    uuid=$(echo "$input" | grep -oE "$UUID_RE" | tail -1 || true)
    echo "${uuid:-$input}"
}

# Значение текстового аргумента: «@путь» — содержимое файла, «-» — stdin,
# иначе строка как есть. Длинный текст комментария в bash-строке — ад
# экранирования, поэтому у него есть файловая форма.
#
# Сигил «@» экранируется удвоением: «@@текст» — литеральный «@текст». Без
# этого комментарий, начинающийся с упоминания, передать было бы нечем: он
# молча уезжал бы в ветку «файл». У «-» своего escape нет намеренно — «--»
# занято разделителем конца опций; значение, равное одному дефису, берётся
# из файла или stdin.
read_arg_text() {
    local value="$1"
    case "$value" in
        -)   cat ;;
        @@*) printf '%s' "${value#@}" ;;
        @*)  local file="${value#@}"
             [[ -f "$file" ]] || {
                 echo "Error: значение начинается с «@», поэтому разобрано как путь к файлу: $file" >&2
                 echo "       файл не найден. Нужен литеральный текст с «@» — удвойте сигил: @@${file}" >&2
                 exit 1
             }
             cat "$file" ;;
        *)   printf '%s' "$value" ;;
    esac
}

# Разобрать идентификаторы страницы и блока из общей формы «<uuid|url[#block]>
# [block_id]». Выставляет PAGE_ID и BLOCK_ID. Один разбор на `comments` и
# `comment`: две копии пришлось бы держать в синхроне руками.
parse_page_and_block_id() {
    local input="$1"
    local maybe_block="${2:-}"

    # Полный URL — buildin.ai/<space>/<page>: страница это последний UUID до «#»
    # (как в parse_id), блок — из якоря после «#».
    PAGE_ID=$(echo "${input%%#*}" | grep -oE "$UUID_RE" | tail -1 || true)
    [[ -z "$PAGE_ID" ]] && { echo "Error: no UUID found in '$input'" >&2; exit 1; }

    BLOCK_ID="$maybe_block"
    if [[ -z "$BLOCK_ID" && "$input" == *"#"* ]]; then
        BLOCK_ID=$(echo "${input#*#}" | grep -oE "$UUID_RE" | head -1 || true)
    fi
}

# Флаги команд комментариев — один разбор на comment, comment-reply и
# comment-resolve/unresolve: копии цикла разошлись бы молча. $1 — разрешённые
# флаги через пробел, дальше аргументы команды. Выставляет DRY_RUN,
# ROLLBACK_OUT, OCCURRENCE, NARROW, массив MENTIONS и массив ARGS с
# позиционными.
#
# Неизвестные «--»-токены отвергаются, а не сваливаются в позиционные: иначе
# опечатка «--dryrun» молча делает боевую запись вместо превью. Флаг, который
# команде не положен, отвергается так же: у резолва нет файла отката, и
# молча принятый --rollback-out обещал бы то, чего нет.
parse_comment_flags() {
    local allowed=" $1 " flag
    shift
    DRY_RUN=""
    ROLLBACK_OUT=""
    OCCURRENCE=""
    NARROW=""
    MENTIONS=()
    ARGS=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --?* ]]; then
            flag="${1%%=*}"
            [[ "$allowed" == *" ${flag#--} "* ]] || {
                echo "Error: неизвестный флаг: $1" >&2; echo "$USAGE" >&2; exit 1; }
        fi
        case "$1" in
            --dry-run)         DRY_RUN=1 ;;
            --narrow)          NARROW=1 ;;
            --occurrence=*)    OCCURRENCE="${1#*=}" ;;
            --occurrence)      shift; OCCURRENCE="${1:-}"
                               [[ -n "$OCCURRENCE" && "$OCCURRENCE" != --* ]] || {
                                   echo "Error: --occurrence без значения" >&2; exit 1; } ;;
            --rollback-out=*)  ROLLBACK_OUT="${1#*=}" ;;
            --rollback-out)    shift; ROLLBACK_OUT="${1:-}"
                               [[ -n "$ROLLBACK_OUT" && "$ROLLBACK_OUT" != --* ]] || {
                                   echo "Error: --rollback-out без значения" >&2; exit 1; } ;;
            --mention=*)       [[ -n "${1#*=}" ]] || { echo "Error: --mention без значения" >&2; exit 1; }
                               MENTIONS+=("${1#*=}") ;;
            --mention)         shift
                               [[ -n "${1:-}" && "${1:-}" != --* ]] || {
                                   echo "Error: --mention без значения" >&2; exit 1; }
                               MENTIONS+=("$1") ;;
            --)                shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done; break ;;
            --*)               echo "Error: неизвестный флаг: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
            *)                 ARGS+=("$1") ;;
        esac
        shift || true
    done
}

# Получить spaceId для страницы
get_space_id() {
    local PAGE_ID="$1"
    local space_id
    space_id=$(buildin GET "/api/blocks/$PAGE_ID" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('data', {}).get('spaceId', ''))
" 2>/dev/null)
    [[ -z "$space_id" ]] && { echo "Error: cannot resolve spaceId for $PAGE_ID" >&2; exit 1; }
    echo "$space_id"
}

# Получить uuid текущего пользователя — его проставляют в createdBy/updatedBy.
# Пустой uuid молча испортил бы авторство у всего, что создаёт транзакция.
get_user_id() {
    local user_id
    user_id=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")
    [[ -z "$user_id" ]] && { echo "Error: cannot resolve current user id from /api/users/me" >&2; exit 1; }
    echo "$user_id"
}

# Сгенерировать UUID v4
gen_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))"
}

# Тело запроса к /api/records/transactions. Отдельно от отправки: тот же конверт
# нужен файлу отката, а две его копии разошлись бы молча и вскрылись бы ровно
# в тот момент, когда откат понадобится.
tx_body() {
    local SPACE_ID="$1"
    local OPERATIONS="$2"
    python3 -c "
import json, sys
ops = json.loads(sys.argv[1])
print(json.dumps({
    'requestId': sys.argv[2],
    'transactions': [{
        'id': sys.argv[3],
        'spaceId': sys.argv[4],
        'operations': ops
    }]
}))
" "$OPERATIONS" "$(gen_uuid)" "$(gen_uuid)" "$SPACE_ID"
}

# Выполнить транзакцию
transaction() {
    local SPACE_ID="$1"
    local OPERATIONS="$2"
    # Тело собираем отдельным присваиванием, а не подстановкой прямо в аргументе:
    # при подстановке сбой сборки прячется от set -e и POST уходит с пустым телом.
    # «|| return» обязателен, а не избыточен: в условии if/&&/|| bash отключает
    # set -e во всём теле вызванной функции, и без него сбой сборки тела не
    # прервал бы её — POST ушёл бы с пустым телом.
    local body
    body=$(tx_body "$SPACE_ID" "$OPERATIONS") || return
    buildin POST "/api/records/transactions" "$body"
}

# Аргументы билдера для @-упоминаний: файл участников пространства (для
# сверки uuid) и сами --mention. Пространство берётся у блока или треда из
# уже прочитанного /api/docs. Если их на странице нет, участников не
# спрашиваем: об отсутствии скажет билдер, и это сообщение точнее.
# Выставляет массив MENTION_ARGS и MEMBERS_FILE — его удаляет trap команды.
# $1 — файл /api/docs, $2 — id блока или треда.
mention_args() {
    local space m
    MENTION_ARGS=()
    [[ ${#MENTIONS[@]} -gt 0 ]] || return 0
    MEMBERS_FILE=$(mktemp)
    space=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8')).get('data') or {}
rec = (data.get('blocks') or {}).get(sys.argv[2]) or (data.get('discussions') or {}).get(sys.argv[2]) or {}
print(rec.get('spaceId', ''))
" "$1" "$2")
    if [[ -z "$space" ]]; then
        echo '{}' > "$MEMBERS_FILE"
    elif ! buildin GET "/api/spaces/$space/members" > "$MEMBERS_FILE"; then
        echo "Error: не удалось получить участников пространства — упоминание не проверить, запись отменена." >&2
        exit 1
    fi
    MENTION_ARGS+=("--members=$MEMBERS_FILE")
    for m in "${MENTIONS[@]}"; do
        MENTION_ARGS+=("--mention=$m")
    done
}

# Файл отката — готовое тело запроса. Один на comment и comment-reply: права
# и дефолтное имя у двух копий разошлись бы молча. $1 — spaceId, $2 — файл с
# операциями отката, $3 (необязательный) — файл сверки для ключа check.
# Путь — из ROLLBACK_OUT, а без него — свежий mktemp.
write_rollback() {
    local body
    [[ -n "$ROLLBACK_OUT" ]] || ROLLBACK_OUT=$(mktemp "${TMPDIR:-/tmp}/buildin-rollback-XXXXXX")
    body=$(tx_body "$1" "$(cat "$2")") || return
    if [[ -n "${3:-}" ]]; then
        # Сверка едет в том же файле: отдельный файл рядом легко потерять, и
        # откат тогда молча шёл бы без проверки свежести.
        body=$(python3 -c "
import json, sys
body = json.loads(sys.argv[1])
body['check'] = json.load(open(sys.argv[2], encoding='utf-8'))
print(json.dumps(body))
" "$body" "$3") || return
    fi
    # umask 077 на подоболочку: дефолтный путь создаёт mktemp с правами 0600,
    # а перенаправление по --rollback-out дало бы права по umask, хотя в
    # файле лежит полный текст блока. У уже существующего файла права свои.
    (umask 077; printf '%s\n' "$body" > "$ROLLBACK_OUT")
    echo "Откат: $ROLLBACK_OUT" >&2
}

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    get)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: get <page_id|url>" >&2; exit 1; }
        buildin GET "/api/docs/$PAGE_ID"
        ;;

    title)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: title <page_id|url>" >&2; exit 1; }
        buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys
page_id = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
blocks = data.get('blocks', {})
block = blocks.get(page_id, next(iter(blocks.values()), {})) if blocks else data
print(block.get('title', '(untitled)'))
" "$PAGE_ID"
        ;;

    create)
        PARENT_ID=$(parse_id "$1")
        TITLE="$2"
        [[ -z "$PARENT_ID" || -z "$TITLE" ]] && { echo "Usage: create <parent_page_id|url> <title>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PARENT_ID")

        PAGE_UUID=$(gen_uuid)
        BLOCK_UUID=$(gen_uuid)
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)

        OPS=$(python3 -c "
import json, sys
page_id = sys.argv[1]
parent_id = sys.argv[2]
space_id = sys.argv[3]
block_id = sys.argv[4]
title = sys.argv[5]
now = int(sys.argv[6])
user_id = sys.argv[7]

ops = [
    # Create the page block
    {
        'id': page_id,
        'command': 'set',
        'table': 'block',
        'path': [],
        'args': {
            'uuid': page_id,
            'spaceId': space_id,
            'parentId': parent_id,
            'type': 0,
            'textColor': '',
            'backgroundColor': '',
            'status': 1,
            'permissions': [],
            'createdAt': now,
            'createdBy': user_id,
            'updatedBy': user_id,
            'updatedAt': now,
            'data': {
                'segments': [{'type': 0, 'text': title, 'enhancer': {}}],
                'pageFixedWidth': True,
                'format': {'commentAlignment': 'top'}
            }
        }
    },
    # Add page to parent's subNodes
    {
        'id': parent_id,
        'command': 'listAfter',
        'table': 'block',
        'path': ['subNodes'],
        'args': {'uuid': page_id}
    },
    # Create empty paragraph inside the page
    {
        'id': block_id,
        'command': 'set',
        'table': 'block',
        'path': [],
        'args': {
            'uuid': block_id,
            'spaceId': space_id,
            'parentId': page_id,
            'type': 1,
            'textColor': '',
            'backgroundColor': '',
            'status': 1,
            'permissions': [],
            'createdAt': now,
            'createdBy': user_id,
            'updatedBy': user_id,
            'updatedAt': now,
            'data': {
                'pageFixedWidth': True,
                'format': {'commentAlignment': 'top'}
            }
        }
    },
    # Add paragraph to page's subNodes
    {
        'id': page_id,
        'command': 'listAfter',
        'table': 'block',
        'path': ['subNodes'],
        'args': {'uuid': block_id}
    },
    # Update parent timestamps
    {
        'id': parent_id,
        'command': 'update',
        'table': 'block',
        'path': [],
        'args': {'updatedBy': user_id, 'updatedAt': now}
    }
]
print(json.dumps(ops))
" "$PAGE_UUID" "$PARENT_ID" "$SPACE_ID" "$BLOCK_UUID" "$TITLE" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        echo ""
        echo "Created page: $PAGE_UUID"
        echo "URL: https://buildin.ai/$SPACE_ID/$PAGE_UUID"
        ;;

    update)
        PAGE_ID=$(parse_id "$1")
        TITLE="$2"
        [[ -z "$PAGE_ID" || -z "$TITLE" ]] && { echo "Usage: update <page_id|url> <title>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PAGE_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)

        OPS=$(python3 -c "
import json, sys
page_id, title, now, user_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
ops = [
    {
        'id': page_id,
        'command': 'update',
        'table': 'block',
        'path': ['data'],
        'args': {'segments': [{'type': 0, 'text': title, 'enhancer': {}}]}
    },
    {
        'id': page_id,
        'command': 'update',
        'table': 'block',
        'path': [],
        'args': {'updatedBy': user_id, 'updatedAt': now}
    }
]
print(json.dumps(ops))
" "$PAGE_ID" "$TITLE" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    archive)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: archive <page_id|url>" >&2; exit 1; }

        # Get parent and space info
        BLOCK_INFO=$(buildin GET "/api/blocks/$PAGE_ID")
        SPACE_ID=$(echo "$BLOCK_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('spaceId',''))")
        [[ -z "$SPACE_ID" ]] && { echo "Error: cannot resolve spaceId for $PAGE_ID" >&2; exit 1; }
        PARENT_ID=$(echo "$BLOCK_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('parentId',''))")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)

        OPS=$(python3 -c "
import json, sys
page_id, parent_id, now, user_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
ops = [
    {'id': page_id, 'command': 'update', 'table': 'block', 'path': [],
     'args': {'status': -1, 'updatedBy': user_id, 'updatedAt': now}},
    {'id': parent_id, 'command': 'listRemove', 'table': 'block', 'path': ['subNodes'],
     'args': {'uuid': page_id}},
    {'id': page_id, 'command': 'update', 'table': 'block', 'path': [],
     'args': {'updatedBy': user_id, 'updatedAt': now}}
]
print(json.dumps(ops))
" "$PAGE_ID" "$PARENT_ID" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    get-blocks)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: get-blocks <page_id|url>" >&2; exit 1; }
        buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys
page_id = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
blocks = data.get('blocks', {})
page = blocks.get(page_id, {})
sub_nodes = page.get('subNodes', [])
result = []
for sid in sub_nodes:
    if sid in blocks:
        result.append(blocks[sid])
print(json.dumps(result, indent=2, ensure_ascii=False))
" "$PAGE_ID"
        ;;

    comments)
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "Usage: comments <page_id|url[#block_id]> [block_id]" >&2; exit 1; }
        parse_page_and_block_id "$INPUT" "${2:-}"

        DOC_FILE=$(mktemp)
        MEMBERS_FILE=$(mktemp)
        trap 'rm -f "$DOC_FILE" "$MEMBERS_FILE"' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        SPACE_ID=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1])).get('data', {})
blocks = data.get('blocks', {})
print(next(iter(blocks.values()), {}).get('spaceId', ''))
" "$DOC_FILE")
        # Участники нужны для имён авторов и @-упоминаний; без доступа — покажем UUID
        if [[ -n "$SPACE_ID" ]]; then
            buildin GET "/api/spaces/$SPACE_ID/members" > "$MEMBERS_FILE" 2>/dev/null || echo '{}' > "$MEMBERS_FILE"
        else
            echo '{}' > "$MEMBERS_FILE"
        fi

        python3 -c "
import json, sys
from datetime import datetime

doc_file, members_file, page_id, block_id = sys.argv[1:5]
data = json.load(open(doc_file)).get('data', {})
blocks = data.get('blocks', {})
discussions = data.get('discussions', {})
comments = data.get('comments', {})

try:
    members = json.load(open(members_file)).get('data', []) or []
except Exception:
    members = []
users = {m['user']['uuid']: m['user'].get('nickname') or m['user'].get('email', '') for m in members if m.get('user')}

def name(uuid):
    return users.get(uuid, uuid[:8] if uuid else '?')

def rt(segments):
    # type 7 — @-упоминание человека: text пустой, uuid = user uuid
    parts = []
    segments = segments or []
    for i, s in enumerate(segments):
        if s.get('type') == 7:
            # Пробел после упоминания нужен, когда следующий сегмент начинается
            # сразу с текста. Если пробел в нём уже есть, второй дал бы «@Имя  текст».
            nxt = segments[i + 1].get('text', '') if i + 1 < len(segments) else ''
            parts.append('@' + name(s.get('uuid', '')) + ('' if nxt[:1].isspace() else ' '))
        else:
            parts.append(s.get('text', ''))
    return ''.join(parts).strip()

def ts(ms):
    return datetime.fromtimestamp(ms / 1000).strftime('%Y-%m-%d %H:%M') if ms else '?'

found = 0
for did, disc in discussions.items():
    parent = disc.get('parentId', '')
    if block_id and parent != block_id:
        continue
    block = blocks.get(parent, {})
    block_title = block.get('title') or rt(block.get('data', {}).get('segments'))
    context = rt(disc.get('context'))
    status = 'resolved' if disc.get('resolved') else 'open'
    found += 1
    print(f'## Блок {parent}')
    if block_title:
        print(f'Текст блока: {block_title}')
    if context and context != block_title:
        print(f'Выделено: «{context}»')
    print(f'Тред {did} [{status}]:')
    for cid in disc.get('comments', []):
        c = comments.get(cid, {})
        body = rt(c.get('text')) or '(без текста)'
        print(f'- {name(c.get(\"createdBy\", \"\"))} ({ts(c.get(\"createdAt\"))}): {body}')
    print()

if not found:
    where = f'блока {block_id}' if block_id else f'страницы {page_id}'
    print(f'Комментариев у {where} нет.')
" "$DOC_FILE" "$MEMBERS_FILE" "$PAGE_ID" "$BLOCK_ID"
        ;;

    comment)
        USAGE='Usage: comment <page_id|url[#block_id]> [block_id] <anchor> <text> [--dry-run] [--occurrence=N] [--rollback-out=<path>]
                [--mention=<user_uuid>]...
  <anchor>, <text>: строка, «@путь» — содержимое файла, «-» — stdin
                    («@@текст» — литеральный «@текст»; значение с ведущими
                     дефисами — после разделителя «--»)
  блок: только прозаический (абзац, списки, todo, toggle, заголовок, цитата,
        callout) — картинка, таблица, код и заголовок страницы отвергаются
  дату и инлайн-формулу внутри блока — только целиком: якорь «‣» у даты,
        исходник LaTeX у формулы'
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "$USAGE" >&2; exit 1; }
        shift
        parse_comment_flags "dry-run occurrence rollback-out mention" "$@"

        parse_page_and_block_id "$INPUT"
        # Первый позиционный считаем блоком, только если он целиком UUID: якорь
        # такой формы был бы патологией, а обычная фраза ею не притворится.
        if [[ "${ARGS[0]:-}" =~ ^$UUID_RE$ ]]; then
            BLOCK_ID="${ARGS[0]}"
            ARGS=("${ARGS[@]:1}")
        fi

        [[ -z "$BLOCK_ID" ]] && { echo "Error: не указан block_id (аргументом или якорем #block-uuid в URL)" >&2; echo "$USAGE" >&2; exit 1; }
        [[ ${#ARGS[@]} -eq 2 ]] || { echo "Error: ожидались ровно <anchor> и <text>, получено: ${#ARGS[@]}" >&2; echo "$USAGE" >&2; exit 1; }
        [[ -z "$OCCURRENCE" || "$OCCURRENCE" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --occurrence ожидает целое число >= 1, получено: $OCCURRENCE" >&2; exit 1; }
        [[ "${ARGS[0]}" == "-" && "${ARGS[1]}" == "-" ]] && { echo "Error: stdin можно отдать только одному аргументу" >&2; exit 1; }

        ANCHOR=$(read_arg_text "${ARGS[0]}")
        TEXT=$(read_arg_text "${ARGS[1]}")
        # Проверяем РАЗВЁРНУТЫЕ значения: пустой файл и пустой stdin дают непустой
        # сигил, и тред с пустым сообщением уходил бы в живой документ.
        [[ -z "$ANCHOR" ]] && { echo "Error: якорь пустой" >&2; exit 1; }
        [[ -z "$TEXT" ]] && { echo "Error: текст комментария пустой" >&2; exit 1; }

        DOC_FILE=$(mktemp)
        FRESH_FILE=""
        OPS_DIR=""
        MEMBERS_FILE=""
        trap 'rm -rf "$DOC_FILE" ${FRESH_FILE:+"$FRESH_FILE"} ${OPS_DIR:+"$OPS_DIR"} ${MEMBERS_FILE:+"$MEMBERS_FILE"}' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")
        mention_args "$DOC_FILE" "$BLOCK_ID"

        # «--» обязателен: без него якорь или текст с ведущими дефисами билдер
        # примет за флаг, и файловая форма ввода от этого не спасает.
        BUILT=$(python3 "$SCRIPT_DIR/buildin-comment.py" \
            ${OCCURRENCE:+--occurrence="$OCCURRENCE"} ${MENTION_ARGS[@]+"${MENTION_ARGS[@]}"} --page="$PAGE_ID" -- \
            "$DOC_FILE" "$BLOCK_ID" "$ANCHOR" "$TEXT" "$NOW" "$USER_ID")

        if [[ -n "$DRY_RUN" ]]; then
            # Превью не трогает ни сеть, ни диск: файл отката по дефолтному пути
            # затёр бы откат предыдущего РЕАЛЬНОГО комментария.
            echo "$BUILT" | python3 -c "
import json, sys
# Пишем в буфер напрямую: печать не-ASCII через stdout падает под не-UTF-8
# локалью, а превью должно оставаться читаемым.
out = json.dumps(json.load(sys.stdin)['ops'], ensure_ascii=False, indent=2)
sys.stdout.buffer.write(out.encode('utf-8') + b'\n')"
            exit 0
        fi

        # spaceId берём у самого блока — тот же, что уходит в args операций
        SPACE_ID=$(python3 -c "
import json, sys
# encoding обязателен: под не-UTF-8 локалью open() берёт ASCII и падает
blocks = (json.load(open(sys.argv[1], encoding='utf-8')).get('data') or {}).get('blocks') or {}
print((blocks.get(sys.argv[2]) or {}).get('spaceId', ''))
" "$DOC_FILE" "$BLOCK_ID")

        # Оптимистичная проверка. Операции узкие, поэтому чужие ключи data и
        # чужие треды в списке переживают запись, а вот segments уходят целиком
        # из снапшота: правка блока между GET и POST потеряла бы чужую подсветку.
        FRESH_FILE=$(mktemp)
        buildin GET "/api/docs/$PAGE_ID" > "$FRESH_FILE"
        python3 -c "
import json, sys
def segs(path):
    blocks = (json.load(open(path, encoding='utf-8')).get('data') or {}).get('blocks') or {}
    return ((blocks.get(sys.argv[3]) or {}).get('data') or {}).get('segments')
if segs(sys.argv[1]) != segs(sys.argv[2]):
    sys.exit('Error: блок изменился, пока готовился комментарий — запись отменена.\n'
             '       Повторите команду: она возьмёт свежее состояние блока.')
" "$DOC_FILE" "$FRESH_FILE" "$BLOCK_ID"

        OPS_DIR=$(mktemp -d)
        DISCUSSION=$(echo "$BUILT" | python3 -c "
import json, os, sys
out, page, block = sys.argv[1:4]
built = json.load(sys.stdin)
for key in ('ops', 'rollback', 'rollback_records'):
    open(os.path.join(out, key + '.json'), 'w').write(json.dumps(built[key]))
open(os.path.join(out, 'check.json'), 'w').write(json.dumps(
    {'page': page, 'block': block, 'segments': built['segments_after']}))
print(built['discussion'])
" "$OPS_DIR" "$PAGE_ID" "$BLOCK_ID")
        write_rollback "$SPACE_ID" "$OPS_DIR/rollback.json" "$OPS_DIR/check.json"

        # О созданном треде сообщаем ДО записи: id известен сразу после билдера,
        # а если POST оборвётся, узнать его будет неоткуда — curl в buildin.sh
        # идёт без -S и на обрыве молчит. Повтор вслепую повесил бы второй тред
        # на ту же фразу: видимый текст блока после разреза не меняется.
        echo "discussion: $DISCUSSION" >&2
        if ! transaction "$SPACE_ID" "$(cat "$OPS_DIR/ops.json")" > /dev/null; then
            echo "Error: исход записи неизвестен (discussion: $DISCUSSION)." >&2
            echo "       Не повторяйте команду вслепую — сначала посмотрите блок на странице." >&2
            exit 2
        fi

        # Проверка ПОСЛЕ записи. Проверка до неё сужает окно, но не закрывает:
        # несколько процессов успевают сделать оба GET раньше первого POST, и
        # тогда побеждает последний писавший segments.
        # FRESH_FILE переиспользуем: второй mktemp оставлял первый файл с полной
        # копией страницы в $TMPDIR навсегда — trap раскрывает переменную на
        # выходе и удалил бы только последний.
        if ! buildin GET "/api/docs/$PAGE_ID" > "$FRESH_FILE"; then
            echo "Error: транзакция отправлена (discussion: $DISCUSSION), но проверить результат не удалось." >&2
            echo "       Не повторяйте команду вслепую — сначала посмотрите блок на странице." >&2
            exit 2
        fi

        VERDICT=$(python3 "$SCRIPT_DIR/buildin-comment.py" --verdict -- \
            "$DOC_FILE" "$FRESH_FILE" "$BLOCK_ID" "$DISCUSSION")
        STATUS=$(echo "$VERDICT" | sed -n 1p)
        LOST=$(echo "$VERDICT" | sed -n 2p)

        case "$STATUS" in
            unverified)
                # Блока нет в ответе: конверт ошибки, чужая страница, обрезанное
                # тело. Об исходе записи ничего не известно, поэтому ничего не
                # гасим — самоочистка тут снимала бы, возможно, успешный тред.
                echo "Error: проверочное чтение не вернуло блок — исход записи неизвестен." >&2
                echo "       Тред: $DISCUSSION. Не повторяйте команду вслепую — посмотрите блок на странице." >&2
                exit 2
                ;;
            not-applied)
                # Нашего треда нет даже в списке блока. listAfter аддитивен, и
                # конкурент наш id из списка не убирает — значит транзакция не
                # легла: создавать было нечего, повтор безопасен.
                echo "Error: транзакция не применилась — треда $DISCUSSION нет в списке блока." >&2
                echo "       Ничего создано не было, повтор безопасен." >&2
                echo "       Файл отката $ROLLBACK_OUT применять не надо." >&2
                exit 1
                ;;
            lost-ours)
                # Блок переписали поверх нас. Наших сегментов там уже нет, поэтому
                # полный откат применять НЕЛЬЗЯ — он вернул бы наш снапшот и стёр
                # подсветку победителя. Предупреждаем ДО самоочистки: её сбой не
                # должен проглотить этот запрет, иначе пользователь применит
                # полный откат, увидев только путь к нему.
                echo "Error: тред создан, но подсветка не закрепилась — блок перезаписали параллельно." >&2
                echo "       Файл отката $ROLLBACK_OUT применять НЕ надо — он вернёт устаревшие сегменты." >&2
                if transaction "$SPACE_ID" "$(cat "$OPS_DIR/rollback_records.json")" > /dev/null; then
                    echo "       Тред $DISCUSSION снят: убран из блока и погашен. Чужие правки не тронуты." >&2
                    echo "       Повторите команду: она возьмёт свежее состояние блока." >&2
                    exit 1
                fi
                echo "       Снять тред не удалось: $DISCUSSION остался в списке блока без подсветки." >&2
                echo "       Снимите его вручную или повторите команду и уберите лишний тред." >&2
                exit 2
                ;;
        esac

        # Именно if, а не «[[ … ]] && { … }»: это последняя команда ветки, и её
        # статус стал бы кодом выхода всей команды — пустой список превращался
        # бы в rc=1 на совершенно успешной записи.
        # Результат — в stdout, как id новой страницы у create: обёртке и агенту
        # естественно искать его там. Ранняя строка в stderr остаётся страховкой
        # на случай обрыва до этого места.
        echo "discussion: $DISCUSSION"

        if [[ -n "$LOST" ]]; then
            echo "ВНИМАНИЕ: параллельная запись лишила подсветки чужие треды: ${LOST// /, }" >&2
            echo "          Они остались в списке блока, но на странице их не видно." >&2
            echo "          Текст цел — посмотреть: buildin-pages.sh comments $PAGE_ID $BLOCK_ID" >&2
            echo "          Если это тред другого запуска comment, упавшего с ошибкой про" >&2
            echo "          подсветку, — он снимется сам и будет повторён, реагировать не надо." >&2
            echo "          Иначе вернуть подсветку можно только новым комментарием: сама" >&2
            echo "          команда не угадывает, к какой фразе чужой тред был привязан." >&2
        fi
        ;;

    comment-reply)
        USAGE='Usage: comment-reply <page_id|url> <discussion_id> <text> [--dry-run] [--rollback-out=<path>]
                      [--mention=<user_uuid>]...
  <discussion_id>: строка «Тред <uuid>» в выводе comments; страница — та, где висит тред
  <text>: строка, «@путь» — содержимое файла, «-» — stdin
          («@@текст» — литеральный «@текст»; значение с ведущими
           дефисами — после разделителя «--»)
  в закрытый тред ответ не пишется: сначала comment-unresolve'
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "$USAGE" >&2; exit 1; }
        shift
        parse_comment_flags "dry-run rollback-out mention" "$@"

        parse_page_and_block_id "$INPUT"
        [[ ${#ARGS[@]} -eq 2 ]] || { echo "Error: ожидались ровно <discussion_id> и <text>, получено: ${#ARGS[@]}" >&2; echo "$USAGE" >&2; exit 1; }
        DISCUSSION="${ARGS[0]}"
        [[ "$DISCUSSION" =~ ^$UUID_RE$ ]] || { echo "Error: <discussion_id> — не UUID: $DISCUSSION" >&2; echo "$USAGE" >&2; exit 1; }
        TEXT=$(read_arg_text "${ARGS[1]}")
        # Проверяем РАЗВЁРНУТОЕ значение: пустой файл и пустой stdin дают
        # непустой сигил, и ответ без текста ушёл бы в живой тред.
        [[ -z "$TEXT" ]] && { echo "Error: текст ответа пустой" >&2; exit 1; }

        DOC_FILE=$(mktemp)
        OPS_DIR=""
        MEMBERS_FILE=""
        trap 'rm -rf "$DOC_FILE" ${OPS_DIR:+"$OPS_DIR"} ${MEMBERS_FILE:+"$MEMBERS_FILE"}' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)
        mention_args "$DOC_FILE" "$DISCUSSION"

        # «--» обязателен: текст с ведущими дефисами билдер иначе принял бы за флаг.
        BUILT=$(python3 "$SCRIPT_DIR/buildin-comment.py" --reply ${MENTION_ARGS[@]+"${MENTION_ARGS[@]}"} -- \
            "$DOC_FILE" "$DISCUSSION" "$TEXT" "$NOW" "$USER_ID")

        if [[ -n "$DRY_RUN" ]]; then
            # Превью не пишет и файл отката: он затёр бы откат предыдущей
            # реальной записи.
            echo "$BUILT" | python3 -c "
import json, sys
out = json.dumps(json.load(sys.stdin)['ops'], ensure_ascii=False, indent=2)
sys.stdout.buffer.write(out.encode('utf-8') + b'\n')"
            exit 0
        fi

        OPS_DIR=$(mktemp -d)
        COMMENT_ID=$(echo "$BUILT" | python3 -c "
import json, os, sys
out = sys.argv[1]
built = json.load(sys.stdin)
for key in ('ops', 'rollback'):
    open(os.path.join(out, key + '.json'), 'w').write(json.dumps(built[key]))
open(os.path.join(out, 'space'), 'w').write(built['space'])
print(built['comment'])
" "$OPS_DIR")
        SPACE_ID=$(cat "$OPS_DIR/space")
        write_rollback "$SPACE_ID" "$OPS_DIR/rollback.json"

        # id ответа — до записи, по той же причине, что у comment: если POST
        # оборвётся, узнать его будет неоткуда, а слепой повтор задвоит ответ.
        echo "comment: $COMMENT_ID" >&2
        if ! transaction "$SPACE_ID" "$(cat "$OPS_DIR/ops.json")" > /dev/null; then
            echo "Error: исход записи неизвестен (comment: $COMMENT_ID)." >&2
            echo "       Не повторяйте команду вслепую — сначала посмотрите тред: buildin-pages.sh comments $PAGE_ID" >&2
            exit 2
        fi
        if ! buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"; then
            echo "Error: транзакция отправлена (comment: $COMMENT_ID), но проверить результат не удалось." >&2
            echo "       Не повторяйте команду вслепую — сначала посмотрите тред: buildin-pages.sh comments $PAGE_ID" >&2
            exit 2
        fi
        STATUS=$(python3 "$SCRIPT_DIR/buildin-comment.py" --reply-verdict -- "$DOC_FILE" "$DISCUSSION" "$COMMENT_ID")
        case "$STATUS" in
            unverified)
                echo "Error: проверочное чтение не вернуло тред $DISCUSSION — исход записи неизвестен." >&2
                echo "       Ответ: $COMMENT_ID. Не повторяйте команду вслепую — посмотрите тред: buildin-pages.sh comments $PAGE_ID" >&2
                exit 2
                ;;
            not-applied)
                echo "Error: транзакция не применилась — ответа $COMMENT_ID в треде нет." >&2
                echo "       Ничего создано не было, повтор безопасен. Файл отката $ROLLBACK_OUT применять не надо." >&2
                exit 1
                ;;
        esac
        echo "comment: $COMMENT_ID"
        ;;

    comment-resolve|comment-unresolve)
        USAGE="Usage: $COMMAND <page_id|url> <discussion_id> [--dry-run]
  <discussion_id>: строка «Тред <uuid>» в выводе comments; страница — та, где висит тред
  тред уже в нужном состоянии — записи нет, выход 0"
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "$USAGE" >&2; exit 1; }
        shift
        parse_comment_flags "dry-run" "$@"

        parse_page_and_block_id "$INPUT"
        [[ ${#ARGS[@]} -eq 1 ]] || { echo "Error: ожидался ровно <discussion_id>, получено: ${#ARGS[@]}" >&2; echo "$USAGE" >&2; exit 1; }
        DISCUSSION="${ARGS[0]}"
        [[ "$DISCUSSION" =~ ^$UUID_RE$ ]] || { echo "Error: <discussion_id> — не UUID: $DISCUSSION" >&2; echo "$USAGE" >&2; exit 1; }
        if [[ "$COMMAND" == comment-resolve ]]; then
            TARGET=true; STATE="закрыт"
        else
            TARGET=false; STATE="открыт"
        fi

        DOC_FILE=$(mktemp)
        trap 'rm -f "$DOC_FILE"' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        BUILT=$(python3 "$SCRIPT_DIR/buildin-comment.py" --resolve="$TARGET" -- "$DOC_FILE" "$DISCUSSION")
        OPS=$(echo "$BUILT" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['ops']))")
        SPACE_ID=$(echo "$BUILT" | python3 -c "import json, sys; print(json.load(sys.stdin)['space'])")

        if [[ "$OPS" == "[]" ]]; then
            echo "Тред $DISCUSSION уже $STATE — записи не было." >&2
            echo "discussion: $DISCUSSION"
            exit 0
        fi
        if [[ -n "$DRY_RUN" ]]; then
            echo "$OPS" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin), indent=2))"
            exit 0
        fi

        # Резолв идемпотентен, поэтому при неизвестном исходе повтор безопасен —
        # в отличие от comment, где слепой повтор повесил бы второй тред.
        if ! transaction "$SPACE_ID" "$OPS" > /dev/null; then
            echo "Error: исход записи неизвестен (discussion: $DISCUSSION)." >&2
            echo "       Повтор безопасен: команда сама увидит, если тред уже $STATE." >&2
            exit 2
        fi
        if ! buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"; then
            echo "Error: транзакция отправлена (discussion: $DISCUSSION), но проверить результат не удалось." >&2
            echo "       Повтор безопасен: команда сама увидит, если тред уже $STATE." >&2
            exit 2
        fi
        STATUS=$(python3 "$SCRIPT_DIR/buildin-comment.py" --resolve-verdict="$TARGET" -- "$DOC_FILE" "$DISCUSSION")
        case "$STATUS" in
            unverified)
                echo "Error: проверочное чтение не вернуло тред $DISCUSSION — исход записи неизвестен." >&2
                echo "       Повтор безопасен: команда сама увидит, если тред уже $STATE." >&2
                exit 2
                ;;
            not-applied)
                echo "Error: транзакция не применилась — тред $DISCUSSION не $STATE. Повтор безопасен." >&2
                exit 1
                ;;
        esac
        echo "Тред $DISCUSSION $STATE." >&2
        echo "discussion: $DISCUSSION"
        ;;

    comment-rollback)
        USAGE='Usage: comment-rollback <file> [--narrow]
  <file>: файл отката из stderr comment или comment-reply («Откат: <путь>»)
  --narrow: снять только свой тред, не возвращая сегменты блока — для блока,
            который изменился после комментария (полный откат тогда отвергается)
  после применения файл переименовывается в <file>.applied — повтор отвергается'
        parse_comment_flags "narrow" "$@"
        FILE="${ARGS[0]:-}"
        [[ -n "$FILE" && ${#ARGS[@]} -eq 1 ]] || { echo "$USAGE" >&2; exit 1; }
        # Применённый откат второй раз не применяется: полный откат снова вернул
        # бы блок к старому снапшоту и стёр бы подсветку тех, кто успел
        # прокомментировать после первого применения.
        [[ "$FILE" == *.applied ]] && { echo "Error: $FILE уже применён (суффикс .applied) — повтор отвергнут." >&2; exit 1; }
        if [[ ! -f "$FILE" ]]; then
            echo "Error: файла отката нет: $FILE" >&2
            [[ -f "$FILE.applied" ]] && echo "       Он уже применён: $FILE.applied — повтор отвергнут." >&2
            exit 1
        fi

        RB_DIR=$(mktemp -d)
        trap 'rm -rf "$RB_DIR"' EXIT
        CHECKED=$(python3 "$SCRIPT_DIR/buildin-comment.py" --check-rollback -- "$FILE")
        echo "$CHECKED" | python3 -c "
import json, os, sys
c, out = json.load(sys.stdin), sys.argv[1]
open(os.path.join(out, 'space'), 'w').write(c['space'])
open(os.path.join(out, 'ops'), 'w').write(json.dumps(c['ops']))
open(os.path.join(out, 'narrow_ops'), 'w').write(json.dumps(c['narrow_ops']))
open(os.path.join(out, 'page'), 'w').write((c['check'] or {}).get('page', ''))
open(os.path.join(out, 'restores'), 'w').write('1' if c['ops'] != c['narrow_ops'] else '')
" "$RB_DIR"
        SPACE_ID=$(cat "$RB_DIR/space")
        OPS=$(cat "$RB_DIR/ops")
        CHECK_PAGE=$(cat "$RB_DIR/page")

        if [[ -n "$NARROW" ]]; then
            OPS=$(cat "$RB_DIR/narrow_ops")
        elif [[ -n "$(cat "$RB_DIR/restores")" ]]; then
            # Полный откат возвращает снапшот сегментов. Если блок меняли после
            # нашего комментария, снапшот стёр бы чужие правки и подсветку,
            # поэтому сначала сверка: блок должен быть ровно таким, каким его
            # оставила наша запись.
            if [[ -z "$CHECK_PAGE" ]]; then
                echo "ВНИМАНИЕ: в файле нет данных для сверки с блоком — сегменты вернутся без проверки свежести." >&2
            else
                if ! buildin GET "/api/docs/$CHECK_PAGE" > "$RB_DIR/doc.json"; then
                    echo "Error: не удалось прочитать страницу, чтобы сверить блок с файлом отката — откат не применён." >&2
                    exit 1
                fi
                # Применяем только при явном fresh: сбой сверки не должен
                # превращаться в откат вслепую.
                FRESH=$(python3 "$SCRIPT_DIR/buildin-comment.py" --rollback-fresh -- "$FILE" "$RB_DIR/doc.json")
                case "$FRESH" in
                    fresh) ;;
                    stale)
                        echo "Error: блок изменился после комментария — полный откат вернул бы старый снапшот" >&2
                        echo "       и стёр чужие правки и подсветку. Откат не применён." >&2
                        echo "       Снять только свой тред, не трогая сегменты: buildin-pages.sh comment-rollback $FILE --narrow" >&2
                        exit 1
                        ;;
                    *)
                        echo "Error: блока из файла отката нет на странице — сверить не с чем, откат не применён." >&2
                        echo "       Снять только свой тред: buildin-pages.sh comment-rollback $FILE --narrow" >&2
                        exit 1
                        ;;
                esac
            fi
        fi

        # Конверт собирается заново общим transaction(): в сеть уходит одна
        # форма тела, а из файла берётся только то, что проверено по операциям.
        if ! transaction "$SPACE_ID" "$OPS" > /dev/null; then
            echo "Error: исход отката неизвестен — файл не переименован." >&2
            echo "       Прежде чем применять снова, посмотрите блок или тред командой comments." >&2
            exit 2
        fi
        if ! mv "$FILE" "$FILE.applied"; then
            echo "ВНИМАНИЕ: откат применён, но переименовать $FILE не удалось." >&2
            echo "          Повторно его не применяйте." >&2
        fi
        echo "rollback: applied ($FILE.applied)"
        ;;

    read)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: read <page_id|url>" >&2; exit 1; }

        buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys

page_id = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
blocks = data.get('blocks', {})
page = blocks.get(page_id, {})
title = page.get('title', '(untitled)')
print(f'# {title}')
print()

# Block types: 0=page, 1=paragraph, 3=todo, 4=bulleted, 5=numbered, 6=toggle,
#              7=heading, 9=divider, 12=quote, 13=callout, 14=image,
#              21=bookmark, 23=equation, 25=code, 27=table (rows=28),
#              38=toggle-heading
def rt(segments):
    parts = []
    for s in (segments or []):
        text = s.get('text', '')
        enh = s.get('enhancer', {})
        url = s.get('url', '')
        if enh.get('code'): text = f'\`{text}\`'
        elif enh.get('bold'): text = f'**{text}**'
        elif enh.get('italic'): text = f'*{text}*'
        if url:
            text = f'[{text}]({url})'
        parts.append(text)
    return ''.join(parts)

def render(node_ids, indent=0):
    pfx = '  ' * indent
    for nid in node_ids:
        b = blocks.get(nid)
        if not b: continue
        t = b.get('type', 1)
        d = b.get('data', {})
        segs = d.get('segments', [])
        text = rt(segs)
        sub = b.get('subNodes', [])
        level = d.get('level', 1)

        if t == 0:
            # Sub-page
            print(f'{pfx}> [{b.get(\"title\", text)}](https://buildin.ai/{b.get(\"spaceId\", \"\")}/{nid})')
            print()
        elif t == 16:
            # Reference/link to another page. Previously unhandled → the link was
            # silently dropped from markdown (a real referenced page looked absent).
            # The /api/docs response includes the referenced block, so resolve its
            # title/space; fall back to the ref uuid when it is not embedded.
            ref = (d.get('ref') or {}).get('uuid', '')
            rb = blocks.get(ref, {})
            rtitle = rb.get('title') or text or '(referenced page)'
            rspace = rb.get('spaceId', '') or b.get('spaceId', '')
            print(f'{pfx}> [{rtitle}](https://buildin.ai/{rspace}/{ref})')
            print()
        elif t == 1:
            # Empty paragraph / text without segments
            if text:
                print(f'{pfx}{text}')
                print()
            else:
                print()
        elif t == 3:
            checked = '[x]' if d.get('checked') else '[ ]'
            print(f'{pfx}- {checked} {text}')
        elif t == 5:
            print(f'{pfx}1. {text}')
        elif t == 4:
            print(f'{pfx}- {text}')
        elif t == 6:
            print(f'{pfx}▶ {text}')
            print()
        elif t == 7:
            # level N → N решёток, чтобы round-trip с md-to-blocks.py был точным
            # (md-to-blocks по умолчанию: '#'→level1, '##'→level2, '###'→level3).
            h = '#' * min(level, 6)
            print(f'{pfx}{h} {text}')
            print()
        elif t == 38:
            # Сворачиваемый заголовок-секция — round-trip с маркером <!-- collapse -->
            h = '#' * min(level, 6)
            print(f'{pfx}<!-- collapse -->')
            print(f'{pfx}{h} {text}')
            print()
        elif t == 27:
            # Таблица: строки — дети типа 28, ячейки в collectionProperties
            fmt = d.get('format', {})
            cols = fmt.get('tableBlockColumnOrder', [])
            rows = []
            for rid in sub:
                rb = blocks.get(rid, {})
                cp = rb.get('data', {}).get('collectionProperties', {})
                rows.append([rt(cp.get(c, [])) for c in cols])
            for ri, row in enumerate(rows):
                print(f'{pfx}| ' + ' | '.join(row) + ' |')
                if ri == 0 and fmt.get('tableBlockRowHeader'):
                    print(f'{pfx}| ' + ' | '.join(['---'] * len(cols)) + ' |')
            print()
            continue
        elif t == 9:
            print(f'{pfx}---')
            print()
        elif t == 12:
            print(f'{pfx}> {text}')
            print()
        elif t == 13:
            icon = d.get('icon', {}).get('value', '')
            print(f'{pfx}> {icon} {text}')
            print()
        elif t == 14:
            oss = d.get('ossName', '')
            ext = d.get('extName', '')
            print(f'{pfx}![{text}]({oss})')
            print()
        elif t == 21:
            link = d.get('link', '')
            print(f'{pfx}[{text or link}]({link})')
            print()
        elif t == 23:
            print(f'{pfx}$$ {text} $$')
            print()
        elif t == 25:
            # Buildin хранит язык в format.language (data.language = null)
            lang = (d.get('language') or d.get('format', {}).get('language', '') or '').lower()
            print(f'{pfx}\`\`\`{lang}')
            print(f'{pfx}{text}')
            print(f'{pfx}\`\`\`')
            print()
        elif text:
            print(f'{pfx}{text}')
            print()

        if sub and t != 0:
            render(sub, indent + 1)

render(page.get('subNodes', []))
" "$PAGE_ID"
        ;;

    publish-md)
        PAGE_ID=$(parse_id "$1")
        MD_FILE="$2"
        [[ -z "$PAGE_ID" || -z "$MD_FILE" ]] && { echo "Usage: publish-md <page_id|url> <file.md> [--replace] [--skip-h1|--keep-h1]" >&2; exit 1; }
        [[ -f "$MD_FILE" ]] || { echo "Error: файл не найден: $MD_FILE" >&2; exit 1; }
        shift 2

        # Режим по умолчанию — append: он же поведение связки
        # md-to-blocks.py + append-blocks, которой пользовались до появления
        # этой команды. Замена страницы включается только явным --replace.
        MODE="--append"
        REST=()
        for arg in "$@"; do
            case "$arg" in
                --replace|--append) MODE="$arg" ;;
                *) REST+=("$arg") ;;
            esac
        done

        python3 "$SCRIPT_DIR/buildin-publish-md.py" "$PAGE_ID" "$MD_FILE" "$MODE" ${REST+"${REST[@]}"}
        ;;

    append-blocks)
        PAGE_ID=$(parse_id "$1")
        BLOCKS_JSON="$2"
        [[ -z "$PAGE_ID" || -z "$BLOCKS_JSON" ]] && { echo "Usage: append-blocks <page_id|url> <json_blocks>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PAGE_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)

        OPS=$(python3 "$SCRIPT_DIR/buildin-blocks.py" "$PAGE_ID" "$SPACE_ID" "$NOW" "$USER_ID" "$BLOCKS_JSON")

        transaction "$SPACE_ID" "$OPS"
        ;;

    insert-blocks-after)
        PAGE_ID=$(parse_id "$1")
        AFTER_BLOCK_ID=$(parse_id "$2")
        BLOCKS_JSON="$3"
        [[ -z "$PAGE_ID" || -z "$AFTER_BLOCK_ID" || -z "$BLOCKS_JSON" ]] && { echo "Usage: insert-blocks-after <page_id|url> <after_block_id> <json_blocks>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PAGE_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)

        OPS=$(python3 "$SCRIPT_DIR/buildin-blocks.py" "$PAGE_ID" "$SPACE_ID" "$NOW" "$USER_ID" "$BLOCKS_JSON" "$AFTER_BLOCK_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    insert-blocks-before)
        PAGE_ID=$(parse_id "$1")
        BEFORE_BLOCK_ID=$(parse_id "$2")
        BLOCKS_JSON="$3"
        [[ -z "$PAGE_ID" || -z "$BEFORE_BLOCK_ID" || -z "$BLOCKS_JSON" ]] && { echo "Usage: insert-blocks-before <page_id|url> <before_block_id> <json_blocks>" >&2; exit 1; }

        # Найти предыдущего соседа целевого блока среди верхнеуровневых блоков
        # страницы. Если он есть — это обычный insert-after (проверенный путь);
        # если целевой блок первый — вставляем в начало через listBefore.
        PREV=$(buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys
page_id, before = sys.argv[1], sys.argv[2]
blocks = json.load(sys.stdin).get('data', {}).get('blocks', {})
sub = blocks.get(page_id, {}).get('subNodes', [])
if before not in sub:
    sys.stderr.write('not_found')
    sys.exit(3)
i = sub.index(before)
print(sub[i - 1] if i > 0 else '')
" "$PAGE_ID" "$BEFORE_BLOCK_ID") || { echo "Error: блок $BEFORE_BLOCK_ID не найден среди верхнеуровневых блоков страницы (вложенные блоки не поддерживаются)" >&2; exit 1; }

        if [[ -n "$PREV" ]]; then
            bash "$SCRIPT_DIR/buildin-pages.sh" insert-blocks-after "$PAGE_ID" "$PREV" "$BLOCKS_JSON"
        else
            SPACE_ID=$(get_space_id "$PAGE_ID")
            NOW=$(python3 -c "import time; print(int(time.time()*1000))")
            USER_ID=$(get_user_id)
            OPS=$(python3 "$SCRIPT_DIR/buildin-blocks.py" "$PAGE_ID" "$SPACE_ID" "$NOW" "$USER_ID" "$BLOCKS_JSON" "" "$BEFORE_BLOCK_ID")
            transaction "$SPACE_ID" "$OPS"
        fi
        ;;

    append-text)
        PAGE_ID=$(parse_id "$1")
        TEXT="$2"
        [[ -z "$PAGE_ID" || -z "$TEXT" ]] && { echo "Usage: append-text <page_id|url> <text>" >&2; exit 1; }

        BLOCKS=$(python3 -c "
import json, sys
text = sys.argv[1]
blocks = [{'type': 1, 'data': {'segments': [{'type': 0, 'text': text, 'enhancer': {}}]}}]
print(json.dumps(blocks))
" "$TEXT")

        bash "$SCRIPT_DIR/buildin-pages.sh" append-blocks "$PAGE_ID" "$BLOCKS"
        ;;

    append-image)
        PAGE_ID=$(parse_id "$1")
        FILE="$2"
        CAPTION="${3:-}"
        [[ -z "$PAGE_ID" || -z "$FILE" ]] && { echo "Usage: append-image <page_id|url> <image_file> [caption]" >&2; exit 1; }
        [[ ! -f "$FILE" ]] && { echo "Error: file not found: $FILE" >&2; exit 1; }

        # Метаданные файла считаем заранее: size+sha256 нужны getS3FileUploadInfo,
        # width/height — image-блоку (без них Buildin не может посчитать layout).
        META=$(python3 -c "
import hashlib, json, os, struct, sys

data = open(sys.argv[1], 'rb').read()

def dimensions(b):
    if b[:8] == b'\x89PNG\r\n\x1a\n':
        w, h = struct.unpack('>II', b[16:24])
        return w, h, 'png', 'image/png'
    if b[:6] in (b'GIF87a', b'GIF89a'):
        w, h = struct.unpack('<HH', b[6:10])
        return w, h, 'gif', 'image/gif'
    # JPEG: размеры из SOF-маркера как есть; EXIF Orientation не учитывается —
    # портретное фото с повёрнутой матрицей получит перепутанные width/height.
    if b[:2] == b'\xff\xd8':
        i = 2
        while i < len(b) - 9:
            if b[i] != 0xFF:
                i += 1
                continue
            marker = b[i + 1]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack('>HH', b[i + 5:i + 9])
                return w, h, 'jpg', 'image/jpeg'
            i += 2 + struct.unpack('>H', b[i + 2:i + 4])[0]
        raise SystemExit('jpeg: SOF marker not found')
    if b[:4] == b'RIFF' and b[8:12] == b'WEBP':
        if b[12:16] == b'VP8X':
            return (int.from_bytes(b[24:27], 'little') + 1,
                    int.from_bytes(b[27:30], 'little') + 1, 'webp', 'image/webp')
        if b[12:16] == b'VP8 ':
            w, h = struct.unpack('<HH', b[26:30])
            return w & 0x3FFF, h & 0x3FFF, 'webp', 'image/webp'
        if b[12:16] == b'VP8L':
            bits = int.from_bytes(b[21:25], 'little')
            return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1, 'webp', 'image/webp'
        raise SystemExit('webp: unsupported variant')
    raise SystemExit('unsupported image format (png/jpg/gif/webp)')

w, h, ext, mime = dimensions(data)
print(json.dumps({
    'fileName': os.path.basename(sys.argv[1]),
    'size': len(data),
    'sha256': hashlib.sha256(data).hexdigest(),
    'width': w, 'height': h, 'extName': ext, 'mimeType': mime,
}))
" "$FILE") || exit 1

        SPACE_ID=$(get_space_id "$PAGE_ID")

        # Дедуп как в родном клиенте: перед аплоадом ищем файл по sha256+size и
        # переиспользуем существующий ossName. Проверка оппортунистическая — в наших
        # пробах ответ был пуст даже для заведомых дублей; пусто -> грузим как обычно.
        # Тело запроса — отдельной подстановкой: вложенное $(…"$(python3 -c "…{…}")"…)
        # на bash 3.2 теряет кавычки внутреннего скрипта, brace expansion режет
        # словарь и тело уходит пустым (SyntaxError + HTTP 411).
        DEDUP_BODY=$(python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
print(json.dumps({'spaceId': sys.argv[2], 'sha256': meta['sha256'], 'size': meta['size']}))
" "$META" "$SPACE_ID")
        S3_KEY=$(buildin POST "/api/search/resource" "$DEDUP_BODY" | python3 -c "import sys, json; print((json.load(sys.stdin).get('data') or {}).get('ossName') or '')" 2>/dev/null) || S3_KEY=""

        if [[ -z "$S3_KEY" ]]; then
            UPLOAD_BODY=$(python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
print(json.dumps({'spaceId': sys.argv[2], 'type': 'file',
                  'mimeType': meta['mimeType'], 'fileName': meta['fileName'],
                  'size': meta['size'], 'sha256': meta['sha256']}))
" "$META" "$SPACE_ID")
            UPLOAD_INFO=$(buildin POST "/api/upload/getS3FileUploadInfo" "$UPLOAD_BODY")
            S3_KEY=$(echo "$UPLOAD_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('s3Key',''))")
            UPLOAD_URL=$(echo "$UPLOAD_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uploadUrl',''))")
            # В stderr не печатаем весь ответ: в нём presigned URL (живёт 2 часа) — нечего
            # ему делать в логах/контексте LLM. Только code/msg.
            [[ -z "$S3_KEY" || -z "$UPLOAD_URL" ]] && { echo "Error: getS3FileUploadInfo failed: $(echo "$UPLOAD_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('code'), d.get('msg') or '')" 2>/dev/null)" >&2; exit 1; }

            # Content-Type подписан в presigned URL (SignedHeaders=content-type;host) —
            # без этого заголовка S3 отвечает 403 SignatureDoesNotMatch.
            MIME=$(echo "$META" | python3 -c "import sys,json; print(json.load(sys.stdin)['mimeType'])")
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: $MIME" --data-binary @"$FILE" "$UPLOAD_URL")
            [[ "$HTTP_CODE" != "200" ]] && { echo "Error: S3 upload failed (HTTP $HTTP_CODE)" >&2; exit 1; }
        fi

        BLOCKS=$(python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
# Схема родного клиента: в segments — имя файла, подпись — отдельным data.caption
# (текст из segments UI у image-блока не отображает).
data = {
    'segments': [{'type': 0, 'text': meta['fileName'], 'enhancer': {}}],
    'display': 'image', 'ossName': sys.argv[2],
    'width': meta['width'], 'height': meta['height'],
    'size': meta['size'], 'extName': meta['extName'],
}
if len(sys.argv) > 3 and sys.argv[3]:
    data['caption'] = [{'type': 0, 'text': sys.argv[3], 'enhancer': {}}]
print(json.dumps([{'type': 14, 'data': data}]))
" "$META" "$S3_KEY" "$CAPTION")

        bash "$SCRIPT_DIR/buildin-pages.sh" append-blocks "$PAGE_ID" "$BLOCKS"
        echo "ossName: $S3_KEY"
        ;;

    delete-block)
        BLOCK_ID=$(parse_id "$1")
        [[ -z "$BLOCK_ID" ]] && { echo "Usage: delete-block <block_id>" >&2; exit 1; }

        # Resolve the block's real parent and use it as source of truth. A wrong block_id
        # (e.g. a page_id) otherwise returns a misleading code 200; for a page that means
        # status=-1 on the page block — silently deleting the whole page.
        DETECTED_PARENT=$(buildin GET "/api/blocks/$BLOCK_ID" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('parentId',''))")
        [[ -z "$DETECTED_PARENT" ]] && { echo "Error: $BLOCK_ID not found or is a page (no parent block); refusing to delete" >&2; exit 1; }
        PARENT_ID="$DETECTED_PARENT"

        SPACE_ID=$(get_space_id "$BLOCK_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)

        OPS=$(python3 -c "
import json, sys
block_id, parent_id, now, user_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
ops = [
    {'id': block_id, 'command': 'update', 'table': 'block', 'path': [],
     'args': {'status': -1, 'updatedBy': user_id, 'updatedAt': now}},
    {'id': parent_id, 'command': 'listRemove', 'table': 'block', 'path': ['subNodes'],
     'args': {'uuid': block_id}}
]
print(json.dumps(ops))
" "$BLOCK_ID" "$PARENT_ID" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    help|*)
        echo "Buildin Pages — операции со страницами и блоками (UI API)"
        echo "Принимает page_id как UUID или URL buildin.ai"
        echo ""
        echo "Commands:"
        echo "  get <id|url>                             — получить страницу (JSON, все блоки)"
        echo "  title <id|url>                           — заголовок страницы"
        echo "  read <id|url>                            — прочитать как markdown"
        echo "  create <parent_id|url> <title>           — создать дочернюю страницу"
        echo "  update <id|url> <title>                  — обновить заголовок"
        echo "  archive <id|url>                         — архивировать (status: -1)"
        echo "  get-blocks <id|url>                      — блоки страницы (JSON; id блока в поле uuid)"
        echo "  comments <id|url[#block_id]> [block_id]  — комментарии страницы или блока (якорь #block-uuid фильтрует)"
        echo "  comment <id|url[#block_id]> [block_id] <anchor> <text>"
        echo "          [--dry-run] [--occurrence=N] [--rollback-out=<path>]"
        echo "                                           — комментарий к фразе <anchor> внутри блока"
        echo "                                             <anchor>/<text>: строка, @путь — файл, - — stdin"
        echo "                                             (@@текст — литеральный @текст; значение с ведущими"
        echo "                                              дефисами — после разделителя --)"
        echo "                                             неоднозначный якорь — отказ, см. --occurrence=N"
        echo "                                             только прозаические блоки; картинка/таблица/код — отказ"
        echo "  publish-md <id|url> <file.md> [--replace] — опубликовать markdown (по умолчанию в конец)"
        echo "  append-blocks <id|url> <json_blocks>     — добавить блоки в конец страницы"
        echo "  insert-blocks-after <id|url> <after_block_id> <json_blocks>   — вставить блоки после блока"
        echo "  insert-blocks-before <id|url> <before_block_id> <json_blocks> — вставить блоки перед блоком"
        echo "  append-text <id|url> <text>              — добавить текстовый параграф"
        echo "  append-image <id|url> <image_file> [caption] — загрузить картинку (png/jpg/gif/webp) и добавить image-блок"
        echo "  delete-block <block_id> [parent_id]      — удалить блок"
        ;;
esac
