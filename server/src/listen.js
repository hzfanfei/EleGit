export function listenHttp(server, port, bind) {
  return new Promise((resolve, reject) => {
    const onError = (err) => {
      server.removeListener("error", onError);
      reject(err);
    };
    server.on("error", onError);
    server.listen(port, bind, () => {
      server.removeListener("error", onError);
      resolve();
    });
  });
}

export function isAddrInUse(err) {
  return err?.code === "EADDRINUSE";
}

export async function bindCompanion(server, port, bind) {
  try {
    await listenHttp(server, port, bind);
    return "bound";
  } catch (err) {
    if (isAddrInUse(err)) return "busy";
    throw err;
  }
}
