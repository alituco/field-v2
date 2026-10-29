#!/usr/bin/env python3
"""Validate public bundletool dumps and stream-check native AAB libraries.

This checks release metadata and binary layout, not runtime 16 KB compatibility,
APK ZIP alignment, signing identity, or behavior. Those are separate release gates.
No archive contents are extracted and no supplied paths or dump contents are logged.
"""
import argparse
import json
from pathlib import Path
import re
import stat
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile

ANDROID = '{http://schemas.android.com/apk/res/android}'
PACKAGE = 'gg.fieldrush.app'
CALLBACK_SCHEME = 'com.alialtaraif.field'
PAGE = 16384
ABIS = {'armeabi-v7a': (1, 40), 'arm64-v8a': (2, 183), 'x86_64': (2, 62)}
PT_LOAD, PT_GNU_RELRO, PF_W = 1, 0x6474E552, 2
MAX_TEXT = 2 * 1024 * 1024
MAX_NATIVE = 512 * 1024 * 1024
MAX_NATIVE_TOTAL = 1024 * 1024 * 1024
CHUNK = 64 * 1024


class InvalidArtifact(Exception):
    pass


def require(condition, message):
    if not condition:
        raise InvalidArtifact(message)


class Parser(argparse.ArgumentParser):
    def error(self, _message):
        self.exit(2, 'Invalid Android validator arguments.\n')


def regular_file(path):
    require(stat.S_ISREG(path.lstat().st_mode), 'Input must be a regular file, not a symlink.')


def read_text(path):
    regular_file(path)
    require(path.stat().st_size <= MAX_TEXT, 'Input metadata exceeds the size limit.')
    return path.read_text(encoding='utf-8')


def number(value):
    require(isinstance(value, str) and re.fullmatch(r'(?:0[xX][0-9a-fA-F]+|[0-9]+)', value),
            'Invalid numeric release metadata.')
    return int(value, 16 if value.lower().startswith('0x') else 10)


def object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate bundle configuration field.')
        result[key] = value
    return result


def validate_bundle_config(path):
    config = json.loads(read_text(path), object_pairs_hook=object_without_duplicates)
    require(isinstance(config, dict) and isinstance(config.get('optimizations'), dict),
            'Bundle optimization configuration is missing.')
    native = config['optimizations'].get('uncompressNativeLibraries')
    require(isinstance(native, dict), 'Bundle native-library configuration is missing.')
    require(native.get('enabled') is True, 'Bundle must enable uncompressed native libraries.')
    require(native.get('alignment') == 'PAGE_ALIGNMENT_16K',
            'Bundle must request PAGE_ALIGNMENT_16K.')


def validate_badging(path, version, code):
    lines = read_text(path).splitlines()
    packages = [line for line in lines if line.startswith('package: ')]
    labels = [line for line in lines if line.startswith('application-label:')]
    require(len(packages) == 1 and len(labels) == 1, 'APK badging identity/label is ambiguous.')
    pairs = re.findall(r"([A-Za-z0-9_]+)='([^']*)'", packages[0])
    attrs = object_without_duplicates(pairs)
    require(attrs.get('name') == PACKAGE and attrs.get('versionName') == version
            and number(attrs.get('versionCode')) == code, 'APK badging does not match the expected release.')
    require(labels[0] == "application-label:'Fieldrush'", 'APK application label must be Fieldrush.')


