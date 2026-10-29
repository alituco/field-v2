import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const validator = fileURLToPath(new URL('./validate-production-android.py', import.meta.url));
const PAGE = 16384;
const abiInfo = { 'arm64-v8a': [2, 183], 'armeabi-v7a': [1, 40], x86_64: [2, 62] };

// Real ELF layouts, not magic-only stubs: valid headers and PT_LOAD file ranges.
function elf(abi, { segments, classOverride, machineOverride, truncate = false } = {}) {
  const [normalClass, normalMachine] = abiInfo[abi];
  const elfClass = classOverride ?? normalClass;
  const is64 = elfClass === 2;
  const headerSize = is64 ? 64 : 52;
  const phSize = is64 ? 56 : 32;
  segments ??= [{ type: 1, offset: 0, vaddr: 0, filesz: PAGE, memsz: PAGE, flags: 5,
    align: is64 ? PAGE : 4096 }];
  const out = Buffer.alloc(PAGE * 3);
  out.set([0x7f, 69, 76, 70, elfClass, 1, 1]);
  out.writeUInt16LE(3, 16);
  out.writeUInt16LE(machineOverride ?? normalMachine, 18);
  out.writeUInt32LE(1, 20);
  if (is64) {
    out.writeBigUInt64LE(BigInt(headerSize), 32);
    out.writeUInt16LE(headerSize, 52);
    out.writeUInt16LE(phSize, 54);
    out.writeUInt16LE(segments.length, 56);
  } else {
    out.writeUInt32LE(headerSize, 28);
    out.writeUInt16LE(headerSize, 40);
    out.writeUInt16LE(phSize, 42);
    out.writeUInt16LE(segments.length, 44);
  }
  for (const [index, seg] of segments.entries()) {
    const at = headerSize + index * phSize;
    const values = [seg.offset ?? 0, seg.vaddr ?? 0, seg.vaddr ?? 0,
      seg.filesz ?? 0, seg.memsz ?? 0, seg.align ?? 1];
    out.writeUInt32LE(seg.type, at);
    if (is64) {
      out.writeUInt32LE(seg.flags ?? 4, at + 4);
      values.forEach((value, slot) => out.writeBigUInt64LE(BigInt(value), at + 8 + slot * 8));
    } else {
      values.slice(0, 5).forEach((value, slot) => out.writeUInt32LE(value, at + 4 + slot * 4));
      out.writeUInt32LE(seg.flags ?? 4, at + 24);
      out.writeUInt32LE(values[5], at + 28);
    }
  }
  return truncate ? out.subarray(0, headerSize + 4) : out;
}

function manifest({ packageName = 'gg.fieldrush.app', version = '1.0.0', code = '201', sdk = '36',
  debug = 'false', label = 'Fieldrush', scheme = 'com.alialtaraif.field', host = 'safepay',
  exported = 'true', browsable = true, pushAutoInit = 'false' } = {}) {
  return `<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="${packageName}"
    android:versionName="${version}" android:versionCode="${code}">
    <uses-sdk android:targetSdkVersion="${sdk}" />
    <application android:label="${label}" android:debuggable="${debug}">
      <meta-data android:name="firebase_messaging_auto_init_enabled" android:value="${pushAutoInit}" />
      <activity android:name=".MainActivity" android:exported="${exported}">
        <intent-filter><action android:name="android.intent.action.VIEW" />
          <category android:name="android.intent.category.DEFAULT" />
          ${browsable ? '<category android:name="android.intent.category.BROWSABLE" />' : ''}
          <data android:scheme="${scheme}" android:host="auth-callback" />
          <data android:host="${host}" />
        </intent-filter>
      </activity>
    </application>
  </manifest>`;
}

const goodConfig = { optimizations: { uncompressNativeLibraries: {
  enabled: true, alignment: 'PAGE_ALIGNMENT_16K',
} } };
const goodBadging = "package: name='gg.fieldrush.app' versionCode='201' versionName='1.0.0'\napplication-label:'Fieldrush'\n";

