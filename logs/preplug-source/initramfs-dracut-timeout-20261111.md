# Транскрипция фото экрана RP6 — `IMG_20261111_173458.jpg`

Источник: `/tmp/opencode/uploads/10fb8dbdfbcff/IMG_20261111_173458.jpg` (3472x4624, фото экрана).
Метод: `tesseract 5.5.4` (распакован локально из rpm, без root), `-l eng+rus`, несколько препроцессингов
(gray / autocontrast / invert / crop+2x). Полный сырой OCR: `ocr-IMG_20261111_173458.raw.txt`.

> ⚠️ Фото экрана — OCR шумный. Ниже — восстановленный смысл + отдельно помечено, что прочитано уверенно, а что нет.
> Это **initramfs-загрузка (dracut) с флешки**, НЕ полная система.

## Что видно на экране

### 1. PPM ULog (`ARMADA-B USB: ...`) — fingerprint = source-role, `usb_type=Unknown`

Повторяющиеся строки вида (≈85…139 с):

```
[ 85.9730] ARMADA-B status: up=86s ulog_ok=1 seen=28 usb_type=[Unknown] SDP DCP CDP ACA C PD PD_DRP PD_PPS BrickID online=0 V=5067000 src=[C] PD PD_PPS src_on=
[ 99.207026] ARMADA-B ULOG: ncp_stby_db_log: ... chgr_stat=...
[126.248446] ARMADA-B ... seen=29 usb_type=[Unknown] SDP DCP CDP ACA C PD PD_DRP ...
[134.742848] ARMADA-B USB: usb_type=[Unknown] SDP DCP CDP ACA C PD PD_DRP PD_PPS BrickID online=0 V=5065000 src=[C] PD PD_PPS src_on= power=[source] sink data=[host] device partner=yes
[136.980411] ARMADA-B USB: usb_type=[Unknown] SDP DCP CDP ACA C PD PD_DRP PD_PPS BrickID online=0 V=5067000 src=[C] PD PD_PPS src_on= ...
[139.257865] ARMADA-B status: up=139s seen=30 usb_type=[Unknown] SDP DCP CDP ACA C PD PD_DRP PD_PPS BrickID online=0 ...
```

Уверенно читается:
- `usb_type=[Unknown]` — значение порта = Unknown (0).
- `src=[C]` — роль source, `PD PD_PPS src_on=` — активен PPS-контракт.
- `power=[source] sink data=[host] device` — роль данных host.
- `partner=yes` — партнёр определён.
- `online=0 V=5067000` (≈5.07 В), `BrickID online=0`.
- счётчик `seen=28…30`, `ulog_ok=1`, `ncp_stby` в ULog.

Т.е. **тот же fingerprint, что dbgB и source-role полная система**: `usb_type=Unknown` + `src=[C]` + `ncp_stby`.

Неуверенно: две строки (≈138.24 и ≈139.23 с) OCR прочитал как `usb_type=3`, но соседние строки — `[Unknown]`.
Скорее всего артефакт OCR (в остальных местах значение читается как `[Unknown]`); если это реально `3` — это `CDP`,
но подтверждения из строк нет. **Не считать измерением.**

### 2. dracut-initqueue — таймаут, корень по UUID не найден

Начиная с ≈141 с и далее каждые ~0.6 с:

```
[141.017935] dracut-initqueue[523]: Warning: dracut-initqueue: timeout, still waiting for following initqueue hooks:
[141.022031] dracut-initqueue[523]: Warning: /lib/dracut/hooks/initqueue/finished/devexists-\x2fdev\x2fd isk\x2fby-uu id\x2f49a99c0a-3e... :
             "if ! grep -qs ... After=remote-fs-pre.target ...; then
[141.062811] dracut-initqueue[523]:   -e "/dev/disk/by-uuid/49a99c0a-3e...
[141.063...] dracut-initqueue[523]: fi"
[141.583555] dracut-initqueue[523]: Warning: dracut-initqueue: starting timeout scripts
...
[145.159790] dracut-initqueue[523]: Warning: dracut-initqueue: starting timeout scripts
```

Уверенно читается:
- hook `devexists-/dev/disk/by-uuid/49a99c0a-3e...` — ждём появления раздела с **UUID `49a99c0a-3e…`**.
- сообщение циклится: `timeout, still waiting for following initqueue hooks:` → `starting timeout scripts`
  (типовое поведение dracut при отсутствии корневого устройства).

Смысл: **initramfs ждёт USB-корень по UUID `49a99c0a-3e…`, флешка не перечислилась → dracut крутит timeout.**

## Вывод
- Фото подтверждает **failing-side initramfs**: `usb_type=Unknown` / source-role / `ncp_stby` (fingerprint dbgB) +
  dracut вечно ждёт `/dev/disk/by-uuid/49a99c0a-3e…`.
- Это ровно тот сценарий, который лечит **lever C** (post-PDR rebind xHCI внутри initramfs): если после PDR флешка
  перечислится, hook `devexists` сразу удовлетворится и dracut найдёт корень.
