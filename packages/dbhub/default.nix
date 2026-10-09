# DBHub (https://github.com/bytebase/dbhub), a database MCP server, pinned by
# package-lock.json. Regenerate the lock after changing the version:
#
#   npm install --package-lock-only --ignore-scripts --save-exact @bytebase/dbhub@<version>
#
# Every dependency is fetched by the integrity hash in the lock, so there is no
# separate dependency hash to update.
{ lib, buildNpmPackage, importNpmLock, makeWrapper, nodejs }:
let
  lock = lib.importJSON ./package-lock.json;
in
buildNpmPackage {
  pname = "dbhub";
  version = lock.packages."node_modules/@bytebase/dbhub".version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./package.json ./package-lock.json ];
  };

  inherit nodejs;
  npmDeps = importNpmLock { npmRoot = ./.; };
  npmConfigHook = importNpmLock.npmConfigHook;
  # The only install scripts build optional native helpers (ssh2's crypto
  # binding, cpu-features); DBHub uses pure-JS drivers and node:sqlite.
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/dbhub
    # npm's install record points at the fetched tarballs; dropping it keeps
    # them out of the runtime closure.
    rm -f node_modules/.package-lock.json
    cp -r node_modules $out/lib/dbhub/
    makeWrapper ${lib.getExe nodejs} $out/bin/dbhub \
      --add-flags $out/lib/dbhub/node_modules/@bytebase/dbhub/dist/index.js
    runHook postInstall
  '';

  meta = {
    description = "Universal database MCP server (PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, Oracle)";
    homepage = "https://github.com/bytebase/dbhub";
    license = lib.licenses.mit;
    mainProgram = "dbhub";
  };
}
