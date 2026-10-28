import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

// Only the main process reads this store. Credentials are encrypted using the
// macOS Keychain-backed Electron safeStorage API; fail closed if unavailable.
export class DesktopState {
  constructor(directory, safeStorage) {
    this.directory = directory;
    this.safeStorage = safeStorage;
    this.value = { workspaceId: randomUUID(), server: 'https://ops-staging.field.bh', obsState: {} };
    this.pending = Promise.resolve();
  }
  async load() {
    try {
      const file = await fs.readFile(path.join(this.directory, 'settings.enc'));
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error('Unlock your Mac keychain to open Fieldrush.');
      const saved = JSON.parse(this.safeStorage.decryptString(file));
      if (typeof saved.workspaceId !== 'string' || !saved.workspaceId) throw new Error('Invalid saved settings.');
      this.value = saved;
    } catch (error) {
      if (error.code !== 'ENOENT') throw new Error('Your saved setup could not be unlocked. Unlock your Mac keychain and restart Fieldrush.');
    }
    return this.value;
  }
  async update(patch) {
    this.value = { ...this.value, ...patch };
    const snapshot = JSON.stringify(this.value);
    const write = this.pending.catch(() => {}).then(async () => {
      if (!this.safeStorage.isEncryptionAvailable()) throw new Error('The Mac keychain is unavailable. Setup was not saved.');
      await fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
      const target = path.join(this.directory, 'settings.enc');
      const temp = target + '.tmp';
      await fs.writeFile(temp, this.safeStorage.encryptString(snapshot), { mode: 0o600 });
      await fs.rename(temp, target);
    });
    this.pending = write;
    await write;
  }
}
