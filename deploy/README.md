# Развёртывание

Что грузить на сервер, как это запустить и как вывести наружу через Cloudflare Tunnel.

Текущий production использует отдельный main и два relay-узла. Его WireGuard,
nginx, Multi-hop и Tor-схема описаны в [mesh/README.md](mesh/README.md). Инструкция
ниже остаётся полезной для одиночной установки и для внутренней службы на main.

## 1. Что грузить

Ровно содержимое `valanium-server/`, и **только** эти файлы:

```
src/                 исходники (TypeScript выполняется Node напрямую, сборки нет)
package.json
package-lock.json
tsconfig.json        только для `npm run check` на копии разработчика
.npmrc               engine-strict: отказ при неподходящей версии Node
.env.example
README.md
```

Что **не** грузить:

| | почему |
|---|---|
| `node_modules/` | ставится на сервере через `npm ci` — иначе приедут бинари не под ту платформу |
| `data/` | это ваша база и вложения; на сервере она своя |
| `.env` | там админский токен, ему место только на сервере |
| `valanium-core/`, клиенты | серверу они не нужны и не должны там лежать |

Готовый архив собирается скриптом:

```powershell
deploy\package.ps1
```

Он кладёт `deploy/dist/valanium-server-<дата>.zip` — этот файл и есть то, что уезжает на сервер.

## 2. Установка

Нужен **Node 24 или новее** — сервер опирается на встроенный `node:sqlite`, разбор TypeScript без сборки и `--env-file-if-exists`.

**Сначала проверьте, какой node вы зовёте.** Системный часто старее 24:

```bash
node -v            # системный
/opt/node-24/bin/node -v   # тот, что нужен серверу
```

Ставить нужно тем же npm, что лежит рядом с Node 24. `.npmrc` в архиве включает
`engine-strict`, поэтому установка старым npm просто откажет и назовёт причину —
это лучше, чем невнятный `SyntaxError` в `.ts` при первом запуске.

```bash
unzip valanium-server-*.zip -d /opt/valanium
cd /opt/valanium

sudo /opt/node-24/bin/npm ci --ignore-scripts --omit=optional --omit=dev
cp .env.example .env
sudo chown -R root:root /opt/valanium
sudo install -d -o valanium -g valanium -m 0750 /opt/valanium/data
sudo chown root:valanium /opt/valanium/.env
sudo chmod 0640 /opt/valanium/.env
sudo chmod -R go-w /opt/valanium
```

`sudo` и `chown` здесь не формальность: каталог принадлежит пользователю
`root`, который выкладывает релиз, а `npm ci` первым делом сносит
`node_modules` целиком. Из-под своей учётки вы получите `EACCES` на
`node_modules/.bin`.

Каждый флаг тут по делу:

| | |
|---|---|
| `--ignore-scripts` | установка пакета не выполняет чужие скрипты |
| `--omit=optional` | пропускает пакеты TON: платный вход выключен, без них сервер работает по инвайтам |
| `--omit=dev` | на боевой машине не нужен компилятор TypeScript — сервер выполняет исходники напрямую, а лишний инструмент это лишняя поверхность |

С этими флагами ставится ровно два пакета верхнего уровня: `uWebSockets.js` и `@noble/*`.

`npm run check` — команда машины разработчика, а не сервера: без dev-зависимостей `tsc` там просто нет.

В `.env` меняем как минимум:

```ini
VALANIUM_HOST=127.0.0.1        # наружу торчит cloudflared, а не сервер
VALANIUM_PORT=8787
VALANIUM_SECRET_KEY=           # пусто = ключ заведётся сам в data/secret.key
```

**Про `data/secret.key`.** Им закрыты секреты вторых факторов. Он заводится сам
при первом запуске и лежит рядом с базой, но в снимки `npm run backup` не
попадает — иначе утёкший бэкап отдал бы и базу, и ключ к ней. Сохраните его
отдельно: база, восстановленная без этого файла, вернёт всё, кроме вторых
факторов.

**`VALANIUM_HOST` обязан остаться `127.0.0.1`.** Ограничение частоты попыток входа доверяет заголовку `cf-connecting-ip`, а его подделает кто угодно, если до сервера можно достучаться напрямую.

Проверка:

```bash
node src/index.ts
# ожидаем: INFO ton entry disabled, invites only
#          INFO valanium-server up port=8787 heartbeatSec=30
```

## 2a. Выпуск сборок

Собранный файл сам по себе ничем не подтверждён: кто получил сервер, Cloudflare
или любой удостоверяющий центр, тот подменяет его на своей стороне, и человек
скачивает троян с правильного адреса. Поэтому версии и хеши подписываются
ключом, которого на сервере нет.

