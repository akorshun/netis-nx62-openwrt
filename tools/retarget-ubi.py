#!/usr/bin/env python3
"""Меняет размер раздела ubi в DTB внутри готового sysupgrade-образа (FIT).

Образ не пересобирается: правятся ровно четыре байта в device tree и
пересчитываются контрольные суммы его image-узла в FIT.

Запуск: retarget_ubi.py <вход.itb> <выход.itb> <размер ubi в КБ>
"""

import hashlib
import struct
import sys
import zlib

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def walk(blob, base=0):
    """Свойства FDT: (путь_узла, имя, смещение_данных, длина)."""
    magic, totalsize, off_struct, off_strings = struct.unpack_from(">IIII", blob, base)
    if magic != 0xD00DFEED:
        raise ValueError("не FDT: magic %#x" % magic)
    out, pos, path = [], base + off_struct, []
    while True:
        tag, = struct.unpack_from(">I", blob, pos)
        pos += 4
        if tag == FDT_BEGIN_NODE:
            end = blob.index(b"\x00", pos)
            path.append(blob[pos:end].decode())
            pos = (end + 4) & ~3
        elif tag == FDT_END_NODE:
            path.pop()
        elif tag == FDT_PROP:
            length, nameoff = struct.unpack_from(">II", blob, pos)
            pos += 8
            ns = base + off_strings + nameoff
            name = blob[ns:blob.index(b"\x00", ns)].decode()
            out.append(("/" + "/".join(p for p in path if p), name, pos, length))
            pos = (pos + length + 3) & ~3
        elif tag == FDT_NOP:
            continue
        elif tag == FDT_END:
            return out, totalsize
        else:
            raise ValueError("неизвестный тег %d" % tag)


def prop(props, node, name):
    for path, pname, off, length in props:
        if path == node and pname == name:
            return off, length
    return None, None


def partitions(dtb):
    """Разделы из DTB: (узел, метка, смещение reg, offset, size)."""
    props, _ = walk(dtb)
    out = []
    for path, name, off, length in props:
        if name != "reg" or length != 8 or "partition" not in path.rsplit("/", 1)[-1]:
            continue
        start, size = struct.unpack_from(">II", dtb, off)
        loff, llen = prop(props, path, "label")
        label = dtb[loff:loff + llen].split(b"\x00")[0].decode() if loff else "?"
        out.append((path, label, off, start, size))
    return out


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    src, dst, want_kb = sys.argv[1], sys.argv[2], int(sys.argv[3])
    blob = bytearray(open(src, "rb").read())
    props, _ = walk(blob)

    pos_off, _ = prop(props, "/images/fdt-1", "data-position")
    size_off, _ = prop(props, "/images/fdt-1", "data-size")
    if pos_off is None:
        raise SystemExit("в FIT нет /images/fdt-1 с внешними данными")
    dtb_at, = struct.unpack_from(">I", blob, pos_off)
    dtb_len, = struct.unpack_from(">I", blob, size_off)
    dtb = bytearray(blob[dtb_at:dtb_at + dtb_len])
    print("DTB в образе: смещение %#x, размер %d байт" % (dtb_at, dtb_len))

    print("разделы до правки:")
    target = None
    for path, label, off, start, size in partitions(dtb):
        print("   %-12s %#010x + %-10s (%d КБ)" % (label, start, hex(size), size // 1024))
        if label == "ubi":
            target = (path, off, start, size)
    if target is None:
        raise SystemExit("в DTB нет раздела с label = ubi")

    path, off, start, old_size = target
    new_size = want_kb * 1024
    if new_size % 0x20000:
        raise SystemExit("размер %d КБ не кратен блоку 128 КБ" % want_kb)
    # reg = <смещение размер>: правим вторую ячейку
    struct.pack_into(">I", dtb, off + 4, new_size)
    print("ubi: %d КБ -> %d КБ (конец %#x)" % (old_size // 1024, want_kb, start + new_size))

    blob[dtb_at:dtb_at + dtb_len] = dtb

    # Контрольные суммы image-узла: значения фиксированной длины, правим на месте.
    for node in ("/images/fdt-1/hash-1", "/images/fdt-1/hash-2", "/images/fdt-1/hash-3"):
        aoff, alen = prop(props, node, "algo")
        voff, vlen = prop(props, node, "value")
        if aoff is None:
            continue
        algo = blob[aoff:aoff + alen].split(b"\x00")[0].decode()
        if algo == "crc32":
            new = struct.pack(">I", zlib.crc32(dtb) & 0xFFFFFFFF)
        elif algo == "sha1":
            new = hashlib.sha1(dtb).digest()
        elif algo == "sha256":
            new = hashlib.sha256(dtb).digest()
        else:
            raise SystemExit("неизвестный алгоритм хеша: %s" % algo)
        if len(new) != vlen:
            raise SystemExit("длина хеша %s не совпала: %d вместо %d" % (algo, len(new), vlen))
        print("%s: %s %s -> %s" % (node, algo, blob[voff:voff + vlen].hex(), new.hex()))
        blob[voff:voff + vlen] = new

    open(dst, "wb").write(blob)
    print("записан %s (%d байт)" % (dst, len(blob)))

    # Самопроверка: перечитываем результат.
    check = bytearray(open(dst, "rb").read())
    cprops, _ = walk(check)
    cdtb = check[dtb_at:dtb_at + dtb_len]
    print("проверка разделов в результате:")
    for _, label, _, cstart, csize in partitions(cdtb):
        print("   %-12s %#010x + %-10s (%d КБ)" % (label, cstart, hex(csize), csize // 1024))
    for node in ("/images/fdt-1/hash-1", "/images/fdt-1/hash-2"):
        aoff, alen = prop(cprops, node, "algo")
        voff, vlen = prop(cprops, node, "value")
        if aoff is None:
            continue
        algo = check[aoff:aoff + alen].split(b"\x00")[0].decode()
        want = {"crc32": struct.pack(">I", zlib.crc32(cdtb) & 0xFFFFFFFF),
                "sha1": hashlib.sha1(cdtb).digest(),
                "sha256": hashlib.sha256(cdtb).digest()}[algo]
        state = "OK" if check[voff:voff + vlen] == want else "НЕ СОВПАЛ"
        print("   %s (%s): %s" % (node, algo, state))
    return 0


if __name__ == "__main__":
    sys.exit(main())