def validate_manifest(path, version, code, badging):
    text = read_text(path)
    require(not re.search(r'<!\s*(?:DOCTYPE|ENTITY)\b', text, re.I), 'XML declarations/entities are unsupported.')
    root = ET.fromstring(text)
    require(root.tag == 'manifest' and root.get('package') == PACKAGE,
            'Manifest package must identify Fieldrush production.')
    require(root.get(ANDROID + 'versionName') == version
            and number(root.get(ANDROID + 'versionCode')) == code, 'Manifest version does not match the expected release.')
    sdks, apps = root.findall('uses-sdk'), root.findall('application')
    require(len(sdks) == 1 and len(apps) == 1, 'Manifest must have one SDK declaration and application.')
    target = number(sdks[0].get(ANDROID + 'targetSdkVersion'))
    require(target >= 36, 'Production target SDK must be at least 36.')
    app = apps[0]
    require(app.get(ANDROID + 'debuggable', 'false') in {'false', '0', '0x0'},
            'Production application must not be debuggable.')
    require(app.get(ANDROID + 'testOnly', 'false') in {'false', '0', '0x0'},
            'Production application must not be test-only.')
    push_init = [x for x in app.findall('meta-data')
                 if x.get(ANDROID + 'name') == 'firebase_messaging_auto_init_enabled']
    require(len(push_init) == 1 and push_init[0].get(ANDROID + 'value') in {'false', '0', '0x0'},
            'Firebase Messaging auto-initialization must be explicitly disabled.')
    label = app.get(ANDROID + 'label', '')
    require(label == 'Fieldrush' or label.startswith('@'), 'Manifest application label must be Fieldrush.')
    require(label == 'Fieldrush' or badging is not None,
            'Resource application labels require an APK badging dump.')
    if badging is not None:
        validate_badging(badging, version, code)
    routes = set()
    for activity in [*app.findall('activity'), *app.findall('activity-alias')]:
        if activity.get(ANDROID + 'exported') not in {'true', '1', '0x1', '0xffffffff'}:
            continue
        for intent in activity.findall('intent-filter'):
            actions = {x.get(ANDROID + 'name') for x in intent.findall('action')}
            categories = {x.get(ANDROID + 'name') for x in intent.findall('category')}
            if 'android.intent.action.VIEW' not in actions or not {
                    'android.intent.category.DEFAULT', 'android.intent.category.BROWSABLE'} <= categories:
                continue
            # Android combines data attributes within one filter, not across filters.
            data = intent.findall('data')
            if CALLBACK_SCHEME in {x.get(ANDROID + 'scheme') for x in data}:
                routes.update(x.get(ANDROID + 'host') for x in data)
    require({'auth-callback', 'safepay'} <= routes, 'Production authentication/payment callback routes are missing.')
    return {'package': PACKAGE, 'version_name': version, 'version_code': code, 'target_sdk': target,
            'debuggable': False, 'label_verified_by': 'APK_BADGING' if badging else 'MANIFEST_LITERAL',
            'required_callback_routes_present': True, 'firebase_messaging_auto_init_enabled': False}


def take(stream, count):
    parts = []
    while count:
        chunk = stream.read(min(count, CHUNK))
        require(chunk, 'Native library is truncated.')
        parts.append(chunk)
        count -= len(chunk)
    return b''.join(parts)


def discard(stream, count):
    while count:
        chunk = stream.read(min(count, CHUNK))
        require(chunk, 'Native library is truncated.')
        count -= len(chunk)


