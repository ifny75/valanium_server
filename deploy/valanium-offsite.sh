#!/bin/bash
#
# Отправка снимка базы на второй узел — зашифрованной.
#
# Зачем вообще. Снимки лежали рядом с оригиналом, на том же диске. Это спасает
# от испорченной базы, но не от потери машины: умрёт main — умрут и копии.
# Настоящий бэкап обязан пережить смерть того, что он копирует.
#
# Почему шифруем. Узел, который принимает копию, — relay. По нашей же модели
# угроз он доверенным хранилищем не является, а в базе метаданные открытым
# текстом: ключи личностей, chat code, хеши имён. Поэтому туда уезжает
# шифротекст, и ключа для него на relay нет.
#
# Ключа нет и здесь. Шифруем публичной половиной age, приватная лежит у
# владельца вне серверов. Захвативший main не прочитает то, что main же и
# отправил; а главное — расшифровать можно тогда, когда main уже нет, ради
# чего всё и затевалось.
#
# Обратный канал закрыт: на той стороне forced command `rrsync -wo`, класть
# можно, читать и удалять нельзя. Ротацией занимается сам приёмник.
#
# Прав root не нужно и быть не должно: всё, что читается, и так доступно
# пользователю `valanium`, под которым идёт снимок. Юнит поэтому тоже
# непривилегированный — см. systemd/valanium-offsite.service.

set -euo pipefail

SNAPSHOTS=/var/backups/valanium
OUTBOX=/var/backups/valanium-outbox
RECIPIENT_FILE=/opt/valanium/backup-recipient.pub
SSH_KEY=/opt/valanium/.ssh/id_backup
KNOWN_HOSTS=/opt/valanium/.ssh/known_hosts
REMOTE=obsbackup@10.77.0.3

[ -s "$RECIPIENT_FILE" ] || { echo "нет публичного ключа: $RECIPIENT_FILE" >&2; exit 1; }
[ -r "$SSH_KEY" ] || { echo "нет ключа доступа: $SSH_KEY" >&2; exit 1; }

# Берём последний готовый снимок, а не делаем свой: VACUUM INTO уже отработал
# в valanium-backup.service, и второй проход стоил бы лишнего чтения базы.
newest=$(ls -1 "$SNAPSHOTS" 2>/dev/null | sort | tail -1)
[ -n "$newest" ] || { echo "снимков нет в $SNAPSHOTS" >&2; exit 1; }

mkdir -p "$OUTBOX"
chmod 700 "$OUTBOX"
archive="$OUTBOX/valanium-$newest.tar.zst.age"

# Чистим за собой при любом исходе: незашифрованного здесь не остаётся никогда,
# а место на main не расходуется впустую.
cleanup() { rm -f "$archive"; }
trap cleanup EXIT

# tar | zstd | age одним конвейером: открытый архив на диск не ложится вовсе.
tar -C "$SNAPSHOTS" -cf - "$newest" \
  | zstd -q -3 \
  | age -r "$(cat "$RECIPIENT_FILE")" -o "$archive"

size=$(stat -c %s "$archive")
[ "$size" -gt 0 ] || { echo "архив пуст" >&2; exit 1; }

# Проверяем, что это действительно шифротекст age, а не случайно уехавший
# открытый tar. Дешевле, чем однажды обнаружить обратное на чужом диске.
head -c 22 "$archive" | grep -q "age-encryption.org" || {
  echo "получившийся файл не похож на шифротекст age — не отправляю" >&2
  exit 1
}

# Хост закреплён заранее (см. deploy/README.md): принимать ключ на лету значило
# бы соглашаться с кем угодно, кто окажется на этом адресе.
rsync -q --timeout=120 \
  -e "ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=$KNOWN_HOSTS" \
  "$archive" "$REMOTE:"

# Отметка об успехе. Прочитать приёмник мы не можем — канал туда
# односторонний намеренно, — поэтому единственный способ узнать, что копия
# уехала, это записать факт здесь. Самопроверка смотрит на свежесть этой
# отметки: без неё «отправка встала» неотличимо от «всё хорошо».
MARK=/opt/valanium/data/offsite
mkdir -p "$MARK"
: > "$MARK/last"

echo "отправлено: $(basename "$archive") ($((size / 1024)) КБ) -> $REMOTE"
