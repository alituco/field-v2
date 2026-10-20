const { contextBridge, ipcRenderer } = require('electron');
const actions = new Set(['state', 'open-obs', 'open-referee', 'open-guide', 'set-server', 'connect-obs', 'devices', 'choose-folder', 'configure', 'preview', 'local-test', 'pair', 'forget', 'stop-local', 'open-recordings', 'stream-test', 'recover-recording', 'cancel-upload', 'restart-recovery']);
contextBridge.exposeInMainWorld('fieldrush', {
  invoke: (action, value) => {
    if (!actions.has(action)) return Promise.resolve({ ok: false, error: 'Unknown action.' });
    return ipcRenderer.invoke(action, value);
  },
  onState: callback => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('state-changed', listener);
    return () => ipcRenderer.removeListener('state-changed', listener);
  },
});