def validate_relro(loads, relros):
    for relro in relros:
        start, end = relro['vaddr'], relro['vaddr'] + relro['memsz']
        if start == end:
            continue
        # Some linkers pad RELRO's p_memsz beyond its LOAD's logical end.
        # Android maps/protects whole pages, so that tail is valid only within
        # the owner's mapped final page. The start must still name actual data.
        # LLVM17 Writer.cpp:setPhdrs and bionic linker_phdr.cpp document this.
        containing = [load for load in loads
                      if load['vaddr'] <= start < load['vaddr'] + load['memsz']
                      and end <= ((load['vaddr'] + load['memsz'] + PAGE - 1) // PAGE) * PAGE]
        require(containing, 'RELRO range is outside loadable memory.')
        require(len(containing) == 1, 'RELRO ownership is ambiguous.')
        owner = containing[0]
        rounded_start = (start // PAGE) * PAGE
        rounded_end = ((end + PAGE - 1) // PAGE) * PAGE
        if owner['flags'] & PF_W:
            require(max(owner['vaddr'], rounded_start) >= start,
                    'RELRO protection overlaps preceding writable data on a 16 KB page.')
            require(min(owner['vaddr'] + owner['memsz'], rounded_end) <= end,
                    'RELRO protection overlaps subsequent writable data on a 16 KB page.')
        # Check even an aligned RELRO end: declared padding must never hide
        # another writable LOAD in the page that mprotect will make read-only.
        require(not any(load['flags'] & PF_W and load is not owner and load['memsz']
                        and load['vaddr'] < rounded_end
                        and load['vaddr'] + load['memsz'] > rounded_start
                        for load in loads), 'RELRO protection overlaps another writable LOAD on a 16 KB page.')


def validate_elf(stream, size, abi):
    ident = take(stream, 16)
    expected_class, machine = ABIS[abi]
    require(ident[:4] == b'\x7fELF' and ident[4] == expected_class and ident[5:7] == b'\x01\x01',
            'Native library ELF class/endianness does not match its ABI.')
    bits = 32 if expected_class == 1 else 64
    header_size, ph_size, sh_size = (52, 32, 40) if bits == 32 else (64, 56, 64)
    header = struct.unpack('<HHIIIIIHHHHHH' if bits == 32 else '<HHIQQQIHHHHHH',
                           take(stream, header_size - 16))
    kind, actual_machine, elf_version, _, phoff, shoff, _, ehsize, phentsize, phnum, shentsize, shnum, shstr = header
    require(kind == 3 and actual_machine == machine and elf_version == 1 and ehsize == header_size,
            'Native library has an invalid shared-object ELF header.')
    require(phentsize == ph_size and 0 < phnum <= 4096 and phoff >= header_size
            and phoff + phnum * ph_size <= size, 'Native program-header table is out of bounds.')
    if shnum:
        require(shentsize == sh_size and shoff >= header_size and shoff + shnum * sh_size <= size
                and shstr < shnum, 'Native section-header table is out of bounds.')
    else:
        require(shoff == 0 and shstr == 0, 'Unsupported extended native section-header table.')
    discard(stream, phoff - header_size)
    table = take(stream, phnum * ph_size)
    loads, relros = [], []
    for offset in range(0, len(table), ph_size):
        values = struct.unpack_from('<IIIIIIII' if bits == 32 else '<IIQQQQQQ', table, offset)
        if bits == 32:
            ptype, fileoff, vaddr, _, filesz, memsz, flags, align = values
        else:
            ptype, flags, fileoff, vaddr, _, filesz, memsz, align = values
        if ptype == 0:  # PT_NULL members are undefined and must be ignored.
            continue
        require((filesz == 0 or fileoff + filesz <= size) and vaddr + memsz <= 1 << bits,
                'Native segment range is out of bounds.')
        segment = {'vaddr': vaddr, 'memsz': memsz, 'flags': flags, 'align': align}
        if ptype == PT_LOAD:
            require(filesz <= memsz and memsz <= 2 * 1024 * 1024 * 1024,
                    'Native LOAD file/memory size is invalid.')
            require(align in {0, 1} or (align & (align - 1) == 0 and fileoff % align == vaddr % align),
                    'Native LOAD alignment/congruence is invalid.')
            if bits == 64:
                require(align >= PAGE and fileoff % PAGE == vaddr % PAGE,
                        'A 64-bit native LOAD is not 16 KB aligned.')
            else:
                require(fileoff % 4096 == vaddr % 4096, 'A 32-bit native LOAD has invalid page congruence.')
            loads.append(segment)
        elif ptype == PT_GNU_RELRO:
            relros.append(segment)
    require(loads and [x['vaddr'] for x in loads] == sorted(x['vaddr'] for x in loads),
            'Native LOAD segments are missing or unsorted.')
    if bits == 64:
        validate_relro(loads, relros)
    consumed = phoff + phnum * ph_size
    discard(stream, size - consumed)
    require(stream.read(1) == b'', 'Native library exceeds its declared size.')
    return {'elf_bits': bits, 'load_count': len(loads), 'minimum_load_alignment': min(x['align'] for x in loads),
            'relro_count': len(relros)}


def validate_archive(path):
    regular_file(path)
    native, names, total, native_total = [], set(), 0, 0
    with zipfile.ZipFile(path) as bundle:
        entries = bundle.infolist()
        require(0 < len(entries) <= 50000, 'Bundle ZIP entry count is invalid.')
        for info in entries:
            name = info.filename
            parts = name.rstrip('/').split('/')
            require(name and '\x00' not in info.orig_filename and '\\' not in name
                    and not name.startswith('/') and not re.match(r'^[A-Za-z]:', name)
                    and not any(part in {'', '.', '..'} for part in parts), 'Unsafe bundle ZIP path.')
            require(name.rstrip('/') not in names, 'Duplicate bundle ZIP entry.')
            names.add(name.rstrip('/'))
            mode = stat.S_IFMT(info.external_attr >> 16)
            require(mode in {0, stat.S_IFREG, stat.S_IFDIR}, 'Bundle ZIP contains a symlink or special file.')
            require(not info.flag_bits & 1 and info.compress_type in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED},
                    'Bundle ZIP encryption/compression is unsupported.')
            total += info.file_size
            require(total <= 4 * 1024 * 1024 * 1024, 'Bundle ZIP expanded size is excessive.')
            if not info.is_dir() and name.lower().endswith('.so'):
                require(len(parts) == 4 and parts[1] == 'lib' and parts[2] in ABIS,
                        'Native library location/ABI is unsupported.')
                require(0 < info.file_size <= MAX_NATIVE, 'Native library size is invalid.')
                native_total += info.file_size
                require(native_total <= MAX_NATIVE_TOTAL, 'Combined native library size is excessive.')
                native.append((info, parts[0], parts[2], parts[3]))
        require('base/manifest/AndroidManifest.xml' in names and 'BundleConfig.pb' in names,
                'Bundle is missing its base manifest/configuration.')
        require(native, 'Flutter release bundle has no native libraries.')
        identities, coverage, results = set(), {}, []
        for info, module, abi, library in native:
            require((abi, library) not in identities, 'Duplicate native library across bundle modules.')
            identities.add((abi, library))
            coverage.setdefault(abi, set())
            if module == 'base':
                coverage[abi].add(library)
            with bundle.open(info) as stream:
                results.append((abi, validate_elf(stream, info.file_size, abi)))
        require('arm64-v8a' in coverage and all({'libflutter.so', 'libapp.so'} <= libs
                                              for libs in coverage.values()),
                'Flutter engine/application ABI coverage is incomplete.')
    return {'abis': sorted(coverage), 'native_library_count': len(results),
            'native_bytes_streamed': native_total, 'flutter_core_libraries_present_per_abi': True,
            'all_native_elf_structures_checked': True, 'all_64bit_load_and_relro_layouts_checked': True,
            'minimum_64bit_load_alignment': min(r['minimum_load_alignment'] for _, r in results if r['elf_bits'] == 64)}


def main():
    parser = Parser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('expected_version')
    parser.add_argument('expected_code')
    parser.add_argument('--bundle-config', type=Path, required=True)
    parser.add_argument('--apk-badging', type=Path)
    args = parser.parse_args()
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.expected_version), 'Expected release version is invalid.')
    code = number(args.expected_code)
    require(0 < code <= 2100000000, 'Expected version code is outside the Play range.')
    validate_bundle_config(args.bundle_config)
    manifest = validate_manifest(args.manifest, args.expected_version, code, args.apk_badging)
    native = validate_archive(args.bundle)
    print(json.dumps({'valid': True, 'manifest': manifest, 'native': native,
                      'bundle_native_libraries_uncompressed': True,
                      'bundle_native_zip_alignment_request': 'PAGE_ALIGNMENT_16K',
                      'runtime_16kb_compatibility_tested': False,
                      'apk_zip_alignment_checked_here': False, 'signing_identity_checked_here': False}, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except InvalidArtifact as error:
        print('Android artifact validation failed: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
    except Exception:
        print('Android artifact validation failed: unreadable or malformed artifact metadata.', file=sys.stderr)
        raise SystemExit(1)