```bash
node deploy/sign-release.mjs windows 0.11.0 release/Valanium-Portable-Windows-0.11.0.exe                              android 0.6.2 release/Valanium-Android-arm64-0.6.2.apk
```

Получившийся `deploy/releases.json` кладётся на сервер в `data/releases.json`,
рядом с базой. Сервер отдаёт его строкой байт в байт: пересобирать манифест ему
нельзя — подпись перестанет сходиться.

Приватный ключ лежит в `~/.valanium-release/signing.key` и в репозиторий не
попадает **никогда**. Открытая половина зашита в клиент (`RELEASE_PUBLIC_KEY` в
`valanium-windows/src-tauri/src/main.rs`). Потеряете ключ — придётся выпустить
клиент с новым: до тех пор обновления не будут подтверждаться, и окно честно
скажет об этом вместо того, чтобы вести человека за неподтверждённой сборкой.

## 3. Автозапуск

**Linux (systemd):** в юнитах прописан `/usr/bin/node`. Если системный node старее 24 — а это обычное дело, — путь нужно подменить, иначе служба упадёт на разборе `.ts`:

```bash
sudo cp systemd/valanium*.service systemd/*.timer /etc/systemd/system/
sudo sed -i 's|/usr/bin/node|/opt/node-24/bin/node|' /etc/systemd/system/valanium*.service

sudo systemctl daemon-reload
sudo systemctl enable --now valanium
sudo journalctl -u valanium -f
```

Юнит намеренно ужат: свой пользователь, `NoNewPrivileges`, только своя папка на запись. Мессенджер не должен иметь доступа ни к чему, кроме своей базы.

**Windows:** запланированная задача при старте системы —

```powershell
deploy\windows\install-task.ps1 -Root C:\valanium
```

## 4. Cloudflare Tunnel

```bash
cloudflared tunnel login
cloudflared tunnel create valanium
cloudflared tunnel route dns valanium valanium.example.com
```

Конфиг — [cloudflared/config.example.yml](cloudflared/config.example.yml), положить в `~/.cloudflared/config.yml` и подставить свои id и домен. Затем:

```bash
sudo cloudflared service install
```

Проверка снаружи: `https://valanium.example.com/v1/health` отвечает `{"ok":true,"v":1}`.

### Обязательно про WebSocket

В панели Cloudflare: **Network → WebSockets → On.** Без этого соединение не установится вообще, а симптом будет невнятный.

Cloudflare рвёт WebSocket после ~100 секунд тишины — клиент шлёт PING каждые 30 секунд именно поэтому. Менять `VALANIUM_HEARTBEAT_SEC` выше 45 нельзя.

## 5. Cloudflare Access

Третий слой закрытого доступа: незалогиненный запрос не доходит до домашнего сервера вообще — это
защищает и от сканеров, и от возможной дыры в самом сервере.

Ядро отправлять service token **умеет** (`valanium-core/src/edge.rs`). Включение — ручное, и
порядок шагов здесь важнее самих шагов.

### 5.1. Что закрывать, а что нельзя

Приложение Access должно накрывать **только** `valanium.com/ws` — и, если хотите,
`valanium.com/v1/admin`.

Накрыть хост целиком нельзя. За тем же именем живут:

| Путь | Что сломается |
|---|---|
| `/` | сайт перестанет открываться у всех |
| `/downloads/` | скачать клиент будет неоткуда |
| `/v1/releases/latest` | проверка обновлений; **старые клиенты потеряют её навсегда** |
| `/v1/health` | туннель и мониторинг перестанут видеть живость |

Последняя строка — самая дорогая ошибка: клиент, который не может ни подключиться, ни узнать о
новой версии, чинится только тем, что человек сам зайдёт на сайт. Которого он тоже не увидит.

### 5.2. Порядок включения

Access отсекает **любой** клиент без токена, включая все уже разошедшиеся сборки. Поэтому:

1. Zero Trust → Access → Applications → Self-hosted, путь `valanium.com/ws`,
   политика `Service Auth` → Service Token. Создать токен, забрать `Client ID` и `Client Secret`.
2. Собрать клиент с токеном:

   ```powershell
   $env:VALANIUM_ACCESS_CLIENT_ID = "....access"
   $env:VALANIUM_ACCESS_CLIENT_SECRET = "...."
   cargo build --release
   ```

   Переменные читаются при компиляции. За их сменой следит `valanium-core/build.rs`: без него
   cargo решил бы, что пересобирать нечего, и выдал бы бинарь со старым токеном.
3. Выложить сборку, обновить `/v1/releases/latest` и **дождаться**, пока люди обновятся.
4. Только теперь включать политику.