function fixture(t, { xml = manifest(), config = goodConfig, entries, badging } = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'fieldrush-artifact-fixture-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  entries ??= Object.keys(abiInfo).flatMap(abi => ['libflutter.so', 'libapp.so'].map(name => ({
    name: `base/lib/${abi}/${name}`, bytes: elf(abi),
  })));
  const entriesPath = path.join(dir, 'entries.json');
  writeFileSync(entriesPath, JSON.stringify(entries.map(entry => ({ name: entry.name,
    data: (entry.bytes ?? Buffer.from('extra')).toString('base64'), symlink: entry.symlink }))));
  const zip = spawnSync('python3', ['-c', `
import json,sys,zipfile,base64,stat
with open(sys.argv[2],encoding='utf-8') as f:data=json.load(f)
with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_DEFLATED) as z:
 z.writestr('BundleConfig.pb',b'fixture config handled through official dump input')
 z.writestr('base/manifest/AndroidManifest.xml',b'fixture binary manifest handled through official dump input')
 for item in data:
  info=zipfile.ZipInfo(item['name']);info.compress_type=zipfile.ZIP_DEFLATED
  info.external_attr=((stat.S_IFLNK if item.get('symlink') else stat.S_IFREG)|0o644)<<16
  z.writestr(info,base64.b64decode(item['data']))
`, path.join(dir, 'release.aab'), entriesPath], {
    encoding: 'utf8', timeout: 15000,
  });
  assert.equal(zip.status, 0, 'fixture ZIP creation failed');
  writeFileSync(path.join(dir, 'manifest.xml'), xml);
  writeFileSync(path.join(dir, 'config.json'), typeof config === 'string' ? config : JSON.stringify(config));
  const args = [validator, path.join(dir, 'manifest.xml'), path.join(dir, 'release.aab'),
    '1.0.0', '201', '--bundle-config', path.join(dir, 'config.json')];
  if (badging !== undefined) {
    writeFileSync(path.join(dir, 'badging.txt'), badging);
    args.push('--apk-badging', path.join(dir, 'badging.txt'));
  }
  return { dir, run: () => spawnSync('python3', args, { encoding: 'utf8', timeout: 15000 }) };
}

function reject(t, options, message) {
  const f = fixture(t, options);
  const result = f.run();
  assert.equal(result.status, 1);
  assert.match(result.stderr, message);
  assert.equal(result.stdout, '');
  assert.ok(!result.stderr.includes(f.dir), 'private artifact paths must not be logged');
}

test('accepts a real Flutter-style ABI matrix, including valid 4 KB ELF32 libraries', t => {
  const result = fixture(t).run();
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.native.abis, ['arm64-v8a', 'armeabi-v7a', 'x86_64']);
  assert.equal(report.native.native_library_count, 6);
  assert.equal(report.native.minimum_64bit_load_alignment, PAGE);
  assert.equal(report.runtime_16kb_compatibility_tested, false);
  assert.equal(report.bundle_native_zip_alignment_request, 'PAGE_ALIGNMENT_16K');
});

test('resolves a manifest resource label only through matching APK badging', t => {
  const result = fixture(t, { xml: manifest({ label: '@0x7f120001' }), badging: goodBadging }).run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).manifest.label_verified_by, 'APK_BADGING');
});

test('rejects an unresolved resource label and mismatched APK badging', async t => {
  await t.test('no badging', child => reject(child, { xml: manifest({ label: '@string/app_name' }) }, /require an APK badging/));
  await t.test('wrong package', child => reject(child, { badging: goodBadging.replace('gg.fieldrush.app', 'com.field.staging') }, /does not match/));
  await t.test('wrong version', child => reject(child, { badging: goodBadging.replace("versionCode='201'", "versionCode='200'") }, /does not match/));
  await t.test('wrong label', child => reject(child, { badging: goodBadging.replace('Fieldrush', 'Field Staging') }, /label must be Fieldrush/));
});

test('rejects incorrect production identity, target SDK, and debug builds', async t => {
  for (const [name, changes, reason] of [
    ['package', { packageName: 'com.field.staging' }, /production/],
    ['version', { version: '0.9.0' }, /version/],
    ['code', { code: '200' }, /version/],
    ['SDK', { sdk: '35' }, /at least 36/],
    ['debug', { debug: 'true' }, /not be debuggable/],
    ['push auto-init', { pushAutoInit: 'true' }, /auto-initialization must be explicitly disabled/],
  ]) await t.test(name, child => reject(child, { xml: manifest(changes) }, reason));
});

test('rejects callbacks that cannot return to the exported app', async t => {
  for (const changes of [{ scheme: 'com.field.staging' }, { host: 'wrong-host' },
    { exported: 'false' }, { browsable: false }]) {
    await t.test(JSON.stringify(changes), child => reject(child, { xml: manifest(changes) }, /callback routes/));
  }
});

