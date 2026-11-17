// The only bridge between a window and the app: named messages, nothing else (windows load local files only).
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('tomatime', {
  invoke: (what, data) => ipcRenderer.invoke('tomatime:' + what, data),
  on: (what, f) => ipcRenderer.on('tomatime:' + what, (_event, data) => f(data)),
});