Пропустить третий шаг — значит отрезать всех, кто не успел обновиться, без способа сообщить им об
этом.

### 5.3. Смена токена

Cloudflare допускает несколько живых service token'ов одновременно. Меняются они так: завести
новый, собрать и раздать клиент с ним, дождаться перехода, и только потом отозвать старый. Отзыв
первым шагом — это тот же обрыв, что и в 5.2.

### 5.4. Чем этот токен не является

Он **один на все сборки и лежит внутри клиента**, который любой может скачать и разобрать. Это не
пароль и не заменяет ни инвайт, ни подпись на каждое соединение. Его работа — отсечь ботов и
сканеры до того, как их запрос коснётся нашего кода. От целевой атаки он не защищает, и относиться
к нему как к секрету не нужно: ровно поэтому его допустимо вкомпилировать в клиент, а ключи
личности — нет и никогда.

Для своего релея, где Cloudflare нет вовсе, токен не задаётся: заголовки просто не добавляются, и
клиент ходит как раньше. Переменные окружения на запущенном клиенте перекрывают вкомпилированный
токен — так проверяется стенд без пересборки.

## 6. Первый пользователь

Открытой регистрации нет:

```bash
cd /opt/valanium
node src/tools/invite.ts
# invite: 7f3a91c4e2b8d05a6f1e9c3d
# expires: 2026-08-30T12:00:00.000Z
```

Код печатается один раз, в базе лежит только его SHA-256. Потеряли — выпускайте новый.

В клиенте: адрес `wss://valanium.example.com/ws`, имя, этот код.

**Инвайт — это пропуск, обращаться с ним как с паролем.** Не пересылайте его в переписке, чатах поддержки и скриншотах: до использования им может воспользоваться любой, кто увидел. Если код куда-то утёк:

```bash
node src/tools/revoke.ts <код>
```

Отзыв работает по самому коду: в базе лежит только его SHA-256, и узнать по базе, какой код за какой строкой, невозможно — это и было целью. Код возврата 0 — отозвали, 1 — такого кода уже нет.

## 7. Бэкап

`data/` не бэкапится сам по себе. Что это даёт и чего не даёт:

- **не спасёт переписку** — у сервера нет ключей, в очереди только шифротекст;
- **спасёт регистрации** — без базы все устройства станут серверу неизвестны, и людям придётся заходить заново по новым инвайтам.

Обычным `cp` копировать нельзя: база в режиме WAL, и файл, снятый во время записи, окажется битым. Инструмент делает `VACUUM INTO` — консистентный снимок на работающем сервере:

```bash
sudo mkdir -p /var/backups/valanium && sudo chown valanium: /var/backups/valanium
sudo systemctl enable --now valanium-backup.timer
```

Раз в сутки, 14 снимков, старые чистятся сами (`VALANIUM_BACKUP_KEEP`). Разовый прогон: `node src/tools/backup.ts /var/backups/valanium`.

### 7a. Копия вне main

Снимки выше лежат на том же диске, что и оригинал. Это спасает от испорченной
базы, но не от потери машины: умрёт main — умрут и копии. Поэтому снимок ещё и
уезжает на второй узел, зашифрованным.

Приёмник — relay, доверенным хранилищем он не является, а в базе метаданные
открытым текстом: ключи личностей, chat code, хеши имён. Значит, туда должен
приезжать шифротекст, ключа от которого на relay нет.

**Ключ.** Генерируется один раз, приватная половина не остаётся ни на одном
сервере — иначе смысла в шифровании нет. Расшифровать копию нужно будет тогда,
когда main уже не существует.

```bash
apt-get install -y age
age-keygen -o /root/age-identity.txt
grep '^# public key:' /root/age-identity.txt | sed 's/# public key: //' \
  > /opt/valanium/backup-recipient.pub
```

Заберите `/root/age-identity.txt` к себе (`scp`), проверьте, что файл дошёл, и
**только потом** удалите его с сервера: `shred -u /root/age-identity.txt`.
Держите не одну копию — потеряете ключ, и все отправленные архивы станут
нечитаемым мусором.

**Приёмник.** Отдельный непривилегированный пользователь и forced command:
класть можно, читать и удалять нельзя. Захваченный main не вычитает то, что
сам же отправил, и не сотрёт историю копий.