test('requires enabled native uncompression and an explicit 16 KB bundle request', async t => {
  for (const native of [{ enabled: false, alignment: 'PAGE_ALIGNMENT_16K' },
    { enabled: true, alignment: 'PAGE_ALIGNMENT_4K' }, { enabled: true }]) {
    await t.test(JSON.stringify(native), child => reject(child,
      { config: { optimizations: { uncompressNativeLibraries: native } } }, /Bundle must/));
  }
  await t.test('ambiguous JSON', child => reject(child, {
    config: '{"optimizations":{},"optimizations":{"uncompressNativeLibraries":{"enabled":true,"alignment":"PAGE_ALIGNMENT_16K"}}}',
  }, /Duplicate bundle configuration/));
});

function arm64Entries(overrides = {}) {
  return ['libflutter.so', 'libapp.so'].map(name => ({ name: `base/lib/arm64-v8a/${name}`,
    bytes: elf('arm64-v8a', overrides) }));
}

test('checks every 64-bit LOAD, not just the first segment', t => reject(t, {
  entries: arm64Entries({ segments: [
    { type: 1, offset: 0, vaddr: 0, filesz: PAGE, memsz: PAGE, flags: 5, align: PAGE },
    { type: 1, offset: PAGE, vaddr: PAGE, filesz: 4096, memsz: 4096, flags: 6, align: 4096 },
  ] }),
}, /not 16 KB aligned/));

test('rejects malformed ELF ranges, ABI headers, and missing Flutter core libraries', async t => {
  await t.test('out of bounds LOAD', child => reject(child, { entries: arm64Entries({ segments: [
    { type: 1, offset: 0, vaddr: 0, filesz: PAGE * 4, memsz: PAGE * 4, flags: 5, align: PAGE },
  ] }) }, /out of bounds/));
  await t.test('truncated header table', child => reject(child, { entries: arm64Entries({ truncate: true }) }, /out of bounds/));
  await t.test('wrong machine', child => reject(child, { entries: arm64Entries({ machineOverride: 62 }) }, /invalid shared-object ELF header/));
  await t.test('missing application', child => reject(child, { entries: arm64Entries().slice(0, 1) }, /ABI coverage is incomplete/));
});

const relro = (vaddr, memsz) => ({ type: 0x6474e552, offset: 0x4000, vaddr, filesz: 0x100, memsz, flags: 4, align: 1 });

// Program headers from Google's datastore-core-android:1.1.7 AAR, used by the
// locked shared_preferences_android 2.4.13 dependency. AAR SHA256:
// adca1d7cde73406fcca2a0eeabac63459adc9d1fe201b79ba08711fa2e331984.
// These offline structural fixtures contain no vendor executable bytes.
const datastoreSegments = {
  'arm64-v8a': [
    { type: 1, offset: 0, vaddr: 0, filesz: 0x11c0, memsz: 0x11c0, flags: 5, align: PAGE },
    { type: 1, offset: 0x11c0, vaddr: 0x51c0, filesz: 0x268, memsz: 0x268, flags: 6, align: PAGE },
    { type: 1, offset: 0x1428, vaddr: 0x9428, filesz: 0, memsz: 1, flags: 6, align: PAGE },
    { ...relro(0x51c0, 0xe40), offset: 0x11c0, filesz: 0x268 },
  ],
  x86_64: [
    { type: 1, offset: 0, vaddr: 0, filesz: 0xf20, memsz: 0xf20, flags: 5, align: PAGE },
    { type: 1, offset: 0xf20, vaddr: 0x4f20, filesz: 0x228, memsz: 0x228, flags: 6, align: PAGE },
    { ...relro(0x4f20, 0x10e0), offset: 0xf20, filesz: 0x228 },
  ],
};

test('accepts real Datastore RELRO padding within the mapped final LOAD page', async t => {
  for (const abi of Object.keys(datastoreSegments)) await t.test(abi, child => {
    const entries = [...new Set(['arm64-v8a', abi])].flatMap(coreAbi =>
      ['libflutter.so', 'libapp.so'].map(name => ({
        name: `base/lib/${coreAbi}/${name}`, bytes: elf(coreAbi),
      })));
    entries.push({ name: `base/lib/${abi}/libdatastore_shared_counter.so`,
      bytes: elf(abi, { segments: datastoreSegments[abi] }) });
    const result = fixture(child, { entries }).run();
    assert.equal(result.status, 0, result.stderr);
  });
});

test('rejects padded RELRO outside actual mapped memory', async t => {
  const base = datastoreSegments['arm64-v8a'];
  for (const [name, changes] of [
    ['one byte past mapped page', { vaddr: 0x51c0, memsz: 0x8001 - 0x51c0 }],
    ['start at logical LOAD end', { vaddr: 0x5428, memsz: 0x6000 - 0x5428 }],
    ['entirely in page padding', { vaddr: 0x5500, memsz: 0x100 }],
  ]) await t.test(name, child => reject(child, {
    entries: arm64Entries({ segments: [...base.slice(0, -1), { ...base.at(-1), ...changes }] }),
  }, /outside loadable memory/));
});

