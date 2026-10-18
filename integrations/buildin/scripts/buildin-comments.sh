#!/bin/bash
# Buildin Comments — комментарии через UI API: треды на фразах блоков, ответы,
# резолв и откат. Обычно вызывается через buildin-pages.sh — тот передаёт сюда
# команды комментариев как есть, поэтому оба вызова равнозначны:
#   ./buildin-pages.sh comment <args...>
#   ./buildin-comments.sh comment <args...>
#
# Commands:
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

# pipefail обязателен вместе с JSON-отказом из buildin.sh: без него сбой клиента
# в конвейере `buildin ... | python3` маскируется нулевым статусом питона,
# который теперь честно разбирает тело ошибки и завершается успешно.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=buildin-lib.sh
source "$SCRIPT_DIR/buildin-lib.sh"

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

# Список команд для справки — одна копия на оба скрипта: buildin-pages.sh
# берёт его отсюда подкомандой commands.
print_commands() {
    echo "  comments <id|url[#block_id]> [block_id]  — комментарии страницы или блока (якорь #block-uuid фильтрует)"
    echo "  comment <id|url[#block_id]> [block_id] <anchor> <text>"
    echo "          [--dry-run] [--occurrence=N] [--rollback-out=<path>]"
    echo "                                           — комментарий к фразе <anchor> внутри блока"
    echo "                                             <anchor>/<text>: строка, @путь — файл, - — stdin"
    echo "                                             (@@текст — литеральный @текст; значение с ведущими"
    echo "                                              дефисами — после разделителя --)"
    echo "                                             неоднозначный якорь — отказ, см. --occurrence=N"
    echo "                                             только прозаические блоки; картинка/таблица/код — отказ"
}

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
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

    commands)
        print_commands
        ;;

    help|*)
        echo "Buildin Comments — комментарии к фразам внутри блоков (UI API)"
        echo "Принимает page_id как UUID или URL buildin.ai"
        echo ""
        echo "Commands:"
        print_commands
        ;;
esac