```bash
useradd -r -m -d /var/lib/valbackup -s /bin/sh valbackup
install -d -o valbackup -g valbackup -m 700 \
  /var/backups/valanium-remote /var/lib/valbackup/.ssh
# сюда — публичный ключ из /opt/valanium/.ssh/id_backup.pub, созданного ниже
cat >> /var/lib/valbackup/.ssh/authorized_keys <<'EOF'
from="10.77.0.1",restrict,command="/usr/bin/rrsync -wo /var/backups/valanium-remote" ssh-ed25519 AAAA... valanium-backup-main
EOF
chown valbackup: /var/lib/valbackup/.ssh/authorized_keys
chmod 600 /var/lib/valbackup/.ssh/authorized_keys
```

**Если на приёмнике есть fail2ban — внесите сеть в исключения сразу.** Каждая
отбитая forced command выглядит для `sshd` неудачным заходом, и в
`mode = aggressive` этого хватает, чтобы забанить собственный main. Отправка
тогда встаёт, а снаружи всё выглядит здоровым: `ping` проходит, `sshd` active,
и причина видна только в правилах `nftables`.

```bash
cp fail2ban/valanium-ignore.conf /etc/fail2ban/jail.d/
systemctl reload fail2ban
fail2ban-client get sshd ignoreip   # 10.77.0.0/24 обязан быть в списке
```

Ротация на приёмнике — своя: удалять по `rsync` оттуда нельзя, и это намеренно.

```bash
printf '#!/bin/sh\nls -1t /var/backups/valanium-remote/*.age 2>/dev/null | tail -n +31 | xargs -r rm -f\n' \
  > /usr/local/bin/valanium-remote-rotate.sh
chmod 755 /usr/local/bin/valanium-remote-rotate.sh
printf '17 1 * * * root /usr/local/bin/valanium-remote-rotate.sh\n' \
  > /etc/cron.d/valanium-remote-rotate
```

**Отправитель.** Прав root не нужно: всё нужное доступно пользователю
`valanium`. Хост закрепляется заранее — принимать ключ на лету значило бы
соглашаться с кем угодно, кто окажется на этом адресе.

```bash
install -d -o valanium -g valanium -m 700 \
  /opt/valanium/.ssh /var/backups/valanium-outbox
sudo -u valanium ssh-keygen -q -t ed25519 -f /opt/valanium/.ssh/id_backup -N '' \
  -C valanium-backup-main
ssh-keyscan -H 10.77.0.3 > /opt/valanium/.ssh/known_hosts
chown valanium: /opt/valanium/.ssh/known_hosts

install -m 755 valanium-offsite.sh /usr/local/bin/valanium-offsite.sh
cp systemd/valanium-offsite.service /etc/systemd/system/
systemctl daemon-reload
```

Отправка привязана к снимку через `OnSuccess=` в `valanium-backup.service`:
отправлять нечего, пока снимок не снят. Проверка — под тем самым пользователем,
до всякой автоматики:

```bash
sudo -u valanium /usr/local/bin/valanium-offsite.sh   # ждём «отправлено»
systemctl start valanium-backup.service
systemctl show valanium-backup.service valanium-offsite.service -p Result
```

**И проверьте, что копия открывается вашим ключом.** Бэкап, который ни разу не
открывали, — это надежда, а не бэкап. На своей машине, не на сервере:

```bash
scp <приёмник>:/var/backups/valanium-remote/<файл> .
age -d -i age-identity.txt -o proba.tar.zst <файл>
tar -tf proba.tar.zst        # внутри обязан быть valanium.db
```

## 8. Обновление

```bash
sudo systemctl stop valanium

# распаковать новый архив поверх, data/ не трогать
cd /opt/valanium
sudo /opt/node-24/bin/npm ci --ignore-scripts --omit=optional --omit=dev
sudo chown -R root:root /opt/valanium
sudo chown -R valanium:valanium /opt/valanium/data
sudo chown root:valanium /opt/valanium/.env
sudo chmod 0755 /opt/valanium
sudo chmod 0750 /opt/valanium/data
sudo chmod 0640 /opt/valanium/.env
sudo chmod -R go-w /opt/valanium

sudo systemctl start valanium
```

`cd` здесь обязателен: без него `npm ci` не найдёт `package-lock.json` и
пожалуется, что его нет вовсе.

База переживает обновление. Очередь недоставленных конвертов — не всегда: при смене схемы она сносится осознанно, это транзитная очередь с TTL, а не архив.

## 9. Что проверить после запуска

- [ ] `/v1/health` отвечает снаружи
- [ ] в панели Cloudflare WebSockets включены
- [ ] `VALANIUM_HOST=127.0.0.1`, порт снаружи напрямую не открыт
- [ ] `.env` не читается посторонними (`chmod 600`)
- [ ] `valanium-backup.timer` включён (`systemctl list-timers valanium-backup`)
- [ ] в логах нет ни pubkey, ни handle, ни IP — если появились, это баг