test('rejects another writable LOAD in RELRO padding, including aligned protection ends', async t => {
  for (const [name, vaddr, end] of [
    ['inside declared padding', 0x5800, 0x6000],
    ['inside rounded padding', 0x7000, 0x6000],
    ['aligned declared end', 0x7000, 0x8000],
  ]) await t.test(name, child => reject(child, {
    entries: arm64Entries({ segments: [
      ...datastoreSegments['arm64-v8a'].slice(0, 2),
      { type: 1, offset: vaddr - 0x4000, vaddr, filesz: 1, memsz: 1, flags: 6, align: PAGE },
      { ...datastoreSegments['arm64-v8a'].at(-1), memsz: end - 0x51c0 },
    ] }),
  }, /another writable LOAD/));
});

test('rejects writable prefix data on the first RELRO-protected page', t => reject(t, {
  entries: arm64Entries({ segments: [
    { type: 1, offset: 0, vaddr: 0, filesz: PAGE, memsz: PAGE, flags: 5, align: PAGE },
    { type: 1, offset: PAGE, vaddr: PAGE, filesz: PAGE, memsz: PAGE, flags: 6, align: PAGE },
    relro(0x4800, 0x3800),
  ] }),
}, /preceding writable data/));

test('allows writable prefix data confined to an earlier unprotected page', t => {
  const result = fixture(t, { entries: arm64Entries({ segments: [
    { type: 1, offset: 0, vaddr: 0, filesz: PAGE, memsz: PAGE, flags: 5, align: PAGE },
    { type: 1, offset: PAGE, vaddr: PAGE, filesz: 0x5000, memsz: 0x5000, flags: 6, align: PAGE },
    { ...relro(0x8000, 0x1000), offset: 0x8000 },
  ] }) }).run();
  assert.equal(result.status, 0, result.stderr);
});

test('rejects RELRO rounding over writable data in the same LOAD', t => reject(t, {
  entries: arm64Entries({ segments: [
    { type: 1, offset: 0, vaddr: 0, filesz: 0x4000, memsz: 0x4000, flags: 5, align: PAGE },
    { type: 1, offset: 0x4000, vaddr: 0x4000, filesz: 0x2000, memsz: 0x2000, flags: 6, align: PAGE },
    relro(0x4000, 0x1000),
  ] }),
}, /RELRO protection overlaps/));

test('allows unaligned RELRO occupying its own LOAD before a separate writable page', t => {
  const result = fixture(t, { entries: arm64Entries({ segments: [
    { type: 1, offset: 0, vaddr: 0, filesz: 0x4000, memsz: 0x4000, flags: 5, align: PAGE },
    { type: 1, offset: 0x4000, vaddr: 0x4000, filesz: 0x1000, memsz: 0x1000, flags: 6, align: PAGE },
    { type: 1, offset: 0x8000, vaddr: 0x8000, filesz: 0x1000, memsz: 0x1000, flags: 6, align: PAGE },
    relro(0x4000, 0x1000),
  ] }) }).run();
  assert.equal(result.status, 0, result.stderr);
});

test('rejects the dedicated RELRO exception when another writable LOAD shares its final page', t => reject(t, {
  entries: arm64Entries({ segments: [
    { type: 1, offset: 0, vaddr: 0, filesz: 0x4000, memsz: 0x4000, flags: 5, align: PAGE },
    { type: 1, offset: 0x4000, vaddr: 0x4000, filesz: 0x1000, memsz: 0x1000, flags: 6, align: PAGE },
    { type: 1, offset: 0x7000, vaddr: 0x7000, filesz: 0x1000, memsz: 0x1000, flags: 6, align: PAGE },
    relro(0x4000, 0x1000),
  ] }),
}, /another writable LOAD/));

test('rejects traversal, duplicate files, symlinks, and unaccounted native code', async t => {
  for (const [name, extra, reason] of [
    ['traversal', { name: '../private-marker' }, /Unsafe bundle ZIP path/],
    ['duplicate', arm64Entries()[0], /Duplicate bundle ZIP entry/],
    ['symlink', { name: 'base/assets/link', symlink: true }, /symlink or special file/],
    ['native outside ABI directory', { name: 'base/assets/payload.so', bytes: elf('arm64-v8a') }, /location\/ABI/],
  ]) await t.test(name, child => reject(child, { entries: [...arm64Entries(), extra] }, reason));
});
