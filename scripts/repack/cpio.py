#!/usr/bin/env python3
"""Минимальный разбор/сборка cpio newc (070701) без внешних утилит.

Разбор: walk_bytes -> list[entry]; end_offset и tail после TRAILER.
Сборка: build(entries) — все записи на месте, новые добавляются перед TRAILER.
"""
import sys


def pad4(n):
    return (4 - (n % 4)) % 4


def parse(data):
    entries = []
    i = 0
    end = None
    while i + 110 <= len(data):
        if data[i:i + 6] != b"070701":
            break
        hdr = data[i:i + 110]
        f = lambda o: int(hdr[o:o + 8], 16)
        (ino, mode, uid, gid, nlink, mtime, filesize,
         devmaj, devmin, rdevmaj, rdevmin, namesize, check) = [f(6 + 8 * k) for k in range(13)]
        name = data[i + 110:i + 110 + namesize - 1]
        hdr_len = 110 + namesize
        body = data[i + hdr_len + pad4(hdr_len):i + hdr_len + pad4(hdr_len) + filesize]
        entries.append({
            "off": i,
            "ino": ino, "mode": mode, "uid": uid, "gid": gid, "nlink": nlink,
            "mtime": mtime, "filesize": filesize, "devmaj": devmaj, "devmin": devmin,
            "rdevmaj": rdevmaj, "rdevmin": rdevmin, "check": check,
            "name": name, "data": body,
        })
        i += hdr_len + pad4(hdr_len) + filesize + pad4(filesize)
        if name == b"TRAILER!!!":
            end = i
            break
    return entries, i, end


def build(entries, trailer_name=b"TRAILER!!!"):
    out = bytearray()
    for e in entries:
        name = e["name"]
        namesize = len(name) + 1
        data = e["data"]
        filesize = len(data)
        fields = [e["ino"], e["mode"], e["uid"], e["gid"], e["nlink"], e["mtime"],
                  filesize, e["devmaj"], e["devmin"], e["rdevmaj"], e["rdevmin"],
                  namesize, e["check"]]
        out += b"070701" + b"".join(b"%08X" % v for v in fields)
        out += name + b"\0"
        out += b"\0" * pad4(110 + namesize)
        out += data
        out += b"\0" * pad4(filesize)
    return bytes(out)


def make_entry(name, data, mode=0o100755, ino=0, uid=0, gid=0, mtime=0, nlink=1):
    return {"ino": ino, "mode": mode, "uid": uid, "gid": gid, "nlink": nlink,
            "mtime": mtime, "filesize": len(data), "devmaj": 0, "devmin": 0,
            "rdevmaj": 0, "rdevmin": 0, "check": 0,
            "name": name, "data": data}


if __name__ == "__main__":
    path = sys.argv[1]
    data = open(path, "rb").read()
    entries, i, end = parse(data)
    print(f"файл: {path} ({len(data)} байт)")
    print(f"разобрано записей: {len(entries)}, дошли до offset {i}, TRAILER end={end}")
    if end is not None and end != len(data):
        print(f"ПОСЛЕ TRAILER осталось {len(data) - end} байт: {data[end:end+32]!r}")
    for e in entries:
        if b"/dracut/hooks" in e["name"]:
            print(f"  {oct(e['mode'])} {e['filesize']:>9} {e['name'].decode()}")
    names = [e["name"].decode(errors="replace") for e in entries]
    print("TRAILER есть:", any(n == "TRAILER!!!" for n in names))
    print("последние 5 записей:", names[-5:])
