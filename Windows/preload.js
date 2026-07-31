'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('agentSignal', {
  getState: () => ipcRenderer.invoke('get-ui-state'),
  onState: (callback) => ipcRenderer.on('ui-state', (_event, value) => callback(value))
});
