import { connect } from 'node:net';

const publicErrors = new Map([
  ['This server has reached its workspace capacity.', 503],
  ['Start a new sign-in.', 409],
  ['Invalid authorization code.', 400],
  ['The provider could not start sign-in.', 502],
]);
export class WorkspaceError extends Error {
  constructor(message) {
    super(message);
    this.status = publicErrors.get(message);
  }
}

export function workspaceBroker(path) {
  function request(workspace, action, provider, code) {
    const socket = connect(path);
    socket.on('connect', () =>
      socket.write(JSON.stringify({ workspace, action, provider, code }) + '\n')
    );
    return new Promise((resolve, reject) => {
      let response = Buffer.alloc(0);
      const fail = () => {
        finish();
        socket.destroy();
        reject(Error('Workspace service unavailable'));
      };
      const timeout = setTimeout(fail, 150_000);
      const finish = () => {
        clearTimeout(timeout);
        socket.off('error', fail);
        socket.off('end', fail);
        socket.off('data', read);
      };
      function read(chunk) {
        response = Buffer.concat([response, chunk]);
        const newline = response.indexOf(10);
        if (newline < 0 && response.length <= 8192) return;
        finish();
        try {
          if (newline < 0 || newline > 8192) throw Error('Invalid broker response');
          const data = JSON.parse(response.subarray(0, newline).toString());
          if (publicErrors.has(data.error)) throw new WorkspaceError(data.error);
          if (data.error) throw Error('Workspace operation failed');
          if (action === 'display') {
            if (data.display !== true) throw Error('Display unavailable');
            socket.pause();
            if (response.length > newline + 1) socket.unshift(response.subarray(newline + 1));
            resolve(socket);
          } else {
            socket.end();
            resolve(data);
          }
        } catch (err) {
          socket.destroy();
          reject(err);
        }
      }
      socket.on('error', fail);
      socket.on('end', fail);
      socket.on('data', read);
    });
  }
  return { call: request, display: (workspace) => request(workspace, 'display') };
}
